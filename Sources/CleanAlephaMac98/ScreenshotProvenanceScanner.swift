import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

/// Correlates known hidden screenshot remnants with Telegram's local media stores.
///
/// Telegram normally replaces the original filename with an opaque resource id and can
/// recompress an image when it is sent as a photo. Filename, extension and Spotlight-only
/// searches therefore miss the most interesting copies. This pass uses two independent
/// signals instead:
///   1. a full SHA-256 digest for byte-identical copies;
///   2. a small pixel fingerprint plus aspect ratio for resized/recompressed copies.
///
/// Results are deliberately audit-only. A visual match is evidence, not sufficient authority
/// to delete a chat attachment, and no postbox database or Telegram session file is opened.
enum ScreenshotProvenanceScanner {
    struct AuditSummary: Sendable {
        let cards: [JunkItem]
        let sourceImages: Int
        let candidateFiles: Int
        let decodedImages: Int
        let exactMatches: Int
        let visualMatches: Int
        let matchedBytes: Int64
        let matchedSources: [String: Int]
        let denied: Int
        let timedOut: Bool
    }

    private struct ImageSignature {
        let url: URL
        let logicalSize: Int64
        let aspect: Double
        let averageHash: UInt64
        let horizontalHash: UInt64
        let verticalHash: UInt64
        let digest: String
    }

    private struct RootMatches {
        let url: URL
        var candidates = 0
        var decoded = 0
        var exact = 0
        var visual = 0
        var bytes: Int64 = 0
        var sourceOwners: [String: Int] = [:]
        var denied = 0
    }

    private struct FileStat {
        let logical: Int64
        let allocated: Int64
        let identity: String
    }

    private static let maximumFileBytes: Int64 = 96 * 1_048_576
    private static let minimumFileBytes: Int64 = 16_384
    private static let maximumEntries = 80_000
    private static let deadlineSeconds: TimeInterval = 45
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func items() -> [JunkItem] {
        audit().cards
    }

