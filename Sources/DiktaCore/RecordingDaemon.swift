import Foundation
import ScreenCaptureKit

/// How `dikta record` was told to pick its display.
enum DisplaySelector: Sendable, Equatable {
    case main
    /// 1-based, matching `dikta displays` and the menu's numbered cards.
    case index(Int)
    case displayID(CGDirectDisplayID)

    func resolve(in displays: [SCDisplay]) -> SCDisplay? {
        switch self {
        case .main:
            return displays.first { $0.displayID == CGMainDisplayID() } ?? displays.first
        case .index(let index):
            guard index >= 1, index <= displays.count else { return nil }
            return displays[index - 1]
        case .displayID(let id):
            return displays.first { $0.displayID == id }
        }
    }

    func failureMessage(in displays: [SCDisplay]) -> String {
        let available = displays.isEmpty
            ? "no displays available (Screen Recording permission?)"
            : "available: " + displays.enumerated()
                .map { "\($0.offset + 1) (id=\($0.element.displayID))" }
                .joined(separator: ", ")
        switch self {
        case .main: return "no display to record — \(available)"
        case .index(let index): return "no display \(index) — \(available)"
        case .displayID(let id): return "no display with id \(id) — \(available)"
        }
    }
}

/// Everything one `dikta record` invocation needs. Parsed from argv by
/// `parseRecordArguments`, which is kept pure so it can be tested without
/// recording anything.
struct RecordingSessionOptions: Sendable, Equatable {
    var display: DisplaySelector = .main
    /// Parent folder; nil follows the stored recordings folder.
    var root: URL?
    /// Folder name inside `root`; nil uses the dated default.
    var name: String?
    /// nil follows the menu's language setting.
    var language: LanguageMode?
    /// nil follows the menu's auto-summarize setting.
    var summarize: Bool?
    /// nil follows the menu's engine setting.
    var engine: SummaryEngine?
    /// Stop automatically after this long.
    var runFor: TimeInterval?
    var maxDuration: TimeInterval = 4 * 60 * 60
    var maxFrames: Int = 5000
    var caffeinate = true
    var foreground = false
    var json = false
    /// Set by the parent when it spawns the detached child, so the parent can
    /// recognise the session it is waiting for.
    var sessionID: String?
}

/// Runs a single recording session from start to written Markdown, with no
/// AppKit anywhere: this is what both `--foreground` and the detached child
/// execute, so there is exactly one code path.
enum RecordingDaemon {
    /// Never throws — every failure is recorded in the state document and
    /// reported as an exit code.
    static func run(
        options: RecordingSessionOptions,
        sessionID: String,
        claim: RecordingRegistry.Claim,
        log: @escaping @Sendable (String) -> Void
    ) async -> Int32 {
        defer { claim.release() }

        let language = options.language ?? Settings.storedLanguageMode
        let wantsSummary = options.summarize ?? Settings.storedAutoSummarize
        let engine = options.engine ?? Settings.storedSummaryEngine

        var state = RecordingState(owner: .cli, sessionID: sessionID, phase: .starting)
        state.language = language.rawValue
        state.summarize = wantsSummary
        state.engine = engine.rawValue
        try? RecordingRegistry.write(state)

        // Resolve the display first: a bad selector should fail before anything
        // is created on disk.
        let displays: [SCDisplay]
        do {
            displays = try await LiveRecorder.availableDisplays()
        } catch {
            return fail(&state, "cannot list displays: \(error)", log: log)
        }
        guard let display = options.display.resolve(in: displays) else {
            return fail(&state, options.display.failureMessage(in: displays), log: log)
        }
        let displayIndex = displays.firstIndex { $0.displayID == display.displayID }.map { $0 + 1 }
        state.displayID = display.displayID
        state.displayIndex = displayIndex

        let pixels = LiveRecorder.pixelSize(of: display)
        log("display \(displayIndex ?? 0) (id=\(display.displayID)) \(pixels.width)x\(pixels.height)")

        let sessionDirectory = RecordingCoordinator.resolveSessionDirectory(
            root: options.root, name: options.name)
        let framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)
        state.sessionDirectory = sessionDirectory.path
        try? RecordingRegistry.write(state)
        log("session \(sessionDirectory.path)")

        do {
            try FileManager.default.createDirectory(
                at: framesDirectory, withIntermediateDirectories: true)
        } catch {
            return fail(&state, "cannot create \(framesDirectory.path): \(error)", log: log)
        }

        let recorder = LiveRecorder()
        // nonisolated(unsafe): SCDisplay is an immutable descriptor that simply
        // isn't marked Sendable, same as the menu path assumes.
        nonisolated(unsafe) let selected = display

        let gate = StopGate(
            owner: .cli,
            sessionID: sessionID,
            deadline: options.runFor.map { Date().addingTimeInterval($0) },
            maximumDuration: Date().addingTimeInterval(options.maxDuration),
            frameLimit: options.maxFrames,
            frameCount: { [weak recorder] in recorder?.keptFrameCount ?? 0 }
        )
        // Armed before capture starts, so a stop arriving during startup is not
        // lost — it resolves the gate the moment the wait begins.
        gate.begin()
        recorder.onStreamError = { error in gate.resolve(.streamError("\(error)")) }

