import CoreGraphics
import Foundation

// dikta detect <wav> — print the auto-detected language (verifies the routing path)
func runDetectCLI(_ args: [String]) -> Int32 {
    guard let wavPath = args.first else {
        FileHandle.standardError.write("usage: dikta detect <audio-file>\n".data(using: .utf8)!)
        return 2
    }
    let modelPath = ModelManager.shared.localURL(for: ModelManager.stockTurboQ5).path
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task {
        defer { semaphore.signal() }
        do {
            let samples = try AudioFileLoader.loadSamples(from: URL(fileURLWithPath: wavPath))
            let t0 = Date()
            let lang = try await Transcriber().detectLanguage(samples: samples, modelPath: modelPath)
            print("\(lang) (\(String(format: "%.2f", Date().timeIntervalSince(t0)))s)")
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
    }
    semaphore.wait()
    return exitCode
}

private let videoUsage =
    "usage: dikta video <video-file> [-o <dest-dir>] [--language he|en|auto] "
    + "[--summarize] [--engine cli|api]\n"

// dikta video <file> [-o <destDir>] [--language he|en|auto] [--summarize] [--engine cli|api]
// Turns a video into <destDir>/<basename>/index.md + frames/, and with
// --summarize also <destDir>/<basename>/summary.md via Claude — either through
// the local Claude Code CLI (default, billed to the Claude subscription) or the
// Messages API with the Keychain key (--engine api).
func runVideoCLI(_ args: [String]) -> Int32 {
    var videoPath: String?
    var destPath: String?
    var mode: LanguageMode = .auto
    var summarize = false
    var engine: SummaryEngine = .claudeCLI

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--summarize":
            summarize = true
        case "-o", "--output":
            i += 1
            guard i < args.count else { break }
            destPath = args[i]
        case "--engine":
            i += 1
            guard i < args.count else { break }
            switch args[i] {
            case "cli", "claude", "claude-cli": engine = .claudeCLI
            case "api", "apikey", "api-key": engine = .apiKey
            default:
                FileHandle.standardError.write("unknown engine: \(args[i])\n".data(using: .utf8)!)
                return 2
            }
        case "--language":
            i += 1
            guard i < args.count else { break }
            switch args[i] {
            case "he", "hebrew": mode = .hebrew
            case "en", "english": mode = .english
            case "auto": mode = .auto
            default:
                FileHandle.standardError.write("unknown language: \(args[i])\n".data(using: .utf8)!)
                return 2
            }
        default:
            videoPath = args[i]
        }
        i += 1
    }

    guard let videoPath else {
        FileHandle.standardError.write(videoUsage.data(using: .utf8)!)
        return 2
    }
    let videoURL = URL(fileURLWithPath: videoPath).standardizedFileURL
    guard FileManager.default.fileExists(atPath: videoURL.path) else {
        FileHandle.standardError.write("file not found: \(videoURL.path)\n".data(using: .utf8)!)
        return 2
    }
    // Default destination: next to the video.
    let destination = destPath.map { URL(fileURLWithPath: $0) }
        ?? videoURL.deletingLastPathComponent()

    let stockModel = ModelManager.shared.localURL(for: ModelManager.stockTurboQ5).path
    guard FileManager.default.fileExists(atPath: stockModel) else {
        FileHandle.standardError.write("model not found: \(stockModel)\n".data(using: .utf8)!)
        return 3
    }

    // How summary.md gets written (nil = don't summarize). The CLI engine needs
    // no key; the API engine reads one from the Keychain, and without it we
    // still produce index.md and report the missing summary via the exit code.
    var summaryRequest: VideoFileProcessor.SummaryRequest?
    if summarize {
        switch engine {
        case .claudeCLI:
            // A missing `claude` binary surfaces as a summaryError (exit 4).
            summaryRequest = .claudeCLI
        case .apiKey:
            if let apiKey = KeychainStore.apiKey() {
                summaryRequest = .api(key: apiKey)
            } else {
                FileHandle.standardError.write("""
                    error: no Anthropic API key found in the Keychain — summary skipped.
                    שגיאה: לא נמצא מפתח Anthropic API — הסיכום דולג. הגדר מפתח מתפריט Dikta \
                    ("הגדר Anthropic API Key…"). ה-index.md נוצר כרגיל.

                    """.data(using: .utf8)!)
            }
        }
    }

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    let selectedMode = mode
    let wantsSummary = summarize
    let request = summaryRequest

    Task {
        defer { semaphore.signal() }
        do {
            let reporter = ProgressReporter()
            let output = try await VideoFileProcessor.process(
                videoURL: videoURL,
                destinationDirectory: destination,
                mode: selectedMode,
                transcriber: Transcriber(),
                summary: request
            ) { phase, fraction in
                reporter.report(phase: phase, fraction: fraction)
            }
            print(output.index.path)
            if let summary = output.summary {
                print(summary.path)
            }
            if let failure = output.summaryError {
                FileHandle.standardError.write(
                    "error: summary failed: \(failure)\n".data(using: .utf8)!)
            }
            // Partial success: index.md is there, the summary isn't.
            if wantsSummary && output.summary == nil { exitCode = 4 }
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
    }
    semaphore.wait()
    return exitCode
}

