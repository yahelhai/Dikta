import Foundation

@testable import DiktaCore

/// The menu bar icon cannot be inspected automatically, so the *precedence* is
/// what gets pinned down here — which is where the bug actually was.
func registerIconTests(_ runner: TestRunner) {
    typealias Icon = StatusItemController.IconState
    let resolve = StatusItemController.resolveIcon

    runner.test("icon: nothing happening is idle") { context in
        context.expectEqual(resolve(.idle, false), Icon.idle)
    }

    runner.test("icon: a screen recording alone shows the circle") { context in
        context.expectEqual(resolve(.idle, true), Icon.screenRecording)
    }

    runner.test("icon: dictation alone shows dictation") { context in
        context.expectEqual(resolve(.recording, false), Icon.recording)
        context.expectEqual(resolve(.transcribing, false), Icon.transcribing)
    }

    // The regression. Dictation during a screen recording used to overwrite the
    // circle, and nothing ever put it back — the menu bar then looked idle for
    // the rest of the lecture, with capture still running.
    runner.test("icon: dictation takes over during a recording, then hands it back") { context in
        context.expectEqual(resolve(.recording, true), Icon.recording,
                            "dictation should show while it is happening")
        context.expectEqual(resolve(.transcribing, true), Icon.transcribing,
                            "transcription should show while it is happening")
        context.expectEqual(resolve(.idle, true), Icon.screenRecording,
                            "the circle must come back once dictation is done")
    }

    runner.test("icon: resolution has no memory") { context in
        // Whatever order states arrive in, the same inputs give the same icon —
        // which is what makes the restore automatic rather than something a
        // caller has to remember to do.
        for _ in 0..<3 {
            context.expectEqual(resolve(.recording, true), Icon.recording)
            context.expectEqual(resolve(.idle, true), Icon.screenRecording)
        }
    }
}
