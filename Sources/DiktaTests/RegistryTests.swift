import Foundation

@testable import DiktaCore

/// Re-runs this same binary as a lock holder. Real processes are the only honest
/// way to test "the kernel released the lock when the owner died".
private func startLockHolder(
    runDirectory: URL, owner: RecordingOwner, seconds: Double, spawnChild: Bool = false
) -> Process? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
    process.arguments = ["--hold-lock", owner.rawValue, "\(seconds)"]
        + (spawnChild ? ["--spawn-child"] : [])
    var environment = ProcessInfo.processInfo.environment
    environment["DIKTA_RUN_DIR"] = runDirectory.path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }

    // The helper prints one line once the lock is actually held.
    var seen = Data()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        let chunk = output.fileHandleForReading.availableData
        if chunk.isEmpty { break }
        seen.append(chunk)
        if String(data: seen, encoding: .utf8)?.contains("held") == true { return process }
    }
    process.terminate()
    return nil
}

func registerRegistryTests(_ runner: TestRunner) {
    runner.test("registry: claiming a free owner succeeds, a second claim does not") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("first claim failed")
            }
            context.expectNil(RecordingRegistry.claim(.cli), "second claim")
            context.expect(RecordingRegistry.isLive(.cli), "should read as live while held")

            claim.release()
            context.expect(!RecordingRegistry.isLive(.cli), "should be free after release")
            context.expect(RecordingRegistry.claim(.cli) != nil, "reclaim after release")
        }
    }

    runner.test("registry: the two owners are independent slots") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            let cli = RecordingRegistry.claim(.cli)
            context.expect(cli != nil, "cli claim")
            context.expect(RecordingRegistry.claim(.app) != nil, "app claim while cli is held")
        }
    }

    runner.test("registry: another process cannot claim what we hold") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let holder = startLockHolder(runDirectory: directory, owner: .cli, seconds: 5)
            else { return context.fail("helper did not start") }
            defer { holder.terminate() }

            context.expectNil(RecordingRegistry.claim(.cli), "claim while another process holds")
            context.expect(RecordingRegistry.isLive(.cli), "isLive across processes")
        }
    }

    // The whole reason the design uses flock rather than a PID file: SIGKILL
    // leaves no chance to clean up, and the lock must still be released.
    runner.test("registry: SIGKILL on the holder frees the lock") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let holder = startLockHolder(runDirectory: directory, owner: .cli, seconds: 30)
            else { return context.fail("helper did not start") }
            context.expect(RecordingRegistry.isLive(.cli), "live before the kill")

            kill(holder.processIdentifier, SIGKILL)
            let freed = await waitUntil { !RecordingRegistry.isLive(.cli) }
            context.expect(freed, "lock still held after SIGKILL")
            context.expect(RecordingRegistry.claim(.cli) != nil, "cannot reclaim after SIGKILL")
        }
    }

    // FD_CLOEXEC regression. Without it the summarizer's `claude` child (and
    // `caffeinate`, and `say`) would inherit the descriptor and keep the slot
    // wedged after the recorder itself was gone — a silent, once-a-month bug.
    runner.test("registry: a child process does not inherit the lock") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let holder = startLockHolder(
                runDirectory: directory, owner: .cli, seconds: 30, spawnChild: true)
            else { return context.fail("helper did not start") }

            kill(holder.processIdentifier, SIGKILL)
            let freed = await waitUntil { !RecordingRegistry.isLive(.cli) }
            context.expect(
                freed,
                "the spawned child inherited the lock — FD_CLOEXEC is missing on the claim")
        }
    }

    runner.test("registry: state survives a dead writer and reads back as not live") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            var state = RecordingState(owner: .cli, sessionID: "abc", phase: .recording)
            state.sessionDirectory = "/tmp/session"
            state.displayIndex = 2
            try RecordingRegistry.write(state)

            guard let found = RecordingRegistry.read(.cli) else {
                return context.fail("state did not read back")
            }
            context.expectEqual(found.state.sessionID, "abc")
            context.expectEqual(found.state.phase, .recording)
            context.expectEqual(found.state.displayIndex, 2)
            context.expectEqual(found.state.sessionDirectory, "/tmp/session")
            // Nobody holds the lock, so a non-terminal phase means a dead writer.
            context.expect(!found.live, "should not be live with no holder")
        }
    }

    runner.test("registry: concurrent readers never see a partial document") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            var state = RecordingState(owner: .cli, sessionID: "atomic", phase: .starting)
            try RecordingRegistry.write(state)

            let writer = Task.detached {
                for index in 0..<200 {
                    state.frameCount = index
                    state.label = String(repeating: "מתמלל…", count: 40)
                    try? RecordingRegistry.write(state)
                }
            }
            for _ in 0..<200 {
                if let found = RecordingRegistry.read(.cli) {
                    context.expectEqual(found.state.sessionID, "atomic", "torn read")
                } else {
                    context.fail("read returned nil during concurrent writes")
                    break
                }
            }
            await writer.value
        }
    }

    runner.test("registry: a stop request round-trips exactly once") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("claim failed")
            }
            defer { claim.release() }
            try RecordingRegistry.write(
                RecordingState(owner: .cli, sessionID: "s1", phase: .recording))

            try RecordingRegistry.requestStop(owner: .cli, sessionID: "s1")
            context.expect(
                RecordingRegistry.consumeStopRequest(owner: .cli, sessionID: "s1"),
                "first consume should see the request")
            context.expect(
                !RecordingRegistry.consumeStopRequest(owner: .cli, sessionID: "s1"),
                "the request should be gone after being consumed")
        }
    }

    runner.test("registry: a request for another session is discarded, not obeyed") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("claim failed")
            }
            defer { claim.release() }
            try RecordingRegistry.write(
                RecordingState(owner: .cli, sessionID: "old", phase: .recording))
            try RecordingRegistry.requestStop(owner: .cli, sessionID: "old")

            // A new session must not be stopped by the previous one's request.
            context.expect(
                !RecordingRegistry.consumeStopRequest(owner: .cli, sessionID: "new"),
                "a stale request stopped the wrong session")
            context.expect(
                !FileManager.default.fileExists(atPath: RecordingRegistry.stopRequestURL.path),
                "the stale request should have been cleared")
        }
    }

    runner.test("registry: stopping refuses when nothing is recording") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }

            // No state at all.
            do {
                try RecordingRegistry.requestStop(owner: .cli, sessionID: "s1")
                context.fail("expected a throw with no state")
            } catch {}

            // Terminal state, lock held — still nothing to stop.
            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("claim failed")
            }
            defer { claim.release() }
            var finished = RecordingState(owner: .cli, sessionID: "s1", phase: .done)
            finished.finishedAt = Date()
            try RecordingRegistry.write(finished)
            do {
                try RecordingRegistry.requestStop(owner: .cli, sessionID: "s1")
                context.fail("expected a throw for a finished session")
            } catch {}

            context.expect(
                !FileManager.default.fileExists(atPath: RecordingRegistry.stopRequestURL.path),
                "a refused request must not leave a file behind")
        }
    }
}

