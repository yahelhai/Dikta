import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decides which captured frames are worth keeping ("slides") and writes those
/// to disk as PNGs.
///
/// Called straight from the ScreenCaptureKit sample queue, so it is a plain
/// non-isolated class: shared state lives behind an `NSLock` and the actual PNG
/// encoding is pushed to a utility queue, keeping the capture callback cheap.
final class SceneCollector: @unchecked Sendable {
    /// Distance from the last kept frame above which we call it a new scene.
    static let sceneThreshold = 10
    /// Distance at or below which a frame repeats one we already kept
    /// (global dedup — catches going back to an earlier slide).
    static let duplicateThreshold = 6

    /// How many full-size images may be waiting to be encoded at once. Each one
    /// is a whole screen of pixels (~31MB at 3456×2234), so an unbounded backlog
    /// is unbounded memory; blocking the capture queue instead costs at most a
    /// dropped frame, and frames are deduplicated anyway.
    static let maximumPendingWrites = 2

    private let directory: URL
    private let writeQueue = DispatchQueue(label: "com.yahel.dikta.frame-writer", qos: .utility)
    private let writeGroup = DispatchGroup()
    private let writeSlots = DispatchSemaphore(value: SceneCollector.maximumPendingWrites)
    private let onKeep: @Sendable (MarkdownExporter.Frame) -> Void

    private let lock = NSLock()
    private var keptHashes: [UInt64] = []
    private var frames: [MarkdownExporter.Frame] = []

    /// `onKeep` fires once the PNG is on disk, so a caller recording frame
    /// timestamps never records one whose image is missing.
    init(directory: URL, onKeep: @escaping @Sendable (MarkdownExporter.Frame) -> Void = { _ in }) {
        self.directory = directory
        self.onKeep = onKeep
    }

    /// Offer a captured frame. Returns true when it was kept (and queued for
    /// writing). The very first frame is always kept — there is nothing before
    /// it to have changed from.
    @discardableResult
    func consider(image: CGImage, timestamp: TimeInterval) -> Bool {
        let hash = FrameHasher.dHash(image)

        lock.lock()
        if let lastHash = keptHashes.last {
            let changedEnough = FrameHasher.hammingDistance(hash, lastHash) > Self.sceneThreshold
            let isRepeat = keptHashes.contains {
                FrameHasher.hammingDistance(hash, $0) <= Self.duplicateThreshold
            }
            guard changedEnough, !isRepeat else {
                lock.unlock()
                return false
            }
        }
        let filename = String(format: "%04d.png", frames.count + 1)
        let frame = MarkdownExporter.Frame(file: "frames/\(filename)", timestamp: timestamp)
        keptHashes.append(hash)
        frames.append(frame)
        lock.unlock()

        let url = directory.appendingPathComponent(filename)
        writeSlots.wait()
        writeQueue.async(group: writeGroup) { [onKeep, writeSlots] in
            defer { writeSlots.signal() }
            do {
                try Self.writePNG(image, to: url)
                onKeep(frame)
            } catch {
                // finish() drops frames whose PNG never landed, so the Markdown
                // can't end up pointing at a missing image.
                NSLog("Dikta: frame write failed (%@): %@", filename, "\(error)")
            }
        }
        return true
    }

    /// Number of frames kept so far — for live progress display.
    var keptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return frames.count
    }

    /// Wait for every queued PNG to hit the disk, then return the kept frames in
    /// capture order. Frames whose PNG failed to write are dropped so the
    /// Markdown never points at a missing image.
    func finish() -> [MarkdownExporter.Frame] {
        writeGroup.wait()
        lock.lock()
        let result = frames
        lock.unlock()
        return result.filter {
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(($0.file as NSString).lastPathComponent).path)
        }
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