    static func audit(now: Date = Date()) -> AuditSummary {
        let started = Date()
        let sourceURLs = captureSourceURLs(now: now)
        var sources: [ImageSignature] = []
        var seenSources = Set<String>()
        for url in sourceURLs {
            guard Date().timeIntervalSince(started) < deadlineSeconds,
                  let info = regularLocalFile(url),
                  info.logical >= minimumFileBytes, info.logical <= maximumFileBytes,
                  seenSources.insert(info.identity).inserted,
                  isImageByMagic(url),
                  let pixels = pixelSignature(url),
                  let digest = ContentFingerprinter.fullSignature(url, expectedSize: info.logical) else { continue }
            sources.append(ImageSignature(
                url: url,
                logicalSize: info.logical,
                aspect: pixels.aspect,
                averageHash: pixels.average,
                horizontalHash: pixels.horizontal,
                verticalHash: pixels.vertical,
                digest: digest
            ))
        }

        guard !sources.isEmpty else {
            CamLog.line("screenshot provenance sources=0 roots=\(telegramMediaRoots().count)")
            return AuditSummary(
                cards: [], sourceImages: 0, candidateFiles: 0, decodedImages: 0,
                exactMatches: 0, visualMatches: 0, matchedBytes: 0,
                matchedSources: [:],
                denied: 0, timedOut: Date().timeIntervalSince(started) >= deadlineSeconds
            )
        }

        let sourceSizes = Set(sources.map(\.logicalSize))
        let sourcesBySize = Dictionary(grouping: sources, by: \.logicalSize)
        var results: [RootMatches] = []
        var seenDestinations = Set<String>()
        var totalEntries = 0
        var timedOut = false

        rootLoop: for root in telegramMediaRoots() {
            guard Date().timeIntervalSince(started) < deadlineSeconds else {
                timedOut = true
                break
            }
            var result = RootMatches(url: root)
            let isDarwinTelegramTemp = SystemDeepScanner.tempRootURL.map {
                canonicalPath($0) == canonicalPath(root)
            } ?? false

            func inspect(_ url: URL) -> Bool {
                totalEntries += 1
                if totalEntries > maximumEntries
                    || Date().timeIntervalSince(started) >= deadlineSeconds {
                    timedOut = true
                    return false
                }
                if isDarwinTelegramTemp, !HiddenCaptureScanner.isTelegramTemporaryMedia(url) {
                    return true
                }
                guard let info = regularLocalFile(url),
                      info.logical >= minimumFileBytes, info.logical <= maximumFileBytes,
                      seenDestinations.insert(info.identity).inserted else { return true }
                result.candidates += 1
                guard isImageByMagic(url) else { return true }

                var exact = false
                if sourceSizes.contains(info.logical),
                   let digest = ContentFingerprinter.fullSignature(url, expectedSize: info.logical),
                   let source = sourcesBySize[info.logical]?.first(where: { $0.digest == digest }) {
                    exact = true
                    result.exact += 1
                    result.bytes += info.allocated
                    result.sourceOwners[sourceOwner(source.url), default: 0] += 1
                }

                guard let pixels = pixelSignature(url, matchingAspects: sources.map(\.aspect)) else { return true }
                result.decoded += 1
                if !exact, let source = bestVisualMatch(pixels, among: sources) {
                    result.visual += 1
                    result.bytes += info.allocated
                    result.sourceOwners[sourceOwner(source.url), default: 0] += 1
                }
                return true
            }

            if isDarwinTelegramTemp {
                guard let children = try? FileManager.default.contentsOfDirectory(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: []
                ) else {
                    result.denied += 1
                    results.append(result)
                    continue
                }
                for url in children where !inspect(url) {
                    results.append(result)
                    break rootLoop
                }
            } else {
                guard let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsPackageDescendants],
                    errorHandler: { _, _ in result.denied += 1; return true }
                ) else {
                    result.denied += 1
                    results.append(result)
                    continue
                }
                for case let url as URL in enumerator where !inspect(url) {
                    results.append(result)
                    break rootLoop
                }
            }
            results.append(result)
        }

        let cards = results.compactMap { result -> JunkItem? in
            guard result.exact + result.visual > 0 else { return nil }
            let coverageRU = timedOut ? "проход достиг лимита времени" : "хранилище проверено"
            let coverageEN = timedOut ? "scan reached its time limit" : "store checked"
            let evidence = result.sourceOwners
                .sorted { lhs, rhs in lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: ", ")
            return JunkItem(
                id: "forensic-screenshot-copy-\(stableKey(result.url.path))",
                module: .junk,
                title: Line(
                    ru: "Telegram · подтверждённые копии скриншотов",
                    en: "Telegram · confirmed screenshot copies"
                ),
                subtitle: Line(
                    ru: "\(result.exact) точных + \(result.visual) пережатых совпадений из \(sources.count) скрытых эталонов · источники: \(evidence) · \(coverageRU) · базы и аккаунты не открывались · только аудит",
                    en: "\(result.exact) exact + \(result.visual) recompressed matches from \(sources.count) hidden references · sources: \(evidence) · \(coverageEN) · databases and accounts were not opened · audit only"
                ),
                url: result.url,
                bytes: result.bytes,
                selected: false,
                kind: .advice,
                keepsLogins: true
            )
        }
        let summary = AuditSummary(
            cards: cards,
            sourceImages: sources.count,
            candidateFiles: results.reduce(0) { $0 + $1.candidates },
            decodedImages: results.reduce(0) { $0 + $1.decoded },
            exactMatches: results.reduce(0) { $0 + $1.exact },
            visualMatches: results.reduce(0) { $0 + $1.visual },
            matchedBytes: results.reduce(0) { $0 + $1.bytes },
            matchedSources: results.reduce(into: [:]) { combined, result in
                for (owner, count) in result.sourceOwners { combined[owner, default: 0] += count }
            },
            denied: results.reduce(0) { $0 + $1.denied },
            timedOut: timedOut
        )
        CamLog.line(
            "screenshot provenance sources=\(summary.sourceImages) candidates=\(summary.candidateFiles) "
                + "decoded=\(summary.decodedImages) exact=\(summary.exactMatches) "
                + "visual=\(summary.visualMatches) bytes=\(summary.matchedBytes) "
                + "denied=\(summary.denied) timedOut=\(summary.timedOut) cards=\(cards.count)"
        )
        ContentFingerprinter.flush()
        return summary
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        guard item.id.hasPrefix("forensic-screenshot-copy-"),
              item.kind == .advice, item.selected == false, item.keepsLogins else { return false }
        let path = canonicalPath(item.url)
        return telegramMediaRoots().contains { canonicalPath($0) == path }
    }

    private static func captureSourceURLs(now: Date) -> [URL] {
        var urls = HiddenCaptureScanner.provenanceCaptureURLs(now: now)
        urls.append(contentsOf: ForensicRemnantScanner.indexedHiddenCaptures().map(\.url))
        var seen = Set<String>()
        return urls.filter { seen.insert(canonicalPath($0)).inserted }
    }

    /// Only payload roots are returned. `postbox/db`, `tdata/key_data(s)`, settings and
    /// every other authentication/session location remain outside this scanner.
    private static func telegramMediaRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = []
        let groupContainers = home.appendingPathComponent("Library/Group Containers")
        if let containers = try? fm.contentsOfDirectory(
            at: groupContainers,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for container in containers {
                let name = container.lastPathComponent.lowercased()
                guard name.contains("telegram") || name.contains("keepcoder") else { continue }
                let stable = container.appendingPathComponent("stable")
                guard let accounts = try? fm.contentsOfDirectory(
                    at: stable,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: []
                ) else { continue }
                for account in accounts where account.lastPathComponent.hasPrefix("account-") {
                    let media = account.appendingPathComponent("postbox/media")
                    if isDirectory(media) { roots.append(media) }
                }
            }
        }

        let tdata = home.appendingPathComponent("Library/Application Support/Telegram Desktop/tdata")
        if let children = try? fm.contentsOfDirectory(
            at: tdata,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) {
            for userData in children where userData.lastPathComponent.hasPrefix("user_data") {
                for leaf in ["cache", "media_cache"] {
                    let cache = userData.appendingPathComponent(leaf)
                    if isDirectory(cache) { roots.append(cache) }
                }
            }
        }
        if let temp = SystemDeepScanner.tempRootURL, isDirectory(temp) {
            roots.append(temp)
        }
        var seen = Set<String>()
        return roots.filter { seen.insert(canonicalPath($0)).inserted }.sorted { $0.path < $1.path }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func regularLocalFile(_ url: URL) -> FileStat? {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0,
              (info.st_mode & S_IFMT) == S_IFREG,
              (info.st_flags & UInt32(SF_DATALESS)) == 0 else { return nil }
        let allocated = Int64(info.st_blocks) * 512
        guard allocated > 0 else { return nil }
        return FileStat(
            logical: Int64(info.st_size),
            allocated: allocated,
            identity: "\(info.st_dev):\(info.st_ino)"
        )
    }

    private static func isImageByMagic(_ url: URL) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16)
        let fd = url.path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let count = read(fd, &bytes, bytes.count)
        guard count >= 3 else { return false }
        let n = Int(count)
        if n >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return true }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return true }
        if n >= 6, String(bytes: bytes[0..<6], encoding: .ascii)?.hasPrefix("GIF8") == true { return true }
        if n >= 4 {
            let prefix = Array(bytes[0..<4])
            if prefix == [0x49, 0x49, 0x2A, 0x00] || prefix == [0x4D, 0x4D, 0x00, 0x2A] {
                return true
            }
        }
        if n >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return true }
        if n >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
            return ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(brand)
        }
        return false
    }

    private static func pixelSignature(
        _ url: URL,
        matchingAspects: [Double]? = nil
    ) -> (aspect: Double, average: UInt64, horizontal: UInt64, vertical: UInt64)? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width >= 32, height >= 32 else { return nil }
        let aspect = max(width, height) / min(width, height)
        if let matchingAspects,
           !matchingAspects.contains(where: { abs(aspect - $0) / max(aspect, $0) <= 0.006 }) {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 48,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions),
              let pixels = grayscalePixels(image, width: 9, height: 9) else { return nil }

        var sum = 0
        for y in 0..<8 { for x in 0..<8 { sum += Int(pixels[y * 9 + x]) } }
        let averageValue = UInt8(sum / 64)
        var average: UInt64 = 0
        var horizontal: UInt64 = 0
        var vertical: UInt64 = 0
        var bit = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if pixels[y * 9 + x] >= averageValue { average |= UInt64(1) << UInt64(bit) }
                if pixels[y * 9 + x] > pixels[y * 9 + x + 1] { horizontal |= UInt64(1) << UInt64(bit) }
                if pixels[y * 9 + x] > pixels[(y + 1) * 9 + x] { vertical |= UInt64(1) << UInt64(bit) }
                bit += 1
            }
        }
        return (aspect, average, horizontal, vertical)
    }

    private static func grayscalePixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let made = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return made ? pixels : nil
    }

    private static func bestVisualMatch(
        _ candidate: (aspect: Double, average: UInt64, horizontal: UInt64, vertical: UInt64),
        among sources: [ImageSignature]
    ) -> ImageSignature? {
        var best: (source: ImageSignature, score: Int)?
        for source in sources {
            let relativeAspect = abs(candidate.aspect - source.aspect) / max(candidate.aspect, source.aspect)
            guard relativeAspect <= 0.006 else { continue }
            let averageDistance = (candidate.average ^ source.averageHash).nonzeroBitCount
            let edgeDistance = (candidate.horizontal ^ source.horizontalHash).nonzeroBitCount
                + (candidate.vertical ^ source.verticalHash).nonzeroBitCount
            guard averageDistance <= 5, edgeDistance <= 10 else { continue }
            let score = averageDistance * 2 + edgeDistance
            if best == nil || score < best!.score { best = (source, score) }
        }
        return best?.source
    }

    private static func sourceOwner(_ url: URL) -> String {
        let lower = canonicalPath(url).lowercased()
        if lower.contains("/nsird_screencaptureui_")
            || lower.contains("/com.apple.screencaptureui/") { return "ScreenCaptureUI" }
        if lower.contains("/application support/cursor/")
            || lower.contains("/.cursor/") { return "Cursor" }
        if lower.contains("/application support/claude/")
            || lower.contains("/.claude/") { return "Claude" }
        if lower.contains("/pixelmator pro/sessiondata/") { return "Pixelmator recovery" }
        if lower.contains("/quicktimeplayerx/") { return "QuickTime" }
        if lower.contains("/screenrecordings/") || lower.contains("/replayd/") { return "Screen recording" }
        if lower.contains("/library/mobile documents/") { return "iCloud Drive" }
        if lower.contains("/private/var/folders/") || lower.contains("/var/folders/") { return "Darwin temp" }
        if lower.contains("/library/") { return "hidden Library store" }
        return "macOS index"
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}
