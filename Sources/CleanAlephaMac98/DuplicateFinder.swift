import Foundation

/// Finds byte-identical duplicate files across the given roots.
///
/// Three tiers, cheapest first:
///   1. bucket by **exact size** (files that differ in size can't be duplicates),
///   2. split each size-collision by a cheap **partial** hash (head/middle/tail sample),
///   3. confirm each remaining collision with a full streaming **SHA-256**.
///
/// Only files sharing a full SHA-256 are reported — so the Duplicates module never offers a
/// non-duplicate for deletion. Tier 2/3 hashing runs data-parallel across CPU cores.
enum DuplicateFinder {
    struct Config: Sendable {
        var minFileBytes: Int64 = 1_048_576        // ignore sub-1MB noise
        var maxItems: Int = 200
        var enumerateCap: Int = 200_000            // safety ceiling per run
    }

    /// Thread-safe sink for the parallel confirm phase (avoids capturing a mutable `var`
    /// in the concurrent closure under Swift 6 strict concurrency).
    private final class SetSink: @unchecked Sendable {
        private let lock = NSLock()
        private var sets: [[URL]] = []
        func add(_ found: [[URL]]) {
            guard !found.isEmpty else { return }
            lock.lock(); sets.append(contentsOf: found); lock.unlock()
        }
        var all: [[URL]] {
            lock.lock(); defer { lock.unlock() }; return sets
        }
    }

    static func find(in roots: [URL], config: Config = Config()) -> Gathered {
        let (bySize, failed) = bucketBySize(roots: roots, config: config)

        // Only size-collisions can be duplicates; process biggest first so `maxItems` keeps the
        // most valuable finds.
        let groups = bySize
            .filter { $0.value.count > 1 }
            .map { (size: $0.key, urls: $0.value) }
            .sorted { $0.size > $1.size }

        let sets = confirmDuplicateSets(groups)
        var items = sets.flatMap { buildItems(for: $0) }
        items.sort { $0.bytes > $1.bytes }
        return Gathered(items: Array(items.prefix(config.maxItems)), failed: failed)
    }

    // MARK: - Tier 1: size buckets

    private static func bucketBySize(roots: [URL], config: Config) -> ([Int64: [URL]], Bool) {
        let fm = FileManager.default
        var bySize: [Int64: [URL]] = [:]
        var failed = false
        var n = 0
        for root in roots {
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                if fm.fileExists(atPath: root.path) { failed = true }
                continue
            }
            for case let url as URL in en {
                ScanThrottle.tickSync(every: 500, counter: &n) // owns the counter (increments once)
                if n > config.enumerateCap { break }
                // Don't descend into dependency/VCS/build trees — hundreds of thousands of tiny files
                // that are never the duplicates a user cares about, and the biggest time sink.
                if SimilarImageFinder.skipDirs.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                if Keep.isProtected(url) { en.skipDescendants(); continue }
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      rv.isRegularFile == true,
                      let size = rv.fileSize,
                      Int64(size) >= config.minFileBytes else { continue }
                bySize[Int64(size), default: []].append(url)
            }
        }
        return (bySize, failed)
    }

    // MARK: - Tiers 2 & 3: partial then full-hash confirmation (parallel)

    private static func confirmDuplicateSets(_ groups: [(size: Int64, urls: [URL])]) -> [[URL]] {
        guard !groups.isEmpty else { return [] }
        let sink = SetSink()
        DispatchQueue.concurrentPerform(iterations: groups.count) { i in
            let group = groups[i]

            // Tier 2 — cheap split by partial hash.
            var byPartial: [String: [URL]] = [:]
            for url in group.urls {
                guard let p = ContentHash.partial(url, size: group.size) else { continue }
                byPartial[p, default: []].append(url)
            }

            // Tier 3 — confirm survivors with a full SHA-256.
            var confirmed: [[URL]] = []
            for (_, sameSample) in byPartial where sameSample.count > 1 {
                var byFull: [String: [URL]] = [:]
                for url in sameSample {
                    guard let f = ContentHash.full(url) else { continue }
                    byFull[f, default: []].append(url)
                }
                for (_, twins) in byFull where twins.count > 1 {
                    confirmed.append(twins.sorted { $0.path < $1.path })
                }
            }
            sink.add(confirmed)
        }
        return sink.all
    }

    // MARK: - Item construction

    private static func buildItems(for set: [URL]) -> [JunkItem] {
        guard set.count > 1 else { return [] }
        let keep = chooseKeep(set)
        let size = fileSize(keep)
        return set.compactMap { url -> JunkItem? in
            guard url != keep else { return nil }
            return JunkItem(
                id: "dup-\(StableID.of(url.standardizedFileURL.path))",
                module: .duplicates,
                title: Line.proper(url.lastPathComponent),
                subtitle: Line(
                    ru: "\(Copy.dupKeepOne.ru) \(ByteFormat.string(size, .ru)) · оставим «\(keep.lastPathComponent)»",
                    en: "\(Copy.dupKeepOne.en) \(ByteFormat.string(size, .en)) · keeping “\(keep.lastPathComponent)”"
                ),
                url: url,
                bytes: size,
                selected: false,
                kind: .deleteItem,
                keepsLogins: false
            )
        }
    }

    /// Deterministic "survivor" for a duplicate set: prefer a copy *not* in Downloads (that's
    /// usually the working original), then the shortest path, then the oldest file.
    static func chooseKeep(_ set: [URL]) -> URL {
        set.min { a, b in
            let da = inDownloads(a), db = inDownloads(b)
            if da != db { return !da }               // keep the non-Downloads copy
            if a.path.count != b.path.count { return a.path.count < b.path.count }
            return mtime(a) < mtime(b)               // keep the older
        } ?? set[0]
    }

    private static func inDownloads(_ url: URL) -> Bool {
        url.standardizedFileURL.path.contains("/Downloads/")
    }

    private static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantFuture
    }

    private static func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
    }
}
