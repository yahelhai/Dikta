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

    static func samples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }
}
