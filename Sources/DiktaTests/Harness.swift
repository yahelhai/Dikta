import Foundation

// A hand-rolled test harness, because neither standard option runs here: XCTest
// ships only with Xcode, and the Testing.framework bundled with the Command Line
// Tools is missing its lib_TestingInterop.dylib, so `swift test` dies at dlopen.
// Dikta's stated requirement is Command Line Tools only, so the runner is an
// ordinary executable target instead — `@testable import` still gives it
// internal access to DiktaCore.

/// Collects the failures of a single test case.
final class TestContext: @unchecked Sendable {
    private let lock = NSLock()
    private var failures: [String] = []

    var recorded: [String] {
        lock.lock()
        defer { lock.unlock() }
        return failures
    }

    func fail(_ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let name = URL(fileURLWithPath: "\(file)").lastPathComponent
        lock.lock()
        failures.append("\(message)  (\(name):\(line))")
        lock.unlock()
    }

    func expect(
        _ condition: Bool, _ message: @autoclosure () -> String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard !condition else { return }
        fail(message(), file: file, line: line)
    }

    func expectEqual<T: Equatable>(
        _ actual: T, _ expected: T, _ label: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard actual != expected else { return }
        let prefix = label().isEmpty ? "" : "\(label()): "
        fail("\(prefix)expected \(expected), got \(actual)", file: file, line: line)
    }

    func expectNil(
        _ value: Any?, _ label: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let value else { return }
        let prefix = label().isEmpty ? "" : "\(label()): "
        fail("\(prefix)expected nil, got \(value)", file: file, line: line)
    }
}

struct TestCase {
    let name: String
    let body: (TestContext) async throws -> Void
}

/// Runs cases in declaration order and reports one line each.
final class TestRunner {
    private var cases: [TestCase] = []
    private var only: Set<String> = []

    /// `swift run DiktaTests <substring>` narrows the run while iterating.
    init(filter: [String] = []) {
        only = Set(filter)
    }

    func test(_ name: String, _ body: @escaping (TestContext) async throws -> Void) {
        cases.append(TestCase(name: name, body: body))
    }

    func run() async -> Int32 {
        let selected = only.isEmpty
            ? cases
            : cases.filter { name in only.contains { name.name.contains($0) } }
        guard !selected.isEmpty else {
            print("no tests matched \(only.joined(separator: ", "))")
            return 1
        }

        var passed = 0
        var failed = 0
        for testCase in selected {
            let context = TestContext()
            do {
                try await testCase.body(context)
            } catch {
                context.fail("threw \(error)")
            }
            let failures = context.recorded
            if failures.isEmpty {
                passed += 1
                print("  ✓ \(testCase.name)")
            } else {
                failed += 1
                print("  ✗ \(testCase.name)")
                for failure in failures { print("      \(failure)") }
            }
        }

        print("")
        print(failed == 0
            ? "\(passed) passed"
            : "\(passed) passed, \(failed) FAILED")
        return failed == 0 ? 0 : 1
    }
}

// MARK: - Helpers shared by the suites

/// A scratch directory removed when `body` returns.
func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async rethrows -> T {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dikta-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: url) }
    return try await body(url)
}

/// Runs a helper process and returns it without waiting — the caller decides how
/// it dies. Used to prove that locks survive (and release on) another process.
@discardableResult
func spawnHelper(_ command: String) -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardOutput = Pipe()
    process.standardError = Pipe()
    try? process.run()
    return process
}

/// Polls until `condition` holds or `timeout` elapses. Returns whether it held.
func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(25))
    }
    return condition()
}
