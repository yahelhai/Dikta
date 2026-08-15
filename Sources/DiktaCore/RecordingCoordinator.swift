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
        didSet {
            publish()
            onStateChange?()
        }
    }

    /// Fired on the main actor whenever `state` changes.
    var onStateChange: (() -> Void)?

    private let recorder = LiveRecorder()
    private let transcriber = Transcriber()

    /// Held for the app's whole life so `dikta record` can tell that the menu is
    /// here at all; the published phase says whether it is actually recording.
    private let registryClaim = RecordingRegistry.claim(.app)
    private let sessionID = UUID().uuidString

    init() { publish() }

    /// Mirrors the menu's state into the run directory, so the CLI can refuse to
    /// start a second capture instead of quietly recording the same screen twice.
    /// One-way on purpose: `dikta stop` does not reach back into the menu.
    private func publish() {
        guard registryClaim != nil else { return }
        var published = RecordingState(
            owner: .app, sessionID: sessionID, phase: .done)
        switch state {
        case .idle:
            // Terminal from the CLI's point of view — the app is not busy.
            published.phase = .done
        case .recording(let startedAt):
            published.phase = .recording
            published.startedAt = startedAt
            published.sessionDirectory = pendingDirectory?.path
        case .processing(let phase):
            published.phase = .processing
            published.label = phase
        }
        try? RecordingRegistry.write(published)
    }

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
        // Before the save panel, not after: being asked to pick a folder and
        // only then refused is worse than being refused straight away. The CLI
        // has refused in the other direction since it shipped; this is the half
        // that was missing, and without it both recorders capture the same
        // screen at once, each unaware of the other.
        if let cli = RecordingRegistry.activeRecording(.cli) {
            warnCLIIsRecording(cli)
            return
        }
        guard Permissions.screenRecordingGranted else {
            Permissions.requestScreenRecording()
            NSLog("Dikta: screen recording permission missing")
            return
        }

        // Ask where this recording goes before anything is created or the state
        // moves off idle — cancelling leaves the app exactly as it was.
        guard let chosen = askForSessionDirectory() else { return }
        startRecording(display: display, sessionDirectory: Self.uniquified(chosen))
    }

    /// The same start with the destination already decided. This is the seam the
    /// save panel blocks: `dikta record` has no UI to put a panel in.
    func startRecording(display: SCDisplay, sessionDirectory directory: URL) {
        let framesDirectory = directory.appendingPathComponent("frames", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: framesDirectory, withIntermediateDirectories: true)
        } catch {
            NSLog("Dikta: failed to create session directory: %@", "\(error)")
            return
        }
        let startedAt = Date()
        let workspace = SessionWorkspace(session: directory)
        let meta = SessionWorkspace.Meta(
            startedAt: startedAt, modelPath: "", language: nil,
            chunkSeconds: Settings.chunkSeconds, title: "הקלטת מסך")
        do {
            try workspace.create()
            try workspace.writeMeta(meta)
        } catch {
            NSLog("Dikta: failed to create workspace: %@", "\(error)")
            return
        }
        let pipeline = ChunkTranscriptionPipeline(
            workspace: workspace, meta: meta, mode: Settings.shared.languageMode,
            transcriber: transcriber)

        state = .recording(startedAt: startedAt)
        pendingDirectory = directory
        pendingWorkspace = workspace
        pendingPipeline = pipeline

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
                try await self.recorder.start(
                    display: selected,
                    framesDirectory: framesDirectory,
                    audioDirectory: workspace.root,
                    chunkSeconds: Settings.chunkSeconds,
                    onFrame: { try? workspace.appendFrame($0) },
                    onChunk: { pipeline.submit($0) })
            } catch {
                NSLog("Dikta: failed to start screen recording: %@", "\(error)")
                self.pendingDirectory = nil
                self.pendingWorkspace = nil
                self.pendingPipeline = nil
                await pipeline.finish()
                try? FileManager.default.removeItem(at: directory)
                self.state = .idle
            }
        }
    }

    /// The mirror image of the CLI's own refusal message.
    private func warnCLIIsRecording(_ cli: RecordingState) {
        let alert = NSAlert()
        alert.messageText = cli.phase == .processing
            ? "הקלטה מהשורת פקודה עדיין מעובדת"
            : "הקלטה כבר רצה מהשורת פקודה"
        var body = cli.phase == .processing
            ? "המתן שתסתיים לפני שתתחיל הקלטה חדשה."
            : "עצור אותה עם dikta stop לפני שתתחיל הקלטה חדשה."
        if let directory = cli.sessionDirectory { body += "\n\n\(directory)" }
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: "הבנתי")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
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
        guard case .recording = state, let directory = pendingDirectory,
              let workspace = pendingWorkspace else { return }
        let pipeline = pendingPipeline
        pendingDirectory = nil
        pendingWorkspace = nil
        pendingPipeline = nil
        state = .processing(phase: "עוצר הקלטה…")

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await self.recorder.stop()
                let output = try await Self.process(
                    result: result, workspace: workspace, pipeline: pipeline,
                    sessionDirectory: directory
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
            return try await Self.summarize(
                output: output, sessionDirectory: sessionDirectory,
                engine: engine, progress: progress)
        } catch SummaryError.noAPIKey {
            NSLog("Dikta: summary skipped — API engine selected but no key configured")
            return output.index
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
    /// Live for the length of a recording: where partial work is flushed, and
    /// the transcriber consuming chunks as they close.
    private var pendingWorkspace: SessionWorkspace?
    private var pendingPipeline: ChunkTranscriptionPipeline?

    enum SummaryError: Error {
        case noAPIKey
    }

    /// The summary stage with no UI and no settings lookup, so the menu and
    /// `dikta record` produce `summary.md` through exactly the same path.
    nonisolated static func summarize(
        output: Output, sessionDirectory: URL, engine: SummaryEngine,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> URL {
        switch engine {
        case .claudeCLI:
            return try await ClaudeCLISummarizer.summarize(
                frames: output.frames, segments: output.segments,
                sessionDirectory: sessionDirectory, progress: progress)
        case .apiKey:
            guard let apiKey = KeychainStore.apiKey() else { throw SummaryError.noAPIKey }
            return try await ClaudeSummarizer.summarize(
                frames: output.frames, segments: output.segments,
                sessionDirectory: sessionDirectory, apiKey: apiKey, progress: progress)
        }
    }

    /// Where a recording goes when nothing opens a save panel: `root` (or the
    /// stored recordings folder) plus `name` (or the dated default), then the
    /// same collision rule the panel path uses.
    nonisolated static func resolveSessionDirectory(
        root: URL? = nil, name: String? = nil, date: Date = Date()
    ) -> URL {
        let parent = root ?? Settings.storedRecordingsFolder
        let folder = name.map { $0.isEmpty ? defaultSessionName(date: date) : $0 }
            ?? defaultSessionName(date: date)
        return uniquified(
            parent.appendingPathComponent(folder, isDirectory: true).standardizedFileURL)
    }

    // MARK: - Pipeline (shared with the `record-test` CLI)

    /// What `process` produced: the written `index.md` plus the material an
    /// optional summary stage needs.
    struct Output: Sendable {
        let index: URL
        let frames: [MarkdownExporter.Frame]
        let segments: [TranscriptSegment]
    }

    /// Drain whatever transcription is still in flight, then write `index.md`.
    ///
    /// Nearly all of the transcribing already happened during the recording, so
    /// what is left here is the final chunk — seconds, not the minutes the old
    /// single-pass version took. The workspace is removed only once `index.md`
    /// is safely on disk.
    @discardableResult
    nonisolated static func process(result: LiveRecorder.Result,
                                    workspace: SessionWorkspace,
                                    pipeline: ChunkTranscriptionPipeline?,
                                    sessionDirectory: URL,
                                    keepAudio: Bool = false,
                                    progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> Output {
        if let pipeline {
            progress("מסיים תמלול…")
            await pipeline.finish()
        }
        if !result.hasAudio {
            NSLog("Dikta: no system audio captured — writing frames only")
        }

        let segments = workspace.readSegments()

        progress("כותב Markdown…")
        let index = try MarkdownExporter.write(
            title: "הקלטת מסך",
            date: result.startedAt,
            duration: result.duration,
            frames: result.frames,
            segments: segments,
            to: sessionDirectory)
        workspace.remove(keepingAudio: keepAudio)
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
