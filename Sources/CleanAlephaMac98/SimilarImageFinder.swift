import Foundation

/// Finds **visually similar** images (resized / re-encoded / lightly edited copies) via a
/// perceptual dHash — the "similar photos" feature from Gemini / CleanMyMac. These are surfaced in
/// the Duplicates module, always off by default and badged "review", because — unlike exact
/// duplicates — they are not byte-identical and the user must judge which to keep.
enum SimilarImageFinder {
    struct Config: Sendable {
        var minFileBytes: Int64 = 51_200   // 50KB — skip icons/thumbnails
        var maxImages: Int = 4000
        var maxDistance: Int = 8           // Hamming distance ≤ this ⇒ "looks the same"
        var maxItems: Int = 120
    }

    static let imageExtensions: Set<String> =
        ["jpg", "jpeg", "png", "heic", "heif", "gif", "tiff", "tif", "bmp", "webp"]

    private struct Img: Sendable { let url: URL; let size: Int64; let hash: UInt64 }

    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var xs: [Img] = []
        func add(_ x: Img?) { guard let x else { return }; lock.lock(); xs.append(x); lock.unlock() }
        var all: [Img] { lock.lock(); defer { lock.unlock() }; return xs }
    }

    static func find(in roots: [URL], config: Config = Config()) -> [JunkItem] {
        let candidates = collect(roots: roots, config: config)
        guard candidates.count > 1 else { return [] }

        // Perceptual hashes are independent per image → hash them in parallel.
        let sink = Sink()
        DispatchQueue.concurrentPerform(iterations: candidates.count) { i in
            let (url, size) = candidates[i]
            sink.add(ImageHash.dHash(url).map { Img(url: url, size: size, hash: $0) })
        }

        // Largest file first so each cluster keeps the highest-resolution copy.
        let images = sink.all.sorted { $0.size > $1.size }

        // Greedy clustering: join the first representative within `maxDistance`, else start a cluster.
        var repHashes: [UInt64] = []
        var clusters: [[Img]] = []
        for img in images {
            if let idx = repHashes.firstIndex(where: { ImageHash.distance($0, img.hash) <= config.maxDistance }) {
                clusters[idx].append(img)
            } else {
                repHashes.append(img.hash)
                clusters.append([img])
            }
        }

        var items: [JunkItem] = []
        for cluster in clusters where cluster.count > 1 {
            let keep = cluster[0] // largest
            for img in cluster.dropFirst() {
                items.append(JunkItem(
                    id: "sim-\(StableID.of(img.url.standardizedFileURL.path))",
                    module: .duplicates,
                    title: Line.proper(img.url.lastPathComponent),
                    subtitle: Line(
                        ru: "Похожее фото · оставим «\(keep.url.lastPathComponent)» · проверь",
                        en: "Similar photo · keeping “\(keep.url.lastPathComponent)” · review"
                    ),
                    url: img.url,
                    bytes: img.size,
                    selected: false,
                    kind: .deleteItem,
                    keepsLogins: false
                ))
            }
        }
        return Array(items.sorted { $0.bytes > $1.bytes }.prefix(config.maxItems))
    }

    private static func collect(roots: [URL], config: Config) -> [(URL, Int64)] {
        let fm = FileManager.default
        var out: [(URL, Int64)] = []
        var n = 0
        for root in roots {
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in en {
                ScanThrottle.tickSync(every: 500, counter: &n)
                if out.count >= config.maxImages { break }
                if Keep.isProtected(url) { en.skipDescendants(); continue }
                guard imageExtensions.contains(url.pathExtension.lowercased()) else { continue }
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      rv.isRegularFile == true,
                      let size = rv.fileSize,
                      Int64(size) >= config.minFileBytes else { continue }
                out.append((url, Int64(size)))
            }
        }
        return out
    }
}