// MARK: - Helper process mode

/// `DiktaTests --hold-lock <owner> <seconds> [--spawn-child]` — claims the slot,
/// optionally leaves a child running, and waits. Prints "held" once the lock is
/// taken so the parent can synchronise.
func runLockHolderMode(_ arguments: [String]) -> Never {
    guard let owner = arguments.first.flatMap(RecordingOwner.init(rawValue:)),
          let seconds = arguments.dropFirst().first.flatMap(Double.init) else {
        FileHandle.standardError.write(Data("usage: --hold-lock <owner> <seconds>\n".utf8))
        exit(2)
    }
    guard let claim = RecordingRegistry.claim(owner) else {
        FileHandle.standardError.write(Data("could not claim \(owner.rawValue)\n".utf8))
        exit(1)
    }

    if arguments.contains("--spawn-child") {
        // Raw posix_spawn on purpose. Foundation's Process passes
        // POSIX_SPAWN_CLOEXEC_DEFAULT, which closes every descriptor for you and
        // would hide the bug — but DetachedLauncher spawns by hand, so this is
        // the shape that can actually leak the lock.
        var pid: pid_t = 0
        var argv: [UnsafeMutablePointer<CChar>?] =
            ["/bin/sleep", "30"].map { $0.withCString(strdup) } + [nil]
        defer { argv.forEach { free($0) } }
        _ = posix_spawn(&pid, "/bin/sleep", nil, nil, &argv, environ)
    }

    print("held")
    fflush(stdout)
    Thread.sleep(forTimeInterval: seconds)
    claim.release()
    exit(0)
}

/// `activeRecording` is the single predicate both refusals now share — the menu's
/// and the CLI's — so it is worth pinning down on its own.
func registerActiveRecordingTests(_ runner: TestRunner) {
    runner.test("active recording: nil when nothing was ever started") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }
            context.expectNil(RecordingRegistry.activeRecording(.cli))
            context.expectNil(RecordingRegistry.activeRecording(.app))
        }
    }

    runner.test("active recording: the state itself while live and recording") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }
            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("claim failed")
            }
            defer { claim.release() }

            var state = RecordingState(owner: .cli, sessionID: "live", phase: .recording)
            state.sessionDirectory = "/tmp/live"
            try RecordingRegistry.write(state)
            context.expectEqual(RecordingRegistry.activeRecording(.cli)?.sessionID, "live")

            // Processing still counts as busy: a second recorder would fight it
            // for the machine.
            state.phase = .processing
            try RecordingRegistry.write(state)
            context.expectEqual(RecordingRegistry.activeRecording(.cli)?.phase, .processing)
        }
    }

    runner.test("active recording: nil once the session finished") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }
            guard let claim = RecordingRegistry.claim(.cli) else {
                return context.fail("claim failed")
            }
            defer { claim.release() }

            for phase in [RecordingState.Phase.done, .failed, .cancelled] {
                var state = RecordingState(owner: .cli, sessionID: "s", phase: phase)
                state.finishedAt = Date()
                try RecordingRegistry.write(state)
                context.expectNil(RecordingRegistry.activeRecording(.cli), "\(phase)")
            }
        }
    }

    // A recorder that died mid-run must not block the next one forever.
    runner.test("active recording: nil when the writer is gone") { context in
        try await withTemporaryDirectory { directory in
            RecordingRegistry.directoryOverride = directory
            defer { RecordingRegistry.directoryOverride = nil }
            // Written with nobody holding the lock: a stale, non-terminal state.
            try RecordingRegistry.write(
                RecordingState(owner: .cli, sessionID: "orphan", phase: .recording))
            context.expectNil(RecordingRegistry.activeRecording(.cli))
        }
    }
}
