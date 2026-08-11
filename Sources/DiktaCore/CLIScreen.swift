import Foundation
import ScreenCaptureKit

// The screen-recording subcommands. Kept apart from CLI.swift, which is already
// long, but following the same conventions: results on stdout, progress and
// errors on stderr with a [tag], and a hand-rolled while/switch parser.

struct CLIError: Error, Equatable {
    let message: String
    var code: Int32 = 2
}

let recordUsage = """
    usage: dikta record [--display <n> | --display-id <id>] [-o <dir>] [--name <folder>]
                        [--language he|en|auto] [--summarize | --no-summarize]
                        [--engine cli|api] [--for <seconds>]
                        [--max-duration <seconds>] [--max-frames <n>]
                        [--foreground] [--no-caffeinate] [--json]

    Records a display plus system audio, then transcribes and writes
    <session>/index.md (and summary.md when summarising). Detaches by default and
    returns once capture is actually live; stop it with `dikta stop`.

    """

/// Pure so it can be tested without recording anything.
func parseRecordArguments(_ args: [String]) -> Result<RecordingSessionOptions, CLIError> {
    var options = RecordingSessionOptions()

    /// Reads the value after a flag, or reports the flag as incomplete.
    func value(_ index: inout Int, _ flag: String) throws -> String {
        index += 1
        guard index < args.count else { throw CLIError(message: "\(flag) needs a value") }
        return args[index]
    }

    var index = 0
    do {
        while index < args.count {
            switch args[index] {
            case "--display":
                let raw = try value(&index, "--display")
                guard let number = Int(raw), number >= 1 else {
                    throw CLIError(message: "--display takes a 1-based number, got \"\(raw)\"")
                }
                options.display = .index(number)
            case "--display-id":
                let raw = try value(&index, "--display-id")
                guard let id = UInt32(raw) else {
                    throw CLIError(message: "--display-id takes a numeric display id, got \"\(raw)\"")
                }
                options.display = .displayID(id)
            case "-o", "--output":
                options.root = URL(fileURLWithPath: try value(&index, "-o"), isDirectory: true)
            case "--name":
                options.name = try value(&index, "--name")
            case "--language":
                let raw = try value(&index, "--language")
                switch raw {
                case "he", "hebrew": options.language = .hebrew
                case "en", "english": options.language = .english
                case "auto": options.language = .auto
                default: throw CLIError(message: "unknown language: \(raw)")
                }
            case "--summarize": options.summarize = true
            case "--no-summarize": options.summarize = false
            case "--engine":
                let raw = try value(&index, "--engine")
                switch raw {
                case "cli", "claude", "claude-cli": options.engine = .claudeCLI
                case "api", "apikey", "api-key": options.engine = .apiKey
                default: throw CLIError(message: "unknown engine: \(raw)")
                }
            case "--for":
                let raw = try value(&index, "--for")
                guard let seconds = Double(raw), seconds > 0 else {
                    throw CLIError(message: "--for takes a positive number of seconds, got \"\(raw)\"")
                }
                options.runFor = seconds
            case "--max-duration":
                let raw = try value(&index, "--max-duration")
                guard let seconds = Double(raw), seconds > 0 else {
                    throw CLIError(message: "--max-duration takes a positive number of seconds")
                }
                options.maxDuration = seconds
            case "--max-frames":
                let raw = try value(&index, "--max-frames")
                guard let frames = Int(raw), frames > 0 else {
                    throw CLIError(message: "--max-frames takes a positive count")
                }
                options.maxFrames = frames
            case "--foreground": options.foreground = true
            case "--no-caffeinate": options.caffeinate = false
            case "--json": options.json = true
            case "--session-id":
                options.sessionID = try value(&index, "--session-id")
            default:
                throw CLIError(message: "unknown argument: \(args[index])")
            }
            index += 1
        }
    } catch let error as CLIError {
        return .failure(error)
    } catch {
        return .failure(CLIError(message: "\(error)"))
    }
    return .success(options)
}

// MARK: - record

