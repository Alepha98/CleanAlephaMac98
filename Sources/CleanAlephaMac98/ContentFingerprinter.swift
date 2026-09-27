import CryptoKit
import Darwin
import Foundation

/// Stable, local-only content fingerprints for repeated scans.
///
/// The on-disk index contains no paths or file contents. A record is keyed by the
/// file-system identity plus size, mtime and ctime, so changing a file invalidates
/// both its sample and full digest before either can affect cleanup decisions.
enum ContentFingerprinter {
    private enum Mode: String, Codable {
        case sample
        case full
    }

    private struct Entry: Codable {
        let signature: String
        var lastAccess: TimeInterval
    }

    private struct Store: Codable {
        let version: Int
        let entries: [String: Entry]
    }

    private static let version = 1
    private static let maximumEntries = 24_000
    private static let retainedEntries = 18_000
    private static let lock = NSLock()
    nonisolated(unsafe) private static var loaded = false
    nonisolated(unsafe) private static var dirty = false
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]

    static func fullSignature(_ url: URL, expectedSize: Int64) -> String? {
        signature(url, expectedSize: expectedSize, mode: .full) { descriptor, size in
            let capacity = 1_048_576
            guard let buffer = malloc(capacity) else { return nil }
            defer { free(buffer) }
            var digest = SHA256()
            var consumed: Int64 = 0
            while true {
                let count = Darwin.read(descriptor, buffer, capacity)
                if count == 0 { break }
                if count < 0 {
                    if errno == EINTR { continue }
                    return nil
                }
                consumed += Int64(count)
                digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            }
            guard consumed == size else { return nil }
            return "\(size):\(Data(digest.finalize()).base64EncodedString())"
        }
    }

    static func sampleSignature(_ url: URL, expectedSize: Int64) -> String? {
        signature(url, expectedSize: expectedSize, mode: .sample) { descriptor, size in
            let sampleBytes = 64 * 1024
            guard let buffer = malloc(sampleBytes) else { return nil }
            defer { free(buffer) }
            let last = max(0, size - Int64(sampleBytes))
            let middle = max(0, min(last, size / 2 - Int64(sampleBytes / 2)))
            let positions = Array(Set([Int64(0), middle, last])).sorted()
            var digest = SHA256()
            digest.update(data: Data("size:\(size)".utf8))
            for position in positions {
                let wanted = Int(min(Int64(sampleBytes), size - position))
                var count: Int
                repeat {
                    count = Darwin.pread(descriptor, buffer, wanted, off_t(position))
                } while count < 0 && errno == EINTR
                guard count == wanted else { return nil }
                digest.update(data: Data("@\(position):".utf8))
                digest.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: count))
            }
            return "\(size):sample:\(Data(digest.finalize()).base64EncodedString())"
        }
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
            let data = try JSONEncoder().encode(Store(version: version, entries: entries))
            try data.write(to: url, options: .atomic)
            dirty = false
        } catch {
            CamLog.line("fingerprint cache write failed: \(error.localizedDescription)")
        }
    }

    static func resetForQA() {
        lock.lock()
        loaded = true
        dirty = false
        entries.removeAll()
        lock.unlock()
    }

    private static func signature(
        _ url: URL,
        expectedSize: Int64,
        mode: Mode,
        compute: (Int32, Int64) -> String?
    ) -> String? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        }
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var before = stat()
        guard Darwin.fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              (before.st_flags & UInt32(SF_DATALESS)) == 0,
              Int64(before.st_size) == expectedSize else { return nil }
        let key = cacheKey(before, mode: mode)

        if let cached = cachedValue(for: key) {
            var after = stat()
            guard Darwin.fstat(descriptor, &after) == 0, stable(before, after) else { return nil }
            return cached
        }

        guard let value = compute(descriptor, expectedSize) else { return nil }
        var after = stat()
        guard Darwin.fstat(descriptor, &after) == 0, stable(before, after) else { return nil }
        store(value, for: key)
        return value
    }

    private static func cachedValue(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        guard var entry = entries[key] else { return nil }
        entry.lastAccess = Date().timeIntervalSince1970
        entries[key] = entry
        return entry.signature
    }

    private static func store(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeededLocked()
        entries[key] = Entry(signature: value, lastAccess: Date().timeIntervalSince1970)
        dirty = true
    }

    private static func loadIfNeededLocked() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: storeURL),
              let store = try? JSONDecoder().decode(Store.self, from: data),
              store.version == version else { return }
        entries = store.entries
    }

    private static func cacheKey(_ info: stat, mode: Mode) -> String {
        let raw = [
            mode.rawValue,
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
            .appendingPathComponent("content-fingerprints-v1.json")
    }
}
