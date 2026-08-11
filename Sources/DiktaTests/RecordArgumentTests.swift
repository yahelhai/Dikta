import Foundation

@testable import DiktaCore

private func parsed(_ args: [String]) -> RecordingSessionOptions? {
    guard case .success(let options) = parseRecordArguments(args) else { return nil }
    return options
}

private func rejected(_ args: [String]) -> String? {
    guard case .failure(let error) = parseRecordArguments(args) else { return nil }
    return error.message
}

/// Parsing is a pure function precisely so it can be checked here, without
/// starting a capture to find out that a flag was misspelled.
func registerRecordArgumentTests(_ runner: TestRunner) {
    runner.test("record args: the defaults follow the menu rather than inventing their own") {
        context in
        guard let options = parsed([]) else { return context.fail("empty arguments rejected") }
        context.expectEqual(options.display, .main)
        context.expect(options.root == nil, "no -o should mean the stored recordings folder")
        context.expect(options.name == nil, "no --name should mean the dated default")
        // nil, not a hardcoded value: these three defer to the menu's settings.
        context.expect(options.language == nil, "language should default to the setting")
        context.expect(options.summarize == nil, "summarize should default to the setting")
        context.expect(options.engine == nil, "engine should default to the setting")
        context.expect(options.caffeinate, "caffeinate should default on")
        context.expect(!options.foreground, "record should detach by default")
    }

    runner.test("record args: display selectors") { context in
        context.expectEqual(parsed(["--display", "2"])?.display, .index(2))
        context.expectEqual(parsed(["--display-id", "22"])?.display, .displayID(22))
        // Last one wins rather than being diagnosed as a conflict.
        context.expectEqual(
            parsed(["--display", "2", "--display-id", "22"])?.display, .displayID(22))
        context.expectEqual(
            parsed(["--display-id", "22", "--display", "3"])?.display, .index(3))

        context.expect(rejected(["--display", "0"]) != nil, "--display 0 should be rejected")
        context.expect(rejected(["--display", "-1"]) != nil, "--display -1 should be rejected")
        context.expect(rejected(["--display", "two"]) != nil, "--display two should be rejected")
        context.expect(rejected(["--display-id", "x"]) != nil, "--display-id x should be rejected")
    }

    runner.test("record args: language and engine aliases") { context in
        context.expectEqual(parsed(["--language", "he"])?.language, .hebrew)
        context.expectEqual(parsed(["--language", "hebrew"])?.language, .hebrew)
        context.expectEqual(parsed(["--language", "en"])?.language, .english)
        context.expectEqual(parsed(["--language", "english"])?.language, .english)
        context.expectEqual(parsed(["--language", "auto"])?.language, .auto)
        context.expect(rejected(["--language", "fr"]) != nil, "unknown language should be rejected")

        for alias in ["cli", "claude", "claude-cli"] {
            context.expectEqual(parsed(["--engine", alias])?.engine, .claudeCLI, alias)
        }
        for alias in ["api", "apikey", "api-key"] {
            context.expectEqual(parsed(["--engine", alias])?.engine, .apiKey, alias)
        }
        context.expect(rejected(["--engine", "gpt"]) != nil, "unknown engine should be rejected")
    }

    runner.test("record args: --summarize is tri-state") { context in
        context.expect(parsed([])?.summarize == nil, "absent means follow the setting")
        context.expectEqual(parsed(["--summarize"])?.summarize, true)
        context.expectEqual(parsed(["--no-summarize"])?.summarize, false)
        // Last wins, so a wrapper script can append an override.
        context.expectEqual(parsed(["--summarize", "--no-summarize"])?.summarize, false)
        context.expectEqual(parsed(["--no-summarize", "--summarize"])?.summarize, true)
    }

    runner.test("record args: output root and name") { context in
        let options = parsed(["-o", "/tmp/out", "--name", "lecture"])
        context.expectEqual(options?.root?.standardizedFileURL.path, "/tmp/out")
        context.expectEqual(options?.name, "lecture")
        context.expectEqual(parsed(["--output", "/tmp/out"])?.root?.standardizedFileURL.path,
                            "/tmp/out")
    }

    runner.test("record args: limits must be positive numbers") { context in
        context.expectEqual(parsed(["--for", "90"])?.runFor, 90)
        context.expectEqual(parsed(["--max-frames", "12"])?.maxFrames, 12)
        context.expectEqual(parsed(["--max-duration", "60"])?.maxDuration, 60)

        for bad in [["--for", "0"], ["--for", "-5"], ["--for", "soon"],
                    ["--max-frames", "0"], ["--max-duration", "0"]] {
            context.expect(rejected(bad) != nil, "\(bad) should be rejected")
        }
    }

    runner.test("record args: a flag missing its value is an error, not a silent skip") { context in
        // The older parser in CLI.swift breaks out of its switch here and ignores
        // the flag entirely, which turns a typo into a recording with the wrong
        // settings. This one refuses.
        for flag in ["--display", "--display-id", "-o", "--name", "--language",
                     "--engine", "--for", "--max-frames", "--max-duration"] {
            context.expect(rejected([flag]) != nil, "\(flag) with no value should be rejected")
        }
    }

    runner.test("record args: an unknown flag is refused rather than ignored") { context in
        context.expect(rejected(["--sumarize"]) != nil, "a typo should not be silently dropped")
        context.expect(rejected(["extra"]) != nil, "a stray positional should be refused")
    }
}
