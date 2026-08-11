import Foundation

/// Who is holding the recorder.
enum RecordingOwner: String, Codable, Sendable, CaseIterable {
    /// The headless `dikta record` daemon.
    case cli
    /// The menu-bar app.
    case app
}

/// What a recording session looks like from the outside. Written by whoever owns
/// the lock, read by everyone else.
struct RecordingState: Codable, Sendable {
    enum Phase: String, Codable, Sendable {
        case starting, recording, processing, done, failed, cancelled

        var isTerminal: Bool {
            switch self {
            case .done, .failed, .cancelled: return true
            case .starting, .recording, .processing: return false
            }
        }
    }

    var version = 1
    var owner: RecordingOwner
    var sessionID: String
    var pid: Int32
    var phase: Phase
    /// The Hebrew progress label the menu would have shown, e.g. "מתמלל…".
    var label: String?
    var startedAt: Date
    var stoppedAt: Date?
    var finishedAt: Date?
    var sessionDirectory: String?
    var displayID: UInt32?
    var displayIndex: Int?
    var language: String?
    var summarize: Bool?
    var engine: String?
    var frameCount: Int?
    /// Recorded so a later cleanup can find the temp WAV if we die mid-processing.
    var audioTempPath: String?
    var indexPath: String?
    var summaryPath: String?
    var stopReason: String?
    var error: String?
    var exitCode: Int32?

    init(owner: RecordingOwner, sessionID: String, phase: Phase, startedAt: Date = Date()) {
        self.owner = owner
        self.sessionID = sessionID
        self.pid = ProcessInfo.processInfo.processIdentifier
        self.phase = phase
        self.startedAt = startedAt
    }
}

/// The whole cross-process contract. Nothing outside this file knows the layout.
///
/// Liveness is an advisory `flock`, not a PID check: the kernel drops the lock on
/// *any* death, including `SIGKILL` and a panic, so "is that recorder still
/// alive?" is answered by trying to take the lock rather than by trusting a
/// number that the OS is free to reuse. The same lock doubles as the
/// one-recorder-at-a-time mutex.
enum RecordingRegistry {
    /// Set by the tests so they never touch the real user's state. The env var
    /// covers the same need across a process boundary, for spawned helpers and
    /// the integration script.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        if let directoryOverride { return directoryOverride }
        let environment = ProcessInfo.processInfo.environment
        if let override = environment["DIKTA_RUN_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dikta/run", isDirectory: true)
    }

    static func stateURL(_ owner: RecordingOwner) -> URL {
        directory.appendingPathComponent("\(owner.rawValue).json")
    }

    static func lockURL(_ owner: RecordingOwner) -> URL {
        directory.appendingPathComponent("\(owner.rawValue).lock")
    }

    static var stopRequestURL: URL {
        directory.appendingPathComponent("stop")
    }

    static var logURL: URL {
        directory.appendingPathComponent("recorder.log")
    }

    private static func ensureDirectory() {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    // MARK: - The lock

    /// An exclusive hold on one owner slot. Released explicitly, on deinit, or by
    /// the kernel when the process dies — which is the entire point.
    final class Claim: @unchecked Sendable {
        let owner: RecordingOwner
        private let descriptor: Int32
        private let lock = NSLock()
        private var released = false

        init(owner: RecordingOwner, descriptor: Int32) {
            self.owner = owner
            self.descriptor = descriptor
        }

        func release() {
            lock.lock()
            defer { lock.unlock() }
            guard !released else { return }
            released = true
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        deinit { release() }
    }

    /// Takes the owner slot, or nil when someone else holds it.
    static func claim(_ owner: RecordingOwner) -> Claim? {
        ensureDirectory()
        let descriptor = open(lockURL(owner).path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }

        // FD_CLOEXEC is not optional. flock lives on the open file description,
        // and posix_spawn/Process inherit descriptors — without this the `claude`
        // summarizer, `caffeinate` and `say` children would each keep the lock
        // alive after the recorder died, wedging the slot for as long as they run.
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return Claim(owner: owner, descriptor: descriptor)
    }

    /// Whether someone currently holds `owner`. Briefly takes the lock itself, so
    /// a caller that is about to claim should retry rather than trust one refusal.
    static func isLive(_ owner: RecordingOwner) -> Bool {
        guard FileManager.default.fileExists(atPath: lockURL(owner).path) else { return false }
        guard let probe = claim(owner) else { return true }
        probe.release()
        return false
    }

    /// Like `claim`, but tolerates a concurrent `isLive` probe holding the lock
    /// for the microseconds it takes to check.
    static func claimWithRetry(_ owner: RecordingOwner, attempts: Int = 4) -> Claim? {
        for attempt in 0..<attempts {
            if let claim = claim(owner) { return claim }
            if attempt < attempts - 1 { usleep(50_000) }
        }
        return nil
    }

    // MARK: - State

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Atomic so a concurrent reader never sees half a document.
    static func write(_ state: RecordingState) throws {
        ensureDirectory()
        try encoder.encode(state).write(to: stateURL(state.owner), options: .atomic)
    }

    /// The last state written for `owner`, and whether its writer is still alive.
    /// `live == false` on a non-terminal phase means the recorder died.
    static func read(_ owner: RecordingOwner) -> (state: RecordingState, live: Bool)? {
        guard let state = readState(owner) else { return nil }
        return (state, isLive(owner))
    }

    private static func readState(_ owner: RecordingOwner) -> RecordingState? {
        let url = stateURL(owner)
        for attempt in 0..<2 {
            guard let data = try? Data(contentsOf: url) else { return nil }
            if let state = try? decoder.decode(RecordingState.self, from: data) { return state }
            // A rename(2) is atomic, so a failed decode means a genuinely bad
            // document rather than a torn read — but one cheap retry costs
            // nothing and covers a filesystem that is less strict than APFS.
            if attempt == 0 { usleep(50_000) }
        }
        return nil
    }

    static func activeOwners() -> [(owner: RecordingOwner, state: RecordingState, live: Bool)] {
        RecordingOwner.allCases.compactMap { owner in
            guard let found = read(owner) else { return nil }
            return (owner, found.state, found.live)
        }
    }

    // MARK: - Stop requests

    private struct StopRequest: Codable {
        let owner: RecordingOwner
        let sessionID: String
    }

    enum StopRequestError: Error, CustomStringConvertible {
        case noActiveRecording

        var description: String {
            switch self {
            case .noActiveRecording: return "no active recording"
            }
        }
    }

    /// Asks `owner` to stop. Refuses when nobody live is recording, so a request
    /// can never linger and kill the *next* session.
    static func requestStop(owner: RecordingOwner, sessionID: String) throws {
        guard let found = read(owner), found.live, !found.state.phase.isTerminal else {
            throw StopRequestError.noActiveRecording
        }
        ensureDirectory()
        let request = StopRequest(owner: owner, sessionID: sessionID)
        try encoder.encode(request).write(to: stopRequestURL, options: .atomic)
    }

    /// Consumes a request addressed to this session. A request for a different
    /// session is stale — it is cleared and ignored rather than obeyed.
    static func consumeStopRequest(owner: RecordingOwner, sessionID: String) -> Bool {
        guard let data = try? Data(contentsOf: stopRequestURL),
              let request = try? decoder.decode(StopRequest.self, from: data) else { return false }
        clearStopRequest()
        return request.owner == owner && request.sessionID == sessionID
    }

    static func clearStopRequest() {
        try? FileManager.default.removeItem(at: stopRequestURL)
    }
}
