import Foundation

// `dikta stop` and `dikta status`. Neither does any recording work itself: stop
// leaves a request for the daemon and then watches the state document, which is
// what lets a caller that gave up mid-wait ask again from a third invocation and
// still get the answer.

let stopUsage = "usage: dikta stop [--no-wait] [--timeout <seconds>] [--json]\n"
let statusUsage = "usage: dikta status [--json]\n"

/// Exit codes beyond the shared 0/1/2/3/4.
enum ScreenExit {
    /// Nothing is recording.
    static let nothingToStop: Int32 = 5
    /// Something already is.
    static let alreadyBusy: Int32 = 6
    /// Stopped, but processing outlasted --timeout.
    static let waitTimedOut: Int32 = 7
}

func runStopCLI(_ args: [String]) -> Int32 {
    var wait = true
    var timeout: TimeInterval = 900
    var json = false

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--no-wait": wait = false
        case "--json": json = true
        case "--timeout":
            index += 1
            guard index < args.count, let seconds = Double(args[index]), seconds > 0 else {
                note("stop", "--timeout takes a positive number of seconds")
                return 2
            }
            timeout = seconds
        default:
            FileHandle.standardError.write(Data(stopUsage.utf8))
            return 2
        }
        index += 1
    }

    guard let found = RecordingRegistry.read(.cli) else {
        note("stop", "no recording has been started")
        return ScreenExit.nothingToStop
    }
    let state = found.state

    // Already finished: re-print the paths rather than erroring. Agents retry,
    // and "the answer you already produced" is more useful than a complaint.
    if state.phase.isTerminal || !found.live {
        if state.phase.isTerminal {
            note("stop", "nothing is recording — the last session already finished")
            report(state, json: json)
            return state.exitCode ?? 0
        }
        note("stop", "the recorder died during \(state.phase.rawValue)"
            + (state.sessionDirectory.map { "; what it captured is in \($0)" } ?? ""))
        return 1
    }

    if state.phase == .recording {
        do {
            try RecordingRegistry.requestStop(owner: .cli, sessionID: state.sessionID)
        } catch {
            note("stop", "\(error)")
            return ScreenExit.nothingToStop
        }
    } else {
        note("stop", "already processing — waiting for it to finish")
    }

    guard wait else {
        note("stop", "stop requested; poll `dikta status` for the result")
        return 0
    }

    return waitForCompletion(sessionID: state.sessionID, timeout: timeout, json: json)
}

private func waitForCompletion(sessionID: String, timeout: TimeInterval, json: Bool) -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    var lastLabel: String?
    var acknowledged = false

    while Date() < deadline {
        guard let found = RecordingRegistry.read(.cli),
              found.state.sessionID == sessionID else {
            note("stop", "the session disappeared")
            return 1
        }
        let state = found.state

        if !acknowledged, state.stoppedAt != nil {
            acknowledged = true
            note("stop", "capture stopped" + (state.frameCount.map { " (\($0) frames)" } ?? ""))
        }
        if let label = state.label, label != lastLabel {
            lastLabel = label
            note("stop", label)
        }
        if state.phase.isTerminal {
            report(state, json: json)
            if let error = state.error { note("stop", error) }
            return state.exitCode ?? 0
        }
        // The lock going free before a terminal phase means the recorder died
        // rather than finished — the reason liveness is a lock and not a PID.
        if !found.live {
            note("stop", "the recorder died during \(state.phase.rawValue)"
                + (state.sessionDirectory.map { "; what it captured is in \($0)" } ?? ""))
            return 1
        }
        usleep(250_000)
    }

    note("stop", "capture stopped, but processing is still running after "
        + "\(Int(timeout))s — poll `dikta status`")
    return ScreenExit.waitTimedOut
}

private func report(_ state: RecordingState, json: Bool) {
    if json {
        printJSON(statePayload(state, live: false))
        return
    }
    if let index = state.indexPath { print(index) }
    if let summary = state.summaryPath { print(summary) }
}

// MARK: - status

func runStatusCLI(_ args: [String]) -> Int32 {
    var json = false
    for argument in args {
        switch argument {
        case "--json": json = true
        default:
            FileHandle.standardError.write(Data(statusUsage.utf8))
            return 2
        }
    }

    let owners = RecordingRegistry.activeOwners()
    if json {
        printJSON([
            "owners": owners.map { owner, state, live in
                var payload = statePayload(state, live: live)
                payload["owner"] = owner.rawValue
                return payload
            }
        ])
        return owners.contains { $0.live && !$0.state.phase.isTerminal } ? 0
            : ScreenExit.nothingToStop
    }

    guard !owners.isEmpty else {
        print("idle — no recording has been started")
        return ScreenExit.nothingToStop
    }

    var active = false
    for (owner, state, live) in owners {
        let running = live && !state.phase.isTerminal
        active = active || running
        // "stale" is the honest word for a non-terminal phase whose writer is
        // gone: the frames are on disk but nothing is going to finish them.
        let health = running ? state.phase.rawValue
            : (state.phase.isTerminal ? state.phase.rawValue : "\(state.phase.rawValue) (stale)")
        var line = "\(owner.rawValue): \(health)"
        if let label = state.label, running { line += " — \(label)" }
        if let directory = state.sessionDirectory { line += "\n  \(directory)" }
        if let index = state.indexPath { line += "\n  \(index)" }
        if let summary = state.summaryPath { line += "\n  \(summary)" }
        if let error = state.error { line += "\n  error: \(error)" }
        print(line)
    }
    return active ? 0 : ScreenExit.nothingToStop
}

private func statePayload(_ state: RecordingState, live: Bool) -> [String: Any] {
    var payload: [String: Any] = [
        "sessionID": state.sessionID,
        "phase": state.phase.rawValue,
        "live": live,
        "pid": Int(state.pid),
    ]
    if let value = state.label { payload["label"] = value }
    if let value = state.sessionDirectory { payload["sessionDirectory"] = value }
    if let value = state.indexPath { payload["indexPath"] = value }
    if let value = state.summaryPath { payload["summaryPath"] = value }
    if let value = state.frameCount { payload["frameCount"] = value }
    if let value = state.displayIndex { payload["displayIndex"] = value }
    if let value = state.displayID { payload["displayID"] = Int(value) }
    if let value = state.stopReason { payload["stopReason"] = value }
    if let value = state.error { payload["error"] = value }
    if let value = state.exitCode { payload["exitCode"] = Int(value) }
    return payload
}
