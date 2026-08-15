@preconcurrency import AVFoundation
import Foundation

/// Streams ScreenCaptureKit audio into a series of 16kHz mono WAV chunks.
///
/// ScreenCaptureKit hands us CMSampleBuffers (typically 48kHz stereo Float32)
/// on its own audio queue, so this is a plain non-isolated class in the same
/// shape as `AudioRecorder`'s `SampleAccumulator`: an `NSLock` around everything
/// mutable, no actor hops from the callback.
///
/// Chunking is what lets transcription run *during* the recording rather than
/// in one long pass at the end: every closed chunk is handed to `onChunk` the
/// moment it lands, and the transcriber can start on it while capture continues.
/// Writing through to disk as int16 keeps RAM flat either way.
final class AudioSpooler: @unchecked Sendable {
    /// A closed chunk, ready to transcribe.
    struct Chunk: Sendable, Equatable {
        let url: URL
        /// 1-based, matching the filename.
        let index: Int
        /// Seconds from the start of the recording to this chunk's first sample.
        /// Counted in samples rather than wall clock, so the timestamps that end
        /// up in the transcript can't drift.
        let startOffset: TimeInterval
        let duration: TimeInterval
    }

    /// Audio quieter than this counts as a gap worth cutting on (-40 dBFS).
    /// Speech sits far above it; room tone and player silence sit below.
    static let silenceRMS: Float = 0.01

    /// Directory the chunk files are written into.
    let directory: URL

    private let chunkFrames: AVAudioFramePosition
    private let overshootFrames: AVAudioFramePosition
    private let onChunk: @Sendable (Chunk) -> Void

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var framesInChunk: AVAudioFramePosition = 0
    private var chunkIndex = 0
    private var currentURL: URL?
    private var failureLogged = false
    private var closed = false

    /// - Parameters:
    ///   - chunkSeconds: how much audio to gather before looking for a cut.
    ///   - maximumOvershoot: how long to keep waiting for a quiet moment past
    ///     that target before cutting mid-word anyway.
    init(directory: URL,
         chunkSeconds: TimeInterval = 120,
         maximumOvershoot: TimeInterval = 15,
         onChunk: @escaping @Sendable (Chunk) -> Void) {
        let rate = AudioFileLoader.whisperFormat.sampleRate
        self.directory = directory
        self.chunkFrames = AVAudioFramePosition(chunkSeconds * rate)
        self.overshootFrames = AVAudioFramePosition(maximumOvershoot * rate)
        self.onChunk = onChunk
    }

    /// Seconds of audio written so far, across every chunk.
    var duration: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Double(framesWritten) / AudioFileLoader.whisperFormat.sampleRate
    }

    /// Append one ScreenCaptureKit audio sample buffer. Safe to call from the
    /// capture queue; never throws into the callback.
    func append(_ sampleBuffer: CMSampleBuffer) {
        guard let input = Self.pcmBuffer(from: sampleBuffer), input.frameLength > 0 else { return }
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }

        var finished: Chunk?
        do {
            let target = AudioFileLoader.whisperFormat
            if file == nil { try openChunk(format: target) }
            if converter == nil || sourceFormat != input.format {
                guard let made = AVAudioConverter(from: input.format, to: target) else {
                    throw DiktaError.audioLoadFailed("cannot convert \(input.format) to 16kHz mono")
                }
                converter = made
                sourceFormat = input.format
            }
            guard let file, let converter else {
                lock.unlock()
                return
            }

            let ratio = target.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
                lock.unlock()
                return
            }

            nonisolated(unsafe) var fed = false
            var conversionError: NSError?
            converter.convert(to: output, error: &conversionError) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            guard output.frameLength > 0 else {
                lock.unlock()
                return
            }

            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
            framesInChunk += AVAudioFramePosition(output.frameLength)

            if shouldRotate(after: output) { finished = closeChunk() }
        } catch {
            if !failureLogged {
                failureLogged = true
                NSLog("Dikta: audio spool failed: %@", "\(error)")
            }
        }
        lock.unlock()
        // Outside the lock: the handler transcribes, and the capture queue must
        // not be held up behind it.
        if let finished { onChunk(finished) }
    }

    /// Close the final chunk and report the totals. Returns nil when no audio
    /// ever arrived (no system sound during the recording).
    @discardableResult
    func finish() -> (chunks: Int, duration: TimeInterval)? {
        lock.lock()
        closed = true
        let finished = closeChunk()
        converter = nil
        let total = Double(framesWritten) / AudioFileLoader.whisperFormat.sampleRate
        let count = chunkIndex
        lock.unlock()

        if let finished { onChunk(finished) }
        guard count > 0, total > 0 else { return nil }
        return (count, total)
    }

    // MARK: - Chunk lifecycle (call with the lock held)

    private func openChunk(format: AVAudioFormat) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chunkIndex += 1
        let url = directory.appendingPathComponent(String(format: "chunk-%04d.wav", chunkIndex))
        // 16-bit PCM on disk, Float32 in the processing format so the converter
        // output can be handed over unchanged.
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        file = try AVAudioFile(forWriting: url, settings: settings,
                               commonFormat: .pcmFormatFloat32, interleaved: false)
        currentURL = url
        framesInChunk = 0
    }

    /// Past the target length, cut on the first quiet buffer; past the overshoot,
    /// cut regardless. Waiting for quiet costs a few seconds of latency and buys
    /// a seam that doesn't fall inside a word.
    private func shouldRotate(after buffer: AVAudioPCMBuffer) -> Bool {
        guard framesInChunk >= chunkFrames else { return false }
        if framesInChunk >= chunkFrames + overshootFrames { return true }
        return Self.rms(of: buffer) < Self.silenceRMS
    }

    /// Close the open chunk and describe it. nil when nothing was written to it.
    private func closeChunk() -> Chunk? {
        // AVAudioFile finalises the WAV header on deallocation, so the file must
        // go before anyone is told the chunk is readable.
        file = nil
        guard let url = currentURL, framesInChunk > 0 else {
            currentURL = nil
            return nil
        }
        currentURL = nil
        let rate = AudioFileLoader.whisperFormat.sampleRate
        let chunk = Chunk(url: url,
                          index: chunkIndex,
                          startOffset: Double(framesWritten - framesInChunk) / rate,
                          duration: Double(framesInChunk) / rate)
        framesInChunk = 0
        return chunk
    }

    static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let samples = UnsafeBufferPointer(start: channel[0], count: Int(buffer.frameLength))
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    // MARK: - CMSampleBuffer bridging

    /// Wrap a CMSampleBuffer's audio in an AVAudioPCMBuffer. The returned buffer
    /// owns a copy, so the caller may keep it past the callback.
    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        // Copy the sample data into the buffer we just allocated — the block
        // buffer behind the sample buffer is recycled as soon as we return.
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList)
        guard status == noErr else { return nil }
        return buffer
    }
}
