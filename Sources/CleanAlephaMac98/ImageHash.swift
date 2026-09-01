import CoreGraphics
import Foundation
import ImageIO

/// Perceptual **difference hash** (dHash) for near-duplicate image detection — the "similar
/// photos" feature competitors ship. Unlike a byte hash, dHash is stable across resize, re-encode
/// and mild edits: two visually-alike images land within a small Hamming distance.
enum ImageHash {
    /// 64-bit dHash: decode → downscale to 9×8 grayscale → each bit is "left pixel brighter than
    /// its right neighbor" (8 rows × 8 comparisons). `nil` if the file can't be decoded as an image.
    static func dHash(_ url: URL) -> UInt64? {
        let width = 9, height = 8
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 32,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else {
            return nil
        }
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .low
        ctx.draw(thumb, in: CGRect(x: 0, y: 0, width: width, height: height))

        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for row in 0..<height {
            for col in 0..<(width - 1) {
                if pixels[row * width + col] > pixels[row * width + col + 1] {
                    hash |= (1 << bit)
                }
                bit += 1
            }
        }
        return hash
    }

    /// Number of differing bits — the perceptual "distance" between two dHashes.
    static func distance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
