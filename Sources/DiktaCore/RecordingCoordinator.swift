import AppKit
import Foundation
import ScreenCaptureKit
import UserNotifications

/// Drives one screen-recording session end to end: capture → transcribe →
/// Markdown, and keeps the menu informed about where it is.
///
/// Completely independent of the dictation flow — it owns its own `Transcriber`
/// so a long export never blocks (or unloads the model out from under) a
/// dictation happening at the same time.
@MainActor
final class RecordingCoordinator {
    enum State {
        case idle
        case recording(startedAt: Date)
        /// Post-processing, with a Hebrew label for the menu.
        case processing(phase: String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isBusy: Bool {
            if case .idle = self { return false }
            return true
        }
    }

    private(set) var state: State = .idle {
        didSet { onStateChange?() }
    }

    /// Fired on the main actor whenever `state` changes.
    var onStateChange: (() -> Void)?

    private let recorder = LiveRecorder()
    private let transcriber = Transcriber()

    /// Seconds since the recording started, for the menu's live timer.
    var elapsed: TimeInterval? {
        guard case .recording(let startedAt) = state else { return nil }
        return Date().timeIntervalSince(startedAt)
    }

    /// Frames kept so far during the current recording.
    var keptFrameCount: Int { recorder.keptFrameCount }

    // MARK: - Recording

    func startRecording(display: SCDisplay) {
        guard case .idle = state else { return }
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            NSLog("Dikta: screen recording permission missing")
            return
        }

        // Ask where this recording goes before anything is created or the state
        // moves off idle — cancelling leaves the app exactly as it was.
        guard let chosen = askForSessionDirectory() else { return }

        let directory = Self.uniquified(chosen)
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: framesDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Dikta: failed to create session directory: %@", "\(error)")
            return
        }
        state = .recording(startedAt: Date())
        pendingDirectory = directory

        recorder.onStreamError = { [weak self] error in
            Task { @MainActor in
                guard let self, self.state.isRecording else { return }
                NSLog("Dikta: screen recording interrupted: %@", "\(error)")
                self.stopAndProcess()
            }
        }