// dikta record-test <seconds> [-o <destDir>] [--language he|en|auto] [--say <text>]
// Hidden headless harness for the live screen recorder: records the main display
// for N seconds (optionally speaking Hebrew through `say` so there is system
// audio to capture), then runs the exact same post-processing the menu uses.
func runRecordTestCLI(_ args: [String]) -> Int32 {
    var seconds: Double = 10
    var destPath: String?
    var mode: LanguageMode = .hebrew
    var sayText: String? = "שלום, זו בדיקה של הקלטת מסך חיה עם תמלול בעברית."

    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o", "--output":
            i += 1
            guard i < args.count else { break }
            destPath = args[i]
        case "--language":
            i += 1
            guard i < args.count else { break }
            switch args[i] {
            case "he", "hebrew": mode = .hebrew
            case "en", "english": mode = .english
            default: mode = .auto
            }
        case "--say":
            i += 1
            guard i < args.count else { break }
            sayText = args[i].isEmpty ? nil : args[i]
        case "--silent":
            sayText = nil
        default:
            if let value = Double(args[i]) { seconds = value }
        }
        i += 1
    }

    let sessionDirectory = destPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("dikta-record-test", isDirectory: true)
    let framesDirectory = sessionDirectory.appendingPathComponent("frames", isDirectory: true)

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    let duration = seconds
    let narration = sayText
    let selectedMode = mode

    Task {
        defer { semaphore.signal() }
        let recorder = LiveRecorder()
        do {
            let displays = try await LiveRecorder.availableDisplays()
            guard let display = displays.first(where: { $0.displayID == CGMainDisplayID() })
                    ?? displays.first else {
                throw DiktaError.screenCaptureFailed("no displays (Screen Recording permission?)")
            }
            note("display \(display.displayID) \(LiveRecorder.pixelSize(of: display))")

            let workspace = SessionWorkspace(session: sessionDirectory)
            let meta = SessionWorkspace.Meta(
                startedAt: Date(), modelPath: "", language: nil,
                chunkSeconds: 30, title: "הקלטת מסך")
            try workspace.create()
            try workspace.writeMeta(meta)
            let pipeline = ChunkTranscriptionPipeline(
                workspace: workspace, meta: meta, mode: selectedMode,
                transcriber: Transcriber()
            ) { progress in
                note("transcribed \(Int(progress.transcribedSeconds))s / \(progress.chunks) chunks")
            }

            // A short chunk so a 60-second harness run still exercises rotation.
            try await recorder.start(
                display: display,
                framesDirectory: framesDirectory,
                audioDirectory: workspace.root,
                chunkSeconds: 30,
                onFrame: { try? workspace.appendFrame($0) },
                onChunk: { pipeline.submit($0) })
            note("recording \(duration)s…")
            if let narration {
                // `say` is a separate process, so SCK captures it as system audio
                // even though we exclude our own.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
                process.arguments = ["-v", "Carmit", "-r", "150", narration]
                try? process.run()
            }
            try await Task.sleep(for: .seconds(duration))

            let result = try await recorder.stop()
            note("frames=\(result.frames.count) audio=\(result.hasAudio ? "yes" : "none") duration=\(String(format: "%.1f", result.duration))s")

            let output = try await RecordingCoordinator.process(
                result: result, workspace: workspace, pipeline: pipeline,
                sessionDirectory: sessionDirectory
            ) { phase in
                note(phase)
            }
            print(output.index.path)
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            await recorder.cancel()
            exitCode = 1
        }
    }
    semaphore.wait()
    return exitCode
}

private func note(_ message: String) {
    FileHandle.standardError.write("[record-test] \(message)\n".data(using: .utf8)!)
}

/// Throttled stderr progress so a long video doesn't spam the terminal.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastLine: String?

    func report(phase: VideoFileProcessor.Phase, fraction: Double) {
        let line = "\(phase.label) \(Int((fraction * 10).rounded(.down)) * 10)%"
        lock.lock()
        let isNew = line != lastLine
        lastLine = line
        lock.unlock()
        guard isNew else { return }
        FileHandle.standardError.write("\(line)\n".data(using: .utf8)!)
    }
}

// dikta transcribe <wav> [--language he|en|auto] [--model <path>]
func runTranscribeCLI(_ args: [String]) -> Int32 {
    var wavPath: String?
    var language: String? = nil
    var modelPath: String?

    var i = 0
    while i < args.count {
        switch args[i] {
        case "--language":
            i += 1
            guard i < args.count else { break }
            language = args[i] == "auto" ? nil : args[i]
        case "--model":
            i += 1
            guard i < args.count else { break }
            modelPath = args[i]
        default:
            wavPath = args[i]
        }
        i += 1
    }

    guard let wavPath else {
        FileHandle.standardError.write("usage: dikta transcribe <audio-file> [--language he|en|auto] [--model <path>]\n".data(using: .utf8)!)
        return 2
    }

    let resolvedModel = modelPath
        ?? ModelManager.shared.localURL(for: ModelManager.stockTurboQ5).path
    guard FileManager.default.fileExists(atPath: resolvedModel) else {
        FileHandle.standardError.write("model not found: \(resolvedModel)\n".data(using: .utf8)!)
        return 3
    }

    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    let lang = language

    Task {
        defer { semaphore.signal() }
        do {
            let samples = try AudioFileLoader.loadSamples(from: URL(fileURLWithPath: wavPath))
            FileHandle.standardError.write("loaded \(samples.count) samples (\(String(format: "%.1f", Double(samples.count) / 16000))s)\n".data(using: .utf8)!)
            let transcriber = Transcriber()
            let t0 = Date()
            let text = try await transcriber.transcribe(
                samples: samples, language: lang, modelPath: resolvedModel)
            let totalTime = Date().timeIntervalSince(t0)
            FileHandle.standardError.write(String(format: "load+inference: %.2fs\n", totalTime).data(using: .utf8)!)
            print(text)
        } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
    }
    semaphore.wait()
    return exitCode
}
