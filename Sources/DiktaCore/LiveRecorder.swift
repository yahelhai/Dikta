@preconcurrency import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// Live screen recording on top of `SCStream`, in a streaming shape: nothing is
/// ever written as video. Frames arrive at 1fps, get hashed and either kept as a
/// PNG or dropped on the spot; system audio is converted and spooled to a
/// temporary WAV as it arrives.
///
/// `SCStreamOutput` callbacks land on our own dispatch queues, so this class is
/// deliberately *not* `@MainActor` — shared state sits behind an `NSLock`, the
/// same pattern `AudioRecorder` uses for its realtime tap.
final class LiveRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Everything a finished recording produced. The audio itself is not here:
    /// it left as chunks during the recording (see `AudioSpooler`), each one
    /// transcribed and deleted as it closed.
    struct Result: Sendable {
        let frames: [MarkdownExporter.Frame]
        /// False when no system audio ever arrived.
        let hasAudio: Bool
        /// Wall-clock length of the recording.
        let duration: TimeInterval
        let startedAt: Date
    }

    /// Called (off the main actor) when the stream dies on its own.
    var onStreamError: (@Sendable (Error) -> Void)?

    private let videoQueue = DispatchQueue(label: "com.yahel.dikta.capture.video", qos: .userInitiated)
    private let audioQueue = DispatchQueue(label: "com.yahel.dikta.capture.audio", qos: .userInitiated)
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private let lock = NSLock()
    private var stream: SCStream?
    private var collector: SceneCollector?
    private var spooler: AudioSpooler?
    private var startedAt: Date?
    private var firstFrameTime: CMTime?

    // MARK: - Discovery

    /// Displays available for capture. Throws (and triggers the TCC prompt) when
    /// Screen Recording has not been granted.
    static func availableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        return content.displays
    }

    /// Human label for the display picker, e.g. "מסך 1 — 3456×2234 (ראשי)".
    static func label(for display: SCDisplay, index: Int) -> String {
        "מסך \(index + 1) — \(subtitle(for: display))"
    }

    /// Everything that identifies a display except its picker number, e.g.
    /// "3456×2234 (ראשי)". Shared by the menu row and the on-screen card.
    ///
    /// The resolution is wrapped in a Unicode isolate (LRI…PDI): "(ראשי)" makes
    /// the line RTL, and without the isolate bidi reorders the two number runs
    /// around the "×" — a 3456×2234 display would read "2234×3456".
    static func subtitle(for display: SCDisplay) -> String {
        let (width, height) = pixelSize(of: display)
        let main = CGMainDisplayID() == display.displayID ? " (ראשי)" : ""
        return "\u{2066}\(width)×\(height)\u{2069}\(main)"
    }

    /// Backing-store resolution, so the saved PNGs are actually readable on a
    /// Retina display (SCDisplay reports points).
    static func pixelSize(of display: SCDisplay) -> (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID) else {
            return (display.width, display.height)
        }
        return (mode.pixelWidth, mode.pixelHeight)
    }

    // MARK: - Lifecycle

    /// Synchronous critical section — `NSLock.lock()` itself is unavailable from
    /// async contexts, so every access funnels through here.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    var isRecording: Bool {
        withLock { stream != nil }
    }

    /// Frames kept so far — cheap enough to poll from the menu.
    var keptFrameCount: Int {
        withLock { collector }?.keptCount ?? 0
    }

    /// Start capturing `display` into `framesDirectory` (created if needed).
    ///
    /// Audio is chunked into `audioDirectory`; `onChunk` fires as each chunk
    /// closes, which is what lets transcription run alongside the capture.
    /// `onFrame` fires once a kept frame's PNG is actually on disk.
    func start(display: SCDisplay,
               framesDirectory: URL,
               audioDirectory: URL,
               chunkSeconds: TimeInterval = 120,
               onFrame: @escaping @Sendable (MarkdownExporter.Frame) -> Void = { _ in },
               onChunk: @escaping @Sendable (AudioSpooler.Chunk) -> Void = { _ in }) async throws {
        guard withLock({ self.stream == nil }) else { return }

        try FileManager.default.createDirectory(at: framesDirectory, withIntermediateDirectories: true)

        let (width, height) = Self.pixelSize(of: display)
        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        // One frame per second: the system throttles for us, so nothing beyond
        // the frames we actually want is ever decoded.
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 4
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        let collector = SceneCollector(directory: framesDirectory, onKeep: onFrame)
        let spooler = AudioSpooler(directory: audioDirectory,
                                   chunkSeconds: chunkSeconds,
                                   onChunk: onChunk)

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)

        withLock {
            self.stream = stream
            self.collector = collector
            self.spooler = spooler
            self.startedAt = Date()
            self.firstFrameTime = nil
        }

        do {
            try await stream.startCapture()
        } catch {
            withLock {
                self.stream = nil
                self.collector = nil
                self.spooler = nil
                self.startedAt = nil
            }
            throw DiktaError.screenCaptureFailed(error.localizedDescription)
        }
    }

    /// Stop the stream, flush pending PNG writes and close the WAV.
    func stop() async throws -> Result {
        let (stream, collector, spooler, startedAt) = withLock {
            let taken = (self.stream, self.collector, self.spooler, self.startedAt)
            self.stream = nil
            self.collector = nil
            self.spooler = nil
            self.startedAt = nil
            return taken
        }

        guard let collector, let spooler, let startedAt else {
            throw DiktaError.screenCaptureFailed("not recording")
        }
        if let stream {
            // A stream that already died on its own throws here — the frames and
            // audio captured until then are still good.
            do { try await stream.stopCapture() } catch {
                NSLog("Dikta: stopCapture: %@", "\(error)")
            }
        }

        let frames = collector.finish()
        // Closes the final chunk, which reaches `onChunk` like every other one.
        let audio = spooler.finish()
        return Result(frames: frames,
                      hasAudio: audio != nil,
                      duration: Date().timeIntervalSince(startedAt),
                      startedAt: startedAt)
    }

    /// Tear everything down (used on failure). The caller owns the session
    /// directory and removes it.
    func cancel() async {
        _ = try? await stop()
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        switch type {
        case .screen: handleVideo(sampleBuffer)
        case .audio: handleAudio(sampleBuffer)
        default: break
        }
    }

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        // Skip the "nothing changed" / blanked frames SCK also emits.
        guard Self.isComplete(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        guard let collector = self.collector else {
            lock.unlock()
            return
        }
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstFrameTime == nil { firstFrameTime = presentation }
        let origin = firstFrameTime ?? presentation
        lock.unlock()

        let timestamp = max(0, CMTimeGetSeconds(CMTimeSubtract(presentation, origin)))
        guard timestamp.isFinite else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let image = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        collector.consider(image: image, timestamp: timestamp)
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        let spooler = self.spooler
        lock.unlock()
        spooler?.append(sampleBuffer)
    }

    /// SCK marks each frame with a status attachment; only `.complete` carries
    /// new pixels.
    private static func isComplete(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first else {
            // No attachment array at all — take the frame rather than lose it.
            return true
        }
        guard let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw) else {
            return true
        }
        return status == .complete
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Dikta: screen capture stopped: %@", "\(error)")
        lock.lock()
        // Drop our handle so `stop()` doesn't try to stop a dead stream, but keep
        // the collector/spooler so whatever was captured survives.
        if self.stream === stream { self.stream = nil }
        lock.unlock()
        onStreamError?(error)
    }

}
