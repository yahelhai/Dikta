import AppKit
import whisper

// CLI mode: dikta transcribe <wav> [--language he|en|auto] [--model <path>]
// (implemented in M1; for M0 we just prove the whisper framework links and sees Metal)
let args = CommandLine.arguments
if args.count >= 2, args[1] == "sysinfo" {
    print(String(cString: whisper_print_system_info()))
    exit(0)
}

if args.count >= 3, args[1] == "transcribe" {
    exit(runTranscribeCLI(Array(args.dropFirst(2))))
}

if args.count >= 3, args[1] == "detect" {
    exit(runDetectCLI(Array(args.dropFirst(2))))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
