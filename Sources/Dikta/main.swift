import AppKit
import whisper

/// whisper.cpp's ggml-metal backend asserts in a static destructor during a
/// normal exit(), aborting CLI runs (SIGABRT) after correct output. Flush and
/// _exit() to skip static destructors entirely.
func cleanExit(_ code: Int32) -> Never {
    fflush(stdout)
    fflush(stderr)
    _exit(code)
}

// CLI mode: dikta transcribe <wav> [--language he|en|auto] [--model <path>]
let args = CommandLine.arguments
if args.count >= 2, args[1] == "sysinfo" {
    print(String(cString: whisper_print_system_info()))
    cleanExit(0)
}

if args.count >= 3, args[1] == "transcribe" {
    cleanExit(runTranscribeCLI(Array(args.dropFirst(2))))
}

if args.count >= 3, args[1] == "detect" {
    cleanExit(runDetectCLI(Array(args.dropFirst(2))))
}

// >= 2 so a bare `dikta video` prints usage instead of launching the menu bar app.
if args.count >= 2, args[1] == "video" {
    cleanExit(runVideoCLI(Array(args.dropFirst(2))))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
