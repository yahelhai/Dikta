@preconcurrency import AVFoundation

/// Load any audio file and convert to 16kHz mono Float32 — the format whisper expects.
enum AudioFileLoader {
    static let whisperFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

    static func loadSamples(from url: URL) throws -> [Float] {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw DiktaError.audioLoadFailed("\(url.path): \(error.localizedDescription)")
        }
        let sourceFormat = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            throw DiktaError.audioLoadFailed("empty or unreadable file")
        }
        try file.read(into: inputBuffer)
        return try convert(buffer: inputBuffer, from: sourceFormat)
    }

    static func convert(buffer inputBuffer: AVAudioPCMBuffer, from sourceFormat: AVAudioFormat) throws -> [Float] {
        if sourceFormat == whisperFormat {
            return samples(from: inputBuffer)
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: whisperFormat) else {
            throw DiktaError.audioLoadFailed("cannot convert \(sourceFormat) to 16kHz mono")
        }
        let ratio = 16000.0 / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: whisperFormat, frameCapacity: capacity) else {
            throw DiktaError.audioLoadFailed("cannot allocate conversion buffer")
        }
        nonisolated(unsafe) var fed = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if fed {
                outStatus.pointee = .endOfStream
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError {
            throw DiktaError.audioLoadFailed(conversionError.localizedDescription)
        }
        return samples(from: outputBuffer)
    }

    /// Stretch samples captured from sped-up playback back towards real time.
    ///
    /// Recording a lecture at 1.5x saves a third of the wall clock, but whisper
    /// is trained on ordinary speech and a 1.5x stream can collapse into
    /// nonsense — measured on a real capture, "Thank you." repeated over two
    /// minutes of perfectly good audio, which transcribed correctly the moment
    /// it was slowed back down. Linear interpolation is enough: it drops pitch
    /// the way a tape slowdown does, and whisper handles that fine.
    static func slowed(_ samples: [Float], playbackRate: Double) -> [Float] {
        guard playbackRate > 0, playbackRate != 1, samples.count > 1 else { return samples }
        let count = Int(Double(samples.count) * playbackRate)
        guard count > 1 else { return samples }
        var out = [Float](repeating: 0, count: count)
        let step = Double(samples.count - 1) / Double(count - 1)
        for i in 0..<count {
            let position = Double(i) * step
            let low = Int(position)
            let high = min(low + 1, samples.count - 1)
            let fraction = Float(position - Double(low))
            out[i] = samples[low] * (1 - fraction) + samples[high] * fraction
        }
        return out
    }

    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
