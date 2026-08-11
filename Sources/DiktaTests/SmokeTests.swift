import Foundation

@testable import DiktaCore

/// Proves the split holds: the runner sees DiktaCore's internals, and the
/// subcommand table answers for real commands only.
func registerSmokeTests(_ runner: TestRunner) {
    runner.test("subcommands: an unknown word is not handled") { context in
        context.expectNil(runSubcommand("definitely-not-a-command", []))
    }

    runner.test("subcommands: the known ones are claimed") { context in
        // Passing no arguments makes each print usage and return 2 without doing
        // any work, so this stays fast and side-effect free.
        for name in ["transcribe", "detect", "video"] {
            context.expectEqual(runSubcommand(name, []), 2, name)
        }
    }
}
