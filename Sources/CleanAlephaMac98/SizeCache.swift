import Foundation

/// Memoizes directory sizes so the same folder isn't walked twice within a scan (and again at
/// clean time). Keyed by `(standardized path, directory mtime)` with a short TTL: adding or
/// removing a direct child bumps the dir's mtime and misses the cache, so `freed = before - after`
/// accounting stays correct without explicit invalidation.
///
/// A lock-guarded class (not an `actor`) because `DiskSizer.bytes(at:)` is called from synchronous
/// scan/clean paths that can't `await`.
final class SizeCache: @unchecked Sendable {
    static let shared = SizeCache()

    private struct Entry {
        let mtime: Date
        let bytes: Int64
        let storedAt: Date
    }

    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    private let ttl: TimeInterval = 90

    func lookup(_ url: URL) -> Int64? {
        guard let mtime = Self.mtime(url) else { return nil }
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        guard let e = map[path], e.mtime == mtime,
              Date().timeIntervalSince(e.storedAt) <= ttl else { return nil }
        return e.bytes
    }

    func store(_ url: URL, bytes: Int64) {
        guard let mtime = Self.mtime(url) else { return }
        let path = url.standardizedFileURL.path
        lock.lock(); map[path] = Entry(mtime: mtime, bytes: bytes, storedAt: Date()); lock.unlock()
    }

    func clear() {
        lock.lock(); map.removeAll(); lock.unlock()
    }

    /// Reads via `FileManager` rather than `URL.resourceValues`, which caches per URL instance and
    /// would otherwise report a stale mtime (causing the cache to never invalidate).
    private static func mtime(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }
}
