@preconcurrency import AVFoundation

/// Captures mic audio and accumulates 16kHz mono Float32 samples.
/// The AVAudioEngine tap runs on a realtime thread — the shared buffer is
/// protected by a lock and never touches actors from the tap.
@MainActor
final class AudioRecorder {
    private var engine: AVAudioEngine?
    private var accumulator: SampleAccumulator?

    var isRecording: Bool { engine != nil }

    func start() throws {
        guard engine == nil else { return }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Read the device's native format at every start — input devices
        // (AirPods etc.) can change between sessions.
        let sourceFormat = input.inputFormat(forBus: 0)
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw DiktaError.audioEngineFailed("no input device / zero format")
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: AudioFileLoader.whisperFormat) else {
            throw DiktaError.audioEngineFailed("cannot convert \(sourceFormat)")
        }

        let accumulator = SampleAccumulator(converter: converter)
        // @Sendable so the closure does NOT inherit @MainActor isolation — it runs
        // on the realtime audio thread, and an inherited isolation check crashes.
        input.installTap(onBus: 0, bufferSize: 4096, format: sourceFormat) { @Sendable buffer, _ in
            accumulator.append(buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw DiktaError.audioEngineFailed(error.localizedDescription)
        }

        self.engine = engine
        self.accumulator = accumulator
    }

    /// Stop and return everything recorded since start().
    func stop() -> [Float] {
        guard let engine, let accumulator else { return [] }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        self.accumulator = nil
        return accumulator.drain()
    }

    func cancel() {
        _ = stop()
    }
}

/// Lock-guarded sample sink shared with the realtime audio thread.
private final class SampleAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []
    private let converter: AVAudioConverter
    private let ratio: Double

    init(converter: AVAudioConverter) {
        self.converter = converter
        self.ratio = 16000.0 / converter.inputFormat.sampleRate
        samples.reserveCapacity(16000 * 60)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: AudioFileLoader.whisperFormat,
                                         frameCapacity: capacity) else { return }
        nonisolated(unsafe) var fed = false
        var conversionError: NSError?
        converter.convert(to: out, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil, out.frameLength > 0,
              let data = out.floatChannelData else { return }
        let chunk = UnsafeBufferPointer(start: data[0], count: Int(out.frameLength))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    func drain() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let result = samples
        samples = []
        return result
    }
}
