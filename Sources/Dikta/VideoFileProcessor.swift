@preconcurrency import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Turns an existing video file into a Markdown "slide deck": scene frames plus
/// a timestamped transcript aligned to them.
///
/// This is the file-based twin of the live screen recorder — it shares
/// `FrameHasher`, `LanguageRouter`, `Transcriber.transcribeSegments` and
/// `MarkdownExporter` with it, and doubles as the headless test path.
enum VideoFileProcessor {
    enum Phase: Sendable {
        case extractingAudio
        case extractingFrames
        case transcribing
        case exporting

        var label: String {
            switch self {
            case .extractingAudio: return "audio"
            case .extractingFrames: return "frames"
            case .transcribing: return "transcribe"
            case .exporting: return "export"
            }
        }
    }

    /// Reported as (phase, fraction of that phase in 0...1).
    typealias ProgressHandler = @Sendable (Phase, Double) -> Void

    /// Distance from the last kept frame above which we call it a new scene.
    private static let sceneThreshold = 10
    /// Distance at or below which a frame is a repeat of one we already kept
    /// (global dedup — catches going back to an earlier slide).
    private static let duplicateThreshold = 6
    /// Frames are sampled once per second.
    private static let sampleInterval: TimeInterval = 1.0
    /// Plenty of detail for hashing, cheap to decode.
    private static let hashingMaxSize = CGSize(width: 960, height: 960)

    /// Process `videoURL` into `<destinationDirectory>/<video-basename>/index.md`.
    /// Returns the URL of the generated index.md.
    @discardableResult
    static func process(videoURL: URL,
                        destinationDirectory: URL,
                        mode: LanguageMode,
                        transcriber: Transcriber,
                        progress: @escaping ProgressHandler = { _, _ in }) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        guard try await asset.load(.isReadable) else {
            throw DiktaError.videoLoadFailed("cannot read \(videoURL.path)")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else {
            throw DiktaError.videoLoadFailed("zero-length video")
        }

        let name = videoURL.deletingPathExtension().lastPathComponent
        let outputDirectory = destinationDirectory.appendingPathComponent(name, isDirectory: true)
        let framesDirectory = outputDirectory.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        progress(.extractingAudio, 0)
        let samples = try await loadAudio(from: asset, url: videoURL)
        progress(.extractingAudio, 1)

        let frames = try await extractFrames(from: asset, duration: duration,
                                             into: framesDirectory, progress: progress)
        progress(.extractingFrames, 1)

        progress(.transcribing, 0)
        let (modelPath, language) = try await LanguageRouter.route(
            samples: samples, mode: mode, transcriber: transcriber)
        let segments = try await transcriber.transcribeSegments(
            samples: samples, language: language, modelPath: modelPath)
        progress(.transcribing, 1)

        progress(.exporting, 0)
        let created = (try? videoURL.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        let index = try MarkdownExporter.write(title: name, date: created, duration: duration,
                                               frames: frames, segments: segments,
                                               to: outputDirectory)
        progress(.exporting, 1)
        return index
    }

    // MARK: - Audio

    /// 16kHz mono Float32 samples from the file's first audio track.
    private static func loadAudio(from asset: AVURLAsset, url: URL) async throws -> [Float] {
        // AVAudioFile opens some movie containers directly (and already gives us
        // the AVAudioConverter path); use it when it works, otherwise decode the
        // track with AVAssetReader.
        if let samples = try? AudioFileLoader.loadSamples(from: url), !samples.isEmpty {
            return samples
        }

        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw DiktaError.audioLoadFailed("\(url.lastPathComponent): no audio track")
        }

        let format = AudioFileLoader.whisperFormat
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: 1,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false

        let reader = try AVAssetReader(asset: asset)
        guard reader.canAdd(output) else {
            throw DiktaError.audioLoadFailed("cannot decode audio track to 16kHz mono")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw DiktaError.audioLoadFailed(reader.error?.localizedDescription ?? "reader did not start")
        }

        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let byteCount = CMBlockBufferGetDataLength(block)
            guard byteCount >= MemoryLayout<Float>.size else { continue }
            var chunk = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
            let status = chunk.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(block, atOffset: 0,
                                                  dataLength: byteCount, destination: base)
            }
            guard status == kCMBlockBufferNoErr else { continue }
            samples.append(contentsOf: chunk)
        }
        guard reader.status != .failed else {
            throw DiktaError.audioLoadFailed(reader.error?.localizedDescription ?? "audio read failed")
        }
        guard !samples.isEmpty else {
            throw DiktaError.audioLoadFailed("\(url.lastPathComponent): audio track is empty")
        }
        return samples
    }

    // MARK: - Frames

    /// Sample one frame per second, keep only the ones that look like a new
    /// screen state, and write those as `frames/%04d.png`.
    private static func extractFrames(from asset: AVURLAsset,
                                      duration: TimeInterval,
                                      into directory: URL,
                                      progress: @escaping ProgressHandler) async throws -> [MarkdownExporter.Frame] {
        let hashing = AVAssetImageGenerator(asset: asset)
        hashing.appliesPreferredTrackTransform = true
        hashing.requestedTimeToleranceBefore = .zero
        hashing.requestedTimeToleranceAfter = .zero
        hashing.maximumSize = hashingMaxSize

        // Kept frames are re-generated at full resolution: there are few of them
        // and the saved PNG is what the reader actually looks at.
        let saving = AVAssetImageGenerator(asset: asset)
        saving.appliesPreferredTrackTransform = true
        saving.requestedTimeToleranceBefore = .zero
        saving.requestedTimeToleranceAfter = .zero

        var frames: [MarkdownExporter.Frame] = []
        var keptHashes: [UInt64] = []
        var time: TimeInterval = 0

        while time < duration {
            defer { time += sampleInterval }
            progress(.extractingFrames, min(1, time / duration))
            let cmTime = CMTime(seconds: time, preferredTimescale: 600)
            guard let candidate = try? await hashing.image(at: cmTime).image else { continue }
            let hash = FrameHasher.dHash(candidate)

            if let lastHash = keptHashes.last {
                guard FrameHasher.hammingDistance(hash, lastHash) > sceneThreshold,
                      !keptHashes.contains(where: {
                          FrameHasher.hammingDistance(hash, $0) <= duplicateThreshold
                      })
                else { continue }
            }
            // (no last hash → this is the first frame, always kept)

            let image = (try? await saving.image(at: cmTime).image) ?? candidate
            let filename = String(format: "%04d.png", frames.count + 1)
            try writePNG(image, to: directory.appendingPathComponent(filename))
            frames.append(MarkdownExporter.Frame(file: "frames/\(filename)", timestamp: time))
            keptHashes.append(hash)
        }
        return frames
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw DiktaError.frameWriteFailed(url.lastPathComponent)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw DiktaError.frameWriteFailed(url.lastPathComponent)
        }
    }
}
