import Foundation

@testable import DiktaCore

// Entry point for `make test`. Suites register themselves below; pass a
// substring to narrow the run, e.g. `swift run DiktaTests registry`.
let runner = TestRunner(filter: Array(CommandLine.arguments.dropFirst()))

print("DiktaCore tests")
registerSmokeTests(runner)

let code = await runner.run()
cleanExit(code)
