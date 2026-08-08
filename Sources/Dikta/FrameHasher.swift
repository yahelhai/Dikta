import CoreGraphics

/// 64-bit difference hash (dHash) used for screen scene-change detection.
///
/// Pure CoreGraphics on purpose: this runs on capture queues in the live
/// recorder, so it must not touch AppKit or the main actor.
enum FrameHasher {
    /// 9 columns give 8 horizontal comparisons per row; 8 rows → 64 bits.
    private static let hashWidth = 9
    private static let hashHeight = 8

    /// Downscale `image` to 9x8 grayscale and compare each pixel with its right
    /// neighbour. Returns 0 when the image cannot be rendered (treated as
    /// "unknown" by callers, which keeps the frame).
    static func dHash(_ image: CGImage) -> UInt64 {
        var pixels = [UInt8](repeating: 0, count: hashWidth * hashHeight)
        let rendered = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: hashWidth,
                    height: hashHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: hashWidth,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: hashWidth, height: hashHeight))
            return true
        }
        guard rendered else { return 0 }

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<hashHeight {
            for column in 0..<(hashWidth - 1) {
                let left = pixels[row * hashWidth + column]
                let right = pixels[row * hashWidth + column + 1]
                if left > right { hash |= (1 << bit) }
                bit += 1
            }
        }
        return hash
    }

    /// Number of differing bits — the perceptual distance between two frames.
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
