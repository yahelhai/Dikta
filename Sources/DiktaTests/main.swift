import Foundation

@testable import DiktaCore

// Entry point for `make test`. Suites register themselves below; pass a
// substring to narrow the run, e.g. `swift run DiktaTests registry`.
let arguments = Array(CommandLine.arguments.dropFirst())

// Some tests need a second process holding a lock, and re-running this binary is
// the cheapest way to get one.
if arguments.first == "--hold-lock" {
    runLockHolderMode(Array(arguments.dropFirst()))
}

let runner = TestRunner(filter: arguments)

print("DiktaCore tests")
registerSmokeTests(runner)
registerRegistryTests(runner)
registerSessionDirectoryTests(runner)
registerStopGateTests(runner)

let code = await runner.run()
cleanExit(code)
