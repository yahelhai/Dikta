import AppKit
import whisper

// The only surface the Dikta executable is allowed to touch. Everything else in
// DiktaCore stays internal, so adding a subcommand never means editing
// main.swift — and the tests reach the internals with `@testable import`.

/// whisper.cpp's ggml-metal backend asserts in a static destructor during a
/// normal exit(), aborting CLI runs (SIGABRT) after correct output. Flush and
/// `_exit()` to skip static destructors entirely.
public func cleanExit(_ code: Int32) -> Never {
    fflush(stdout)
    fflush(stderr)
    _exit(code)
}

/// Runs `name` as a headless subcommand, or returns nil when it isn't one —
/// in which case the caller launches the menu-bar app.
public func runSubcommand(_ name: String, _ arguments: [String]) -> Int32? {
    switch name {
    case "sysinfo":
        print(String(cString: whisper_print_system_info()))
        return 0
    case "transcribe": return runTranscribeCLI(arguments)
    case "detect": return runDetectCLI(arguments)
    case "video": return runVideoCLI(arguments)
    case "displays": return runDisplaysCLI(arguments)
    case "record": return runRecordCLI(arguments)
    // Hidden harness for the live screen recorder (see CLI.swift).
    case "record-test": return runRecordTestCLI(arguments)
    default: return nil
    }
}

/// `NSApplication.delegate` is unowned — without this the delegate would be
/// released the moment `runMenuBarApp` returns into `app.run()`.
@MainActor private var retainedDelegate: AppDelegate?

/// Launches the menu-bar app. Does not return.
@MainActor
public func runMenuBarApp() -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    retainedDelegate = delegate
    app.delegate = delegate
    app.run()
    cleanExit(0)
}
