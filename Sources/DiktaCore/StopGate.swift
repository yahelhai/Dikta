import Foundation

/// Why a recording stopped.
enum StopReason: Sendable, Equatable, CustomStringConvertible {
    /// `dikta stop` asked for it.
    case request
    /// `^C` or a `kill`.
    case signal(Int32)
    /// `--for` elapsed.
    case deadline
    /// `--max-duration` elapsed.
    case durationLimit
    /// `--max-frames` reached.
    case frameLimit
    /// The capture stream died on its own.
    case streamError(String)

    var description: String {
        switch self {
        case .request: return "stop requested"
        case .signal(let number): return "signal \(number)"
        case .deadline: return "duration reached"
        case .durationLimit: return "maximum duration reached"
        case .frameLimit: return "frame limit reached"
        case .streamError(let message): return "stream error: \(message)"
        }
    }
}

/// Waits for the first of: a stop request from another process, `^C`/`SIGTERM`,
/// a deadline, a frame cap, or the stream dying — then resolves exactly once.
///
/// Signal dispositions are saved and restored. The previous implementation of
/// this idea left `SIG_IGN` in place after resolving, which made the process
/// un-interruptible during transcription — precisely the long phase where a
/// second `^C` is what a user reaches for.
final class StopGate: @unchecked Sendable {
    private let owner: RecordingOwner
    private let sessionID: String
    private let deadline: Date?
    private let maximumDuration: Date?
    private let pollInterval: TimeInterval
    private let frameLimit: Int?
    private let frameCount: @Sendable () -> Int

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.yahel.dikta.stop-gate")
    private var continuation: CheckedContinuation<StopReason, Never>?
    private var resolved: StopReason?
    private var signalSources: [DispatchSourceSignal] = []
    private var previousDispositions: [(Int32, sig_t?)] = []
    private var timer: DispatchSourceTimer?

    init(
        owner: RecordingOwner,
        sessionID: String,
        deadline: Date? = nil,
        maximumDuration: Date? = nil,
        frameLimit: Int? = nil,
        pollInterval: TimeInterval = 0.25,
        frameCount: @escaping @Sendable () -> Int = { 0 }
    ) {
        self.owner = owner
        self.sessionID = sessionID
        self.deadline = deadline
        self.maximumDuration = maximumDuration
        self.frameLimit = frameLimit
        self.pollInterval = pollInterval
        self.frameCount = frameCount
    }

    /// Starts watching. Safe to call once.
    func begin() {
        lock.lock()
        defer { lock.unlock() }
        guard signalSources.isEmpty, timer == nil else { return }

        for number in [SIGINT, SIGTERM] {
            // The default disposition kills the process before a dispatch source
            // ever runs; ignoring hands delivery to the source instead.
            let previous = signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: queue)
            source.setEventHandler { [weak self] in self?.resolve(.signal(number)) }
            source.resume()
            signalSources.append(source)
            previousDispositions.append((number, previous))
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        if let deadline, Date() >= deadline { return resolve(.deadline) }
        if let maximumDuration, Date() >= maximumDuration { return resolve(.durationLimit) }
        if let frameLimit, frameCount() >= frameLimit { return resolve(.frameLimit) }
        if RecordingRegistry.consumeStopRequest(owner: owner, sessionID: sessionID) {
            resolve(.request)
        }
    }

    /// First caller wins; the rest are ignored. Resuming a continuation twice is
    /// a hard crash, and a deadline, a signal, a request and a stream error can
    /// genuinely land together.
    func resolve(_ reason: StopReason) {
        lock.lock()
        guard resolved == nil else { return lock.unlock() }
        resolved = reason
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume(returning: reason)
    }

    func wait() async -> StopReason {
        await withCheckedContinuation { (continuation: CheckedContinuation<StopReason, Never>) in
            lock.lock()
            if let resolved {
                lock.unlock()
                continuation.resume(returning: resolved)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    /// Stops watching and restores the signal dispositions.
    ///
    /// Call this **before** post-processing, not after: the first signal means
    /// "stop capturing and keep what you have", and from then on a second one
    /// should terminate immediately. Post-processing is deliberately not
    /// gracefully interruptible — once whisper is inside `whisper_full`, a C call
    /// on a background thread, no Swift-level cancellation can preempt it, and
    /// pretending otherwise would just hang.
    /// Restoring happens here rather than in the sources' cancel handlers,
    /// because those run asynchronously on the gate's queue: `end()` would return
    /// while `SIG_IGN` was still installed, and the uninterruptible window this
    /// method exists to close would simply move a few milliseconds later.
    func end() {
        lock.lock()
        let sources = signalSources
        signalSources = []
        let dispositions = previousDispositions
        previousDispositions = []
        let pollTimer = timer
        timer = nil
        lock.unlock()

        sources.forEach { $0.cancel() }
        pollTimer?.cancel()
        for (number, previous) in dispositions {
            signal(number, previous ?? SIG_DFL)
        }
    }

    deinit { end() }
}
