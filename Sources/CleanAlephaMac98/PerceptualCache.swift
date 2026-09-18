import Foundation

/// Persistent cache of perceptual image hashes, keyed by `(path, mtime, size)`. A file's dHash is
/// fully determined by its bytes, and any edit changes its mtime **and** usually its size — so unlike
/// a *directory* size (which a deep change can leave stale), a file-hash cache keyed on mtime+size is
/// exact with no TTL. Decoding thousands of photos is the single most expensive part of a scan; this
/// makes every rescan after the first nearly free.
///
/// A lock-guarded class (not an `actor`) because it is called from the synchronous, parallel
/// `DispatchQueue.concurrentPerform` hashing loop. The expensive decode happens outside the lock.
final class PerceptualCache: @unchecked Sendable {
    static let shared = PerceptualCache()

    private struct Entry: Codable { let m: Double; let s: Int64; let h: UInt64 }

    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    private var dirty = false
    private var loaded = false

    /// ~/Library/Application Support/CleanAlephaMac98/perceptual.cache
    private static let fileURL: URL? = {
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        let dir = base.appendingPathComponent("CleanAlephaMac98", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("perceptual.cache")
    }()

    /// Load the persisted cache once, synchronously, BEFORE the parallel hashing loop. Doing this
    /// lazily inside `hash(for:)` raced: the first thread set `loaded` before the map was populated,
    /// so the other threads sailed past an empty map and recomputed everything.
    func preload() {
        lock.lock()
        defer { lock.unlock() }
        guard !loaded else { return }
        loaded = true
        guard let url = Self.fileURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        map = decoded
    }

    /// Returns the dHash for `file`, reusing a cached value when the file is unchanged and computing
    /// (and caching) it otherwise. Returns `nil` only when the file cannot be decoded as an image.
    func hash(for file: URL, compute: (URL) -> UInt64? = ImageHash.dHash) -> UInt64? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970,
              let size = (attrs[.size] as? NSNumber)?.int64Value else {
            return compute(file)
        }
        let key = file.standardizedFileURL.path
        lock.lock()
        if let e = map[key], e.m == mtime, e.s == size {
            lock.unlock()
            return e.h
        }
        lock.unlock()

        guard let h = compute(file) else { return nil }
        lock.lock()
        map[key] = Entry(m: mtime, s: size, h: h)
        dirty = true
        lock.unlock()
        return h
    }

    /// Persist new entries. Call once after a hashing batch.
    func flush() {
        lock.lock()
        let shouldWrite = dirty
        let snapshot = map
        dirty = false
        lock.unlock()
        guard shouldWrite, let url = Self.fileURL else { return }
        // Bound the file: keep it from growing without limit across a machine's lifetime.
        let capped = snapshot.count > 40_000
            ? Dictionary(uniqueKeysWithValues: snapshot.prefix(40_000).map { ($0.key, $0.value) })
            : snapshot
        if let data = try? JSONEncoder().encode(capped) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
