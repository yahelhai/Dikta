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

    private let directory: URL
    private let writeQueue = DispatchQueue(label: "com.yahel.dikta.frame-writer", qos: .utility)
    private let writeGroup = DispatchGroup()

    private let lock = NSLock()
    private var keptHashes: [UInt64] = []
    private var frames: [MarkdownExporter.Frame] = []

    init(directory: URL) {
        self.directory = directory
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
        keptHashes.append(hash)
        frames.append(MarkdownExporter.Frame(file: "frames/\(filename)", timestamp: timestamp))
        lock.unlock()

        let url = directory.appendingPathComponent(filename)
        writeQueue.async(group: writeGroup) {
            do {
                try Self.writePNG(image, to: url)
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