func runRecordCLI(_ args: [String]) -> Int32 {
    let options: RecordingSessionOptions
    switch parseRecordArguments(args) {
    case .success(let parsed): options = parsed
    case .failure(let error):
        note("record", error.message)
        FileHandle.standardError.write(Data(recordUsage.utf8))
        return error.code
    }

    guard modelIsInstalled() else { return 3 }
    if let busy = busyMessage() {
        note("record", busy)
        return 6
    }

    // Detached is the default: a caller's shell can be killed with its process
    // group, and an agent needs a synchronous "capture is live" answer anyway.
    if !options.foreground && options.sessionID == nil {
        return runDetachedRecord(options: options, rawArguments: args)
    }

    let sessionID = options.sessionID ?? UUID().uuidString
    guard let claim = RecordingRegistry.claimWithRetry(.cli) else {
        note("record", "another recording is already running")
        return 6
    }

    return blockingTask { await RecordingDaemon.run(
        options: options, sessionID: sessionID, claim: claim,
        log: { note("record", $0) })
    }
}

/// Whichever owner is currently busy, phrased for a refusal.
private func busyMessage() -> String? {
    for (owner, state, live) in RecordingRegistry.activeOwners()
    where live && !state.phase.isTerminal {
        switch owner {
        case .cli:
            let where_ = state.sessionDirectory.map { " (\($0))" } ?? ""
            return state.phase == .processing
                ? "a recording is still being processed\(where_) — wait for it to finish"
                : "already recording\(where_) — stop it with `dikta stop`"
        case .app:
            return "the Dikta menu bar app is recording — stop it from the menu"
        }
    }
    return nil
}

private func modelIsInstalled() -> Bool {
    let path = ModelManager.shared.localURL(for: ModelManager.stockTurboQ5).path
    guard FileManager.default.fileExists(atPath: path) else {
        note("record", "model not found: \(path) — run `make models`")
        return false
    }
    return true
}

// MARK: - displays

let displaysUsage = "usage: dikta displays [--json] [--identify [seconds]]\n"

func runDisplaysCLI(_ args: [String]) -> Int32 {
    var json = false
    var identify = false
    var seconds: Double = 4

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--json": json = true
        case "--identify":
            identify = true
            // The duration is optional, so only consume the next argument when
            // it actually looks like one.
            if index + 1 < args.count, let value = Double(args[index + 1]), value > 0 {
                seconds = value
                index += 1
            }
        default:
            FileHandle.standardError.write(Data(displaysUsage.utf8))
            return 2
        }
        index += 1
    }

    if identify { return identifyDisplays(seconds: seconds) }

    let asJSON = json
    return blockingTask {
        do {
            let displays = try await LiveRecorder.availableDisplays()
            // The index is the same 1-based number the menu rows and the
            // on-screen numbered cards show, so a human can read a card and
            // hand the number straight to --display.
            if asJSON {
                let rows = displays.enumerated().map { offset, display -> [String: Any] in
                    let pixels = LiveRecorder.pixelSize(of: display)
                    return [
                        "index": offset + 1,
                        "id": Int(display.displayID),
                        "main": display.displayID == CGMainDisplayID(),
                        "width": pixels.width,
                        "height": pixels.height,
                    ]
                }
                printJSON(["displays": rows])
            } else {
                for (offset, display) in displays.enumerated() {
                    let pixels = LiveRecorder.pixelSize(of: display)
                    let main = display.displayID == CGMainDisplayID() ? "  main" : ""
                    print("\(offset + 1)  id=\(display.displayID)  "
                          + "\(pixels.width)x\(pixels.height)px\(main)")
                }
            }
            return 0
        } catch {
            note("displays", "\(error)")
            return 1
        }
    }
}

// MARK: - Shared helpers

func note(_ tag: String, _ message: String) {
    FileHandle.standardError.write(Data("[\(tag)] \(message)\n".utf8))
}

func printJSON(_ payload: [String: Any]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
        let text = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(text)
}

/// The semaphore bridge the rest of CLI.swift already uses, factored out.
func blockingTask(_ body: @escaping @Sendable () async -> Int32) -> Int32 {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var exitCode: Int32 = 0
    Task {
        defer { semaphore.signal() }
        exitCode = await body()
    }
    semaphore.wait()
    return exitCode
}
