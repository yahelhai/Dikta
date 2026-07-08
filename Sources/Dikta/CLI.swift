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
