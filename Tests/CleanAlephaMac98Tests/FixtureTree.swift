import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A throwaway directory tree under the system temp dir, cleaned up on `tearDown()`.
final class FixtureTree {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam98-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes `data` to `relativePath` (creating parent dirs) and returns the file URL.
    @discardableResult
    func write(_ relativePath: String, _ data: Data) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url)
        return url
    }

    /// Deterministic filler of `count` bytes (repeating 0x00..0xFF).
    static func bytes(_ count: Int, seed: UInt8 = 0) -> Data {
        var d = Data(count: count)
        for i in 0..<count { d[i] = UInt8((i &+ Int(seed)) & 0xFF) }
        return d
    }

    /// Writes a deterministic PNG "scene" of colored rectangles seeded by `seed`. Same seed at a
    /// different size yields a perceptually-similar image (near dHash); a different seed yields a
    /// distinct one — the fixtures the similar-image tests need.
    @discardableResult
    func writeScene(_ relativePath: String, width: Int, height: Int, seed: UInt64) -> URL {
        let url = root.appendingPathComponent(relativePath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        var s = seed &+ 0x9E37_79B9_7F4A_7C15
        func rnd() -> Double {
            s = s &* 6364136223846793005 &+ 1442695040888963407
            return Double(s >> 11) / Double(UInt64(1) << 53)
        }
        for _ in 0..<14 {
            ctx.setFillColor(CGColor(red: rnd(), green: rnd(), blue: rnd(), alpha: 1))
            ctx.fill(CGRect(
                x: rnd() * Double(width), y: rnd() * Double(height),
                width: rnd() * Double(width) * 0.5 + 6, height: rnd() * Double(height) * 0.5 + 6))
        }

        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        return url
    }
}
