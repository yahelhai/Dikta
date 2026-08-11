import Foundation

@testable import DiktaCore

/// Reads a signal's current disposition without changing it. C function pointers
/// are not Equatable, so the comparison goes through raw addresses.
private func isIgnored(_ number: Int32) -> Bool {
    var action = sigaction()
    sigaction(number, nil, &action)
    let installed = unsafeBitCast(action.__sigaction_u.__sa_handler, to: UnsafeRawPointer?.self)
    return installed == unsafeBitCast(SIG_IGN, to: UnsafeRawPointer?.self)
}

func registerStopGateTests(_ runner: TestRunner) {
    runner.test("stop gate: a deadline resolves the wait") { context in
        let gate = StopGate(
            owner: .cli, sessionID: "s", deadline: Date().addingTimeInterval(0.2),
            pollInterval: 0.05)
        gate.begin()
        let reason = await gate.wait()
        gate.end()
        context.expectEqual(reason, .deadline)
    }

    runner.test("stop gate: a request from another process resolves the wait") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("claim failed")
            }
            defer { claim.release() }
            try RecordingRegistry.write(
                RecordingState(owner: .cli, sessionID: "s", phase: .recording))

            let gate = StopGate(owner: .cli, sessionID: "s", pollInterval: 0.05)
            gate.begin()
            try RecordingRegistry.requestStop(owner: .cli, sessionID: "s")
            let reason = await gate.wait()
            gate.end()
            context.expectEqual(reason, .request)
        }
    }

    runner.test("stop gate: a frame cap resolves the wait") { context in
        let counter = Counter()
        let gate = StopGate(
            owner: .cli, sessionID: "s", frameLimit: 5, pollInterval: 0.05,
            frameCount: { counter.value })
        gate.begin()
        counter.value = 5
        let reason = await gate.wait()
        gate.end()
        context.expectEqual(reason, .frameLimit)
    }

    runner.test("stop gate: SIGINT is caught rather than killing the process") { context in
        let gate = StopGate(owner: .cli, sessionID: "s", pollInterval: 0.05)
        gate.begin()
        // Safe only because begin() has already installed SIG_IGN plus a source;
        // without the gate this would terminate the test runner.
        kill(getpid(), SIGINT)
        let reason = await gate.wait()
        gate.end()
        context.expectEqual(reason, .signal(SIGINT))
    }

    // The regression that motivated rewriting this: the earlier implementation
    // cancelled its sources without restoring the disposition, so SIG_IGN stayed
    // installed and the long transcription phase could not be interrupted at all.
    runner.test("stop gate: end() restores the signal dispositions") { context in
        context.expect(!isIgnored(SIGINT), "SIGINT was already ignored before the test")
        context.expect(!isIgnored(SIGTERM), "SIGTERM was already ignored before the test")

        let gate = StopGate(
            owner: .cli, sessionID: "s", deadline: Date().addingTimeInterval(0.1),
            pollInterval: 0.05)
        gate.begin()
        context.expect(isIgnored(SIGINT), "begin() should have installed SIG_IGN")

        _ = await gate.wait()
        gate.end()

        let restored = await waitUntil { !isIgnored(SIGINT) && !isIgnored(SIGTERM) }
        context.expect(
            restored,
            "end() left SIG_IGN installed — post-processing would be uninterruptible")
    }

    runner.test("stop gate: resolving twice keeps the first reason and does not crash") { context in
        let gate = StopGate(owner: .cli, sessionID: "s", pollInterval: 10)
        gate.begin()
        gate.resolve(.frameLimit)
        gate.resolve(.deadline)
        gate.resolve(.streamError("late"))
        let reason = await gate.wait()
        gate.end()
        context.expectEqual(reason, .frameLimit, "the first reason should win")
    }

    runner.test("stop gate: concurrent resolves produce exactly one result") { context in
        let gate = StopGate(owner: .cli, sessionID: "s", pollInterval: 10)
        gate.begin()
        // Resuming a CheckedContinuation twice traps, so this either passes or
        // takes the whole runner down — which is exactly the signal we want.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<32 {
                group.addTask {
                    gate.resolve(index.isMultiple(of: 2) ? .deadline : .frameLimit)
                }
            }
        }
        let reason = await gate.wait()
        gate.end()
        context.expect(reason == .deadline || reason == .frameLimit, "unexpected \(reason)")
    }

    runner.test("stop gate: waiting after the fact returns the stored reason") { context in
        let gate = StopGate(owner: .cli, sessionID: "s", pollInterval: 10)
        gate.begin()
        gate.resolve(.streamError("display disconnected"))
        gate.end()
        let reason = await gate.wait()
        context.expectEqual(reason, .streamError("display disconnected"))
    }
}

/// A tiny thread-safe box, so the frame-count closure can be moved from a test.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