        // SCDisplay is an immutable descriptor but isn't marked Sendable; handing
        // it to the (nonisolated) recorder is safe.
        nonisolated(unsafe) let selected = display
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start(display: selected, framesDirectory: framesDirectory)
            } catch {
                NSLog("Dikta: failed to start screen recording: %@", "\(error)")
                self.pendingDirectory = nil
                try? FileManager.default.removeItem(at: directory)
                self.state = .idle
            }
        }
    }

    /// Where should this recording go? Returns the chosen session directory, or
    /// nil when the user cancels.
    private func askForSessionDirectory() -> URL? {
        let panel = NSSavePanel()
        panel.title = "הקלטת מסך חדשה"
        panel.message = "בחר היכן לשמור את ההקלטה ומה שם התיקייה"
        panel.prompt = "התחל הקלטה"
        panel.canCreateDirectories = true
        panel.showsTagField = false
        panel.nameFieldStringValue = Self.defaultSessionName(date: Date())
        let root = Settings.shared.recordingsFolder
        if FileManager.default.fileExists(atPath: root.path) {
            panel.directoryURL = root
        }
        // LSUIElement: without activating first the panel opens behind whatever
        // the user was looking at.
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        // The next panel opens wherever this one ended up.
        Settings.shared.recordingsFolder = panel.directoryURL ?? url.deletingLastPathComponent()
        return url
    }

    /// Stop capturing and run the full pipeline. Safe to call twice.
    func stopAndProcess() {
        guard case .recording = state, let directory = pendingDirectory else { return }
        pendingDirectory = nil
        state = .processing(phase: "עוצר הקלטה…")

        let mode = Settings.shared.languageMode
        let transcriber = self.transcriber

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.recorder.stop()
                let output = try await Self.process(
                    result: result, sessionDirectory: directory, mode: mode,
                    transcriber: transcriber
                ) { phase in
                    Task { @MainActor [weak self] in
                        self?.state = .processing(phase: phase)
                    }
                }
                // index.md is done; the summary is optional and never risks it.
                let document = await self.summarizeIfEnabled(output: output,
                                                             sessionDirectory: directory)
                self.state = .idle
                await self.present(index: document)
            } catch {
                NSLog("Dikta: screen recording failed: %@", "\(error)")
                self.state = .idle
            }
        }
    }

    /// Run the Claude summary when a key is configured and the toggle is on.
    /// Returns the document to open: `summary.md` on success, `index.md`
    /// whenever the stage is skipped or fails.
    private func summarizeIfEnabled(output: Output, sessionDirectory: URL) async -> URL {
        guard Settings.shared.autoSummarize else { return output.index }
        let engine = Settings.shared.summaryEngine

        state = .processing(phase: "מסכם עם Claude…")
        let progress: @Sendable (String) -> Void = { phase in
            Task { @MainActor [weak self] in
                self?.state = .processing(phase: phase)
            }
        }

        do {
            switch engine {
            case .claudeCLI:
                return try await ClaudeCLISummarizer.summarize(
                    frames: output.frames, segments: output.segments,
                    sessionDirectory: sessionDirectory, progress: progress)
            case .apiKey:
                guard let apiKey = KeychainStore.apiKey() else {
                    NSLog("Dikta: summary skipped — API engine selected but no key configured")
                    return output.index
                }
                return try await ClaudeSummarizer.summarize(
                    frames: output.frames, segments: output.segments,
                    sessionDirectory: sessionDirectory, apiKey: apiKey,
                    progress: progress)
            }
        } catch {
            NSLog("Dikta: Claude summary failed: %@", "\(error)")
            // Surface the actual reason (e.g. "credit balance is too low") —
            // a generic message hides fixable problems.
            await notify(title: "הסיכום עם Claude נכשל",
                         body: String("\(error)".prefix(140)) + "\nה-Markdown המקומי נשמר כרגיל.")
            return output.index
        }
    }

    private var pendingDirectory: URL?

    // MARK: - Pipeline (shared with the `record-test` CLI)

    /// What `process` produced: the written `index.md` plus the material an
    /// optional summary stage needs.
    struct Output: Sendable {
        let index: URL
        let frames: [MarkdownExporter.Frame]
        let segments: [TranscriptSegment]
    }

    /// Transcribe the recorded audio, align it to the kept frames and write
    /// `index.md`. Deletes the temporary WAV, so the session directory is left
    /// holding nothing but `index.md` and `frames/`.
    @discardableResult
    nonisolated static func process(result: LiveRecorder.Result,
                                    sessionDirectory: URL,
                                    mode: LanguageMode,
                                    transcriber: Transcriber,
                                    progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Output {
        defer {
            if let audioURL = result.audioURL {
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        var segments: [TranscriptSegment] = []
        if let audioURL = result.audioURL {
            progress("טוען אודיו…")
            let samples = try AudioFileLoader.loadSamples(from: audioURL)
            if !samples.isEmpty {
                progress("מתמלל…")
                let (modelPath, language) = try await LanguageRouter.route(
                    samples: samples, mode: mode, transcriber: transcriber)
                segments = try await transcriber.transcribeSegments(
                    samples: samples, language: language, modelPath: modelPath)
            }
        } else {
            NSLog("Dikta: no system audio captured — writing frames only")
        }

        progress("כותב Markdown…")
        let index = try MarkdownExporter.write(
            title: "הקלטת מסך",
            date: result.startedAt,
            duration: result.duration,
            frames: result.frames,
            segments: segments,
            to: sessionDirectory)
        return Output(index: index, frames: result.frames, segments: segments)
    }

    /// Default name offered in the save panel: `הקלטה 2026-07-09 14.30`.
    nonisolated static func defaultSessionName(date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm"
        return "הקלטה \(formatter.string(from: date))"
    }

    /// The chosen directory when it's free (or exists but empty), otherwise
    /// `<name> (2)`, `<name> (3)`… so an earlier recording is never written over.
    nonisolated static func uniquified(_ directory: URL) -> URL {
        guard !isVacant(directory) else { return directory }
        let parent = directory.deletingLastPathComponent()
        let base = directory.lastPathComponent
        var suffix = 2
        var candidate = parent.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
        while !isVacant(candidate) {
            suffix += 1
            candidate = parent.appendingPathComponent("\(base) (\(suffix))", isDirectory: true)
        }
        return candidate
    }

    /// Nothing there, or an empty directory — either way safe to record into.
    private nonisolated static func isVacant(_ url: URL) -> Bool {
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
            // Not a directory: vacant only if nothing exists at that path at all.
            return !FileManager.default.fileExists(atPath: url.path)
        }
        return contents.isEmpty
    }

    // MARK: - Presentation

    private func present(index: URL) async {
        NSWorkspace.shared.open(index)
        NSLog("Dikta: screen recording ready: %@", index.path)
        await notify(title: "הקלטת המסך מוכנה",
                     body: index.deletingLastPathComponent().lastPathComponent)
    }

    private func notify(title: String, body: String) async {
        // UNUserNotificationCenter traps when the process isn't a real bundle.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert])) ?? false
        guard granted else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        try? await center.add(UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
