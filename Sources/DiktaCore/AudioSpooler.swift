@preconcurrency import AVFoundation
import Foundation

/// Streams ScreenCaptureKit audio into a temporary 16kHz mono WAV.
///
/// ScreenCaptureKit hands us CMSampleBuffers (typically 48kHz stereo Float32)
/// on its own audio queue, so this is a plain non-isolated class in the same
/// shape as `AudioRecorder`'s `SampleAccumulator`: an `NSLock` around everything
/// mutable, no actor hops from the callback.
///
/// Writing straight through to disk as int16 keeps RAM flat (~115MB/hour on
/// disk, nothing accumulated in memory).
final class AudioSpooler: @unchecked Sendable {
    /// Where the WAV is being written. Caller deletes it once transcribed.
    let url: URL

    private let lock = NSLock()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var framesWritten: AVAudioFramePosition = 0
    private var failureLogged = false
    private var closed = false

    init(url: URL) {
        self.url = url
    }

    /// Frames written so far, in seconds of 16kHz audio.
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
        defer { lock.unlock() }
        guard !closed else { return }

        do {
            let target = AudioFileLoader.whisperFormat
            if file == nil {
                // 16-bit PCM on disk, Float32 in the processing format so the
                // converter output can be handed over unchanged.
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVSampleRateKey: target.sampleRate,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            if converter == nil || sourceFormat != input.format {
                guard let made = AVAudioConverter(from: input.format, to: target) else {
                    throw DiktaError.audioLoadFailed("cannot convert \(input.format) to 16kHz mono")
                }
                converter = made
                sourceFormat = input.format
            }
            guard let file, let converter else { return }

            let ratio = target.sampleRate / input.format.sampleRate
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 256
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

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
            guard output.frameLength > 0 else { return }

            try file.write(from: output)
            framesWritten += AVAudioFramePosition(output.frameLength)
        } catch {
            if !failureLogged {
                failureLogged = true
                NSLog("Dikta: audio spool failed: %@", "\(error)")
            }
        }
    }

    /// Close the file and report what was written. Returns nil when no audio
    /// ever arrived (no system sound during the recording).
    @discardableResult
    func finish() -> (url: URL, duration: TimeInterval)? {
        lock.lock()
        defer { lock.unlock() }
        closed = true
        guard file != nil, framesWritten > 0 else {
            file = nil
            converter = nil
            return nil
        }
        // AVAudioFile finalises the WAV header on deallocation.
        file = nil
        converter = nil
        return (url, Double(framesWritten) / AudioFileLoader.whisperFormat.sampleRate)
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