        do {
            try await recorder.start(display: selected, framesDirectory: framesDirectory)
        } catch {
            gate.end()
            try? FileManager.default.removeItem(at: sessionDirectory)
            return fail(&state, "cannot start capture: \(error)", log: log)
        }

        var caffeinated: Process?
        if options.caffeinate {
            caffeinated = startCaffeinate()
        }
        defer { caffeinated?.terminate() }

        state.phase = .recording
        state.startedAt = Date()
        try? RecordingRegistry.write(state)
        // The line a caller waits for: capture is live from here on.
        log("recording — \(stopHint(options))")

        let reason = await gate.wait()
        // Before post-processing, never after: from here a second ^C must kill.
        gate.end()
        log("stopping — \(reason)")

        state.phase = .processing
        state.stoppedAt = Date()
        state.stopReason = "\(reason)"
        state.label = "עוצר הקלטה…"
        try? RecordingRegistry.write(state)

        let result: LiveRecorder.Result
        do {
            result = try await recorder.stop()
        } catch {
            return fail(&state, "capture failed: \(error)", log: log)
        }
        state.frameCount = result.frames.count
        state.audioTempPath = result.audioURL?.path
        try? RecordingRegistry.write(state)
        log("captured \(result.frames.count) frames / "
            + String(format: "%.1f", result.duration) + "s"
            + (result.audioURL == nil ? " (no system audio)" : ""))

        // A session stopped before a single frame landed is not worth a folder.
        if result.frames.isEmpty && reason == .request && state.startedAt.timeIntervalSinceNow > -1 {
            try? FileManager.default.removeItem(at: sessionDirectory)
            state.phase = .cancelled
            state.finishedAt = Date()
            state.exitCode = 0
            try? RecordingRegistry.write(state)
            log("cancelled before capture produced anything")
            return 0
        }

        let output: RecordingCoordinator.Output
        do {
            let snapshot = state
            output = try await RecordingCoordinator.process(
                result: result, sessionDirectory: sessionDirectory,
                mode: language, transcriber: Transcriber()
            ) { phase in
                var progress = snapshot
                progress.label = phase
                try? RecordingRegistry.write(progress)
                log(phase)
            }
        } catch {
            return fail(&state, "processing failed: \(error)", log: log)
        }
        state.indexPath = output.index.path
        state.label = nil
        try? RecordingRegistry.write(state)
        print(output.index.path)

        guard wantsSummary else { return finish(&state, exitCode: 0, log: log) }

        state.label = "מסכם עם Claude…"
        try? RecordingRegistry.write(state)
        log("מסכם עם Claude…")
        do {
            let snapshot = state
            let summary = try await RecordingCoordinator.summarize(
                output: output, sessionDirectory: sessionDirectory, engine: engine
            ) { phase in
                var progress = snapshot
                progress.label = phase
                try? RecordingRegistry.write(progress)
                log(phase)
            }
            state.summaryPath = summary.path
            print(summary.path)
            return finish(&state, exitCode: 0, log: log)
        } catch {
            // index.md is already written and printed; the summary is the only
            // casualty, so this is partial success rather than failure.
            state.error = "summary failed: \(error)"
            log("summary failed: \(error)")
            return finish(&state, exitCode: 4, log: log)
        }
    }

    // MARK: - Helpers

    private static func stopHint(_ options: RecordingSessionOptions) -> String {
        var parts: [String] = []
        if let runFor = options.runFor { parts.append("stopping after \(Int(runFor.rounded()))s") }
        parts.append(options.foreground ? "^C or `dikta stop`" : "`dikta stop`")
        return parts.joined(separator: ", ")
    }

    /// Keeps the display awake for the length of the recording. A screen that
    /// sleeps mid-lecture is the likeliest way an unattended run ends up with two
    /// identical frames; `-w` makes it exit with us even if we are killed.
    private static func startCaffeinate() -> Process? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-d", "-i", "-w", "\(ProcessInfo.processInfo.processIdentifier)"]
        try? process.run()
        return process
    }

    private static func fail(
        _ state: inout RecordingState, _ message: String,
        log: @escaping @Sendable (String) -> Void
    ) -> Int32 {
        state.phase = .failed
        state.error = message
        state.finishedAt = Date()
        state.exitCode = 1
        try? RecordingRegistry.write(state)
        log("error: \(message)")
        return 1
    }

    private static func finish(
        _ state: inout RecordingState, exitCode: Int32,
        log: @escaping @Sendable (String) -> Void
    ) -> Int32 {
        state.phase = .done
        state.finishedAt = Date()
        state.exitCode = exitCode
        state.label = nil
        try? RecordingRegistry.write(state)
        return exitCode
    }
}
