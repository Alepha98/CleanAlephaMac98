import Foundation

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
}
