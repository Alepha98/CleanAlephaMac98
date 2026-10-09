import CryptoKit
import Darwin
import Foundation

struct ImagePixelFingerprint: Codable, Sendable {
    let aspect: Double
    let width: Int
    let height: Int
    let average: UInt64
    let horizontal: UInt64
    let vertical: UInt64
}

/// Persistent path-free cache for the inexpensive image prefilter.
/// Vision runs only after this filter finds a close candidate pair.
enum ImageFingerprintCache {
    private struct Entry: Codable {
        let fingerprint: ImagePixelFingerprint
        var lastAccess: TimeInterval
    }

    private struct Store: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private static let version = 1
    private static let maximumEntries = 22_000
    private static let retainedEntries = 16_000
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var dirty = false
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    static func fingerprint(
        for url: URL,
        compute: () -> ImagePixelFingerprint?
    ) -> ImagePixelFingerprint? {
        var before = stat()
        guard url.path.withCString({ lstat($0, &before) }) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              (before.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
        let key = cacheKey(before)
        if let cached = cachedValue(for: key) {
            var after = stat()
            guard url.path.withCString({ lstat($0, &after) }) == 0,
                  stable(before, after) else { return nil }
            return cached
        }
        guard let made = compute() else { return nil }
        var after = stat()
        guard url.path.withCString({ lstat($0, &after) }) == 0,
              stable(before, after) else { return nil }
        lock.lock()
        loadIfNeededLocked()
        entries[key] = Entry(fingerprint: made, lastAccess: Date().timeIntervalSince1970)
        dirty = true
        lock.unlock()
        return made
    }

    static func flush() {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard dirty else { return }
        if entries.count > maximumEntries {
            entries = Dictionary(
                uniqueKeysWithValues: entries
                    .sorted { $0.value.lastAccess > $1.value.lastAccess }
                    .prefix(retainedEntries)
                    .map { ($0.key, $0.value) }
            )
        }
        do {
            let url = storeURL
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(Store(version: version, entries: entries))
                .write(to: url, options: .atomic)
            dirty = false
        } catch {
            CamLog.line("image fingerprint cache write failed: \(error.localizedDescription)")
        }
    }

    private static func cachedValue(for key: String) -> ImagePixelFingerprint? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = Date().timeIntervalSince1970
        entries[key] = entry
        return entry.fingerprint
    }

    private static func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == version else { return }
        entries = store.entries
    }

    private static func cacheKey(_ info: stat) -> String {
        let raw = [
            "image-pixel-v1",
            String(UInt64(bitPattern: Int64(info.st_dev))),
            String(UInt64(info.st_ino)),
            String(Int64(info.st_size)),
            String(info.st_mtimespec.tv_sec),
            String(info.st_mtimespec.tv_nsec),
            String(info.st_ctimespec.tv_sec),
            String(info.st_ctimespec.tv_nsec)
        ].joined(separator: ":")
        return SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func stable(_ before: stat, _ after: stat) -> Bool {
        before.st_dev == after.st_dev
            && before.st_ino == after.st_ino
            && before.st_size == after.st_size
            && before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec
            && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec
            && before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec
            && before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec
    }

    private static var storeURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("CleanAlephaMac98/Indexes", isDirectory: true)
            .appendingPathComponent("image-pixels-v1.json")
    }
}
