import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO
import Vision

/// Finds screenshot copies that survived renaming, resizing, or image recompression.
///
/// A filename is used only to establish at least one trusted screenshot reference.
/// Matching then requires the same aspect ratio, three independent pixel hashes and
/// a close on-device Vision feature print. Hidden matches remain read-only because a
/// cache/recovery copy may be the user's last recoverable version.
enum SimilarCaptureScanner {
    struct AuditSummary: Sendable {
        let cards: [JunkItem]
        let references: Int
        let candidates: Int
        let decoded: Int
        let shortlisted: Int
        let matches: Int
        let timedOut: Bool
    }

    private struct Candidate {
        let url: URL
        let facts: FileStorageFacts
        let modified: Date
        let hidden: Bool
        let reference: Bool
        let pixels: ImagePixelFingerprint
    }

    private struct Match {
        let candidate: Candidate
        let reference: Candidate
        let distance: Float
        let hashDistance: Int
    }

    private static let minimumBytes: Int64 = 16_384
    private static let maximumBytes: Int64 = 96 * 1_048_576
    private static let maximumVisibleEntries = 55_000
    private static let maximumHiddenCandidates = 18_000
    private static let normalDeadline: TimeInterval = 42
    private static let maximumVisionDistance: Float = 0.36
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func items() -> [JunkItem] {
        audit().cards
    }

    static func audit() -> AuditSummary {
        let visibleRoots = [
            home.appendingPathComponent("Desktop"),
            home.appendingPathComponent("Documents"),
            home.appendingPathComponent("Downloads"),
            home.appendingPathComponent("Pictures"),
            home.appendingPathComponent("Movies")
        ]
        let indexedCaptures = ForensicRemnantScanner.indexedHiddenCaptures().map(\.url)
        var hiddenReferences = indexedCaptures
        hiddenReferences.append(contentsOf: HiddenCaptureScanner.provenanceCaptureURLs())
        let hiddenMedia = ForensicRemnantScanner.indexedHiddenMediaForCorrelation().map(\.url)
        return scan(
            visibleRoots: visibleRoots,
            hiddenReferences: hiddenReferences,
            hiddenMedia: hiddenMedia,
            deadline: normalDeadline,
            honorProtection: true
        )
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        guard item.module == .duplicates, item.selected == false else { return false }
        if item.id == "similar-capture-partial-coverage" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(home)
        }
        guard item.id.hasPrefix("similar-capture-") else { return false }
        if item.kind == .advice { return isHiddenContext(item.url) || Keep.isProtected(item.url) }
        return item.kind == .deleteItem && isInsideVisibleRoot(item.url)
    }

    static func compareForQA(_ reference: URL, _ candidate: URL) -> (passes: Bool, distance: Float?) {
        guard let left = pixelFingerprint(reference),
              let right = pixelFingerprint(candidate),
              pixelShortlist(right, left) != nil else { return (false, nil) }
        guard let leftVision = visionFingerprint(reference),
              let rightVision = visionFingerprint(candidate),
              let distance = visionDistance(leftVision, rightVision) else { return (false, nil) }
        return (distance <= maximumVisionDistance, distance)
    }

    static func itemsForQA(roots: [URL]) -> [JunkItem] {
        scan(
            visibleRoots: roots,
            hiddenReferences: [],
            hiddenMedia: [],
            deadline: 15,
            honorProtection: false
        ).cards
    }

    private static func scan(
        visibleRoots: [URL],
        hiddenReferences: [URL],
        hiddenMedia: [URL],
        deadline: TimeInterval,
        honorProtection: Bool
    ) -> AuditSummary {
        let started = Date()
        var timedOut = false
        var raw: [(url: URL, hidden: Bool, forcedReference: Bool)] = []
        var seen = Set<String>()

        func append(_ url: URL, hidden: Bool, forcedReference: Bool) {
            let path = canonicalPath(url)
            guard seen.insert(path).inserted else {
                if forcedReference, let index = raw.firstIndex(where: { canonicalPath($0.url) == path }) {
                    raw[index].forcedReference = true
                }
                return
            }
            raw.append((url, hidden, forcedReference))
        }

        for url in visibleImageURLs(
            in: visibleRoots,
            deadline: started.addingTimeInterval(deadline),
            honorProtection: honorProtection
        ) {
            append(url, hidden: false, forcedReference: false)
        }
        for url in hiddenReferences { append(url, hidden: true, forcedReference: true) }
        for url in hiddenMedia.prefix(maximumHiddenCandidates) {
            append(url, hidden: true, forcedReference: false)
        }

        var candidates: [Candidate] = []
        var decoded = 0
        for item in raw {
            if Date().timeIntervalSince(started) >= deadline {
                timedOut = true
                break
            }
            guard let facts = FileStorageFacts.read(item.url),
                  !facts.isCloudPlaceholder,
                  facts.logicalBytes >= minimumBytes,
                  facts.logicalBytes <= maximumBytes,
                  let pixels = pixelFingerprint(item.url) else { continue }
            decoded += 1
            let values = try? item.url.resourceValues(forKeys: [.contentModificationDateKey])
            let reference = item.forcedReference || hasCaptureEvidence(item.url)
            candidates.append(Candidate(
                url: item.url,
                facts: facts,
                modified: values?.contentModificationDate ?? .distantPast,
                hidden: item.hidden,
                reference: reference,
                pixels: pixels
            ))
        }

        let references = candidates.filter(\.reference)
        guard !references.isEmpty else {
            CamLog.line("similar captures references=0 candidates=\(raw.count) decoded=\(decoded)")
            return AuditSummary(
                cards: [], references: 0, candidates: raw.count, decoded: decoded,
                shortlisted: 0, matches: 0, timedOut: timedOut
            )
        }

        var visionCache: [String: VNFeaturePrintObservation] = [:]
        func feature(_ candidate: Candidate) -> VNFeaturePrintObservation? {
            let key = canonicalPath(candidate.url)
            if let cached = visionCache[key] { return cached }
            guard let made = visionFingerprint(candidate.url) else { return nil }
            visionCache[key] = made
            return made
        }

        var matches: [Match] = []
        var shortlisted = 0
        for candidate in candidates where !candidate.reference {
            if Date().timeIntervalSince(started) >= deadline {
                timedOut = true
                break
            }
            var best: Match?
            for reference in references {
                guard candidate.facts.inodeKey != reference.facts.inodeKey,
                      let hashDistance = pixelShortlist(candidate.pixels, reference.pixels) else { continue }
                shortlisted += 1
                guard let candidateFeature = feature(candidate),
                      let referenceFeature = feature(reference),
                      let distance = visionDistance(candidateFeature, referenceFeature),
                      distance <= maximumVisionDistance else { continue }
                let match = Match(
                    candidate: candidate,
                    reference: reference,
                    distance: distance,
                    hashDistance: hashDistance
                )
                if best == nil
                    || distance < best!.distance
                    || (distance == best!.distance && hashDistance < best!.hashDistance) {
                    best = match
                }
            }
            if let best { matches.append(best) }
        }

        var cards = matches.map(card(for:))
            .sorted { lhs, rhs in
                if lhs.kind == .advice, rhs.kind != .advice { return false }
                if lhs.kind != .advice, rhs.kind == .advice { return true }
                return lhs.bytes > rhs.bytes
            }
        if cards.count > 140 { cards = Array(cards.prefix(140)) }
        if timedOut {
            cards.append(JunkItem(
                id: "similar-capture-partial-coverage",
                module: .duplicates,
                title: Line(
                    ru: "Похожие скриншоты · проход не завершён",
                    en: "Similar screenshots · partial pass"
                ),
                subtitle: Line(
                    ru: "Проверена только часть доступных изображений: достигнут лимит времени · ничего не удаляется автоматически",
                    en: "Only part of the accessible image set was checked: the time limit was reached · nothing is removed automatically"
                ),
                url: home,
                bytes: 0,
                selected: false,
                kind: .advice,
                keepsLogins: true
            ))
        }
        CamLog.line(
            "similar captures references=\(references.count) candidates=\(raw.count) "
                + "decoded=\(decoded) shortlisted=\(shortlisted) matches=\(matches.count) "
                + "timedOut=\(timedOut)"
        )
        ImageFingerprintCache.flush()
        return AuditSummary(
            cards: cards,
            references: references.count,
            candidates: raw.count,
            decoded: decoded,
            shortlisted: shortlisted,
            matches: matches.count,
            timedOut: timedOut
        )
    }

    private static func card(for match: Match) -> JunkItem {
        let candidate = match.candidate
        let shared = candidate.facts.isHardLinked
            || (candidate.facts.mayShareFileContent && candidate.facts.contentIdentifier != nil)
        let auditOnly = candidate.hidden || shared || Keep.isProtected(candidate.url)
        let kind: CleanKind = auditOnly ? .advice : .deleteItem
        let keep = PathFormat.tilde(match.reference.url)
        let visualCloseness = match.distance <= 0.12 ? "почти одинаково" : "очень похоже"
        let visualClosenessEN = match.distance <= 0.12 ? "near-identical" : "very similar"
        let detailRU = auditOnly
            ? "скрытая копия остаётся только в анализе"
            : "не выбрано: сравните обе картинки перед удалением"
        let detailEN = auditOnly
            ? "the hidden copy stays read-only"
            : "not selected: compare both images before removal"
        return JunkItem(
            id: "similar-capture-\(auditOnly ? "audit-" : "file-")\(stableKey(canonicalPath(candidate.url)))",
            module: .duplicates,
            title: Line(
                ru: "Похожая копия · \(candidate.url.lastPathComponent)",
                en: "Similar copy · \(candidate.url.lastPathComponent)"
            ),
            subtitle: Line(
                ru: "После переименования или пережатия выглядит \(visualCloseness) · сравнить с: \(keep) · \(detailRU)",
                en: "Looks \(visualClosenessEN) after renaming or recompression · compare with: \(keep) · \(detailEN)"
            ),
            url: candidate.url,
            bytes: candidate.facts.allocatedBytes,
            selected: false,
            kind: kind,
            keepsLogins: true
        )
    }

    private static func visibleImageURLs(
        in roots: [URL],
        deadline: Date,
        honorProtection: Bool
    ) -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var visited = 0
        for root in roots {
            guard Date() < deadline else { break }
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                visited += 1
                if visited > maximumVisibleEntries || Date() >= deadline { return result }
                if honorProtection, Keep.isProtected(url) {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "heic", "heif", "tiff", "tif", "gif", "webp", "avif", "jxl", "bmp"].contains(ext) {
                    result.append(url)
                }
            }
        }
        return result
    }

    private static func pixelFingerprint(_ url: URL) -> ImagePixelFingerprint? {
        ImageFingerprintCache.fingerprint(for: url) {
            makePixelFingerprint(url)
        }
    }

    private static func makePixelFingerprint(_ url: URL) -> ImagePixelFingerprint? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width >= 32, height >= 32 else { return nil }
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
        return ImagePixelFingerprint(
            aspect: Double(max(width, height)) / Double(min(width, height)),
            width: width,
            height: height,
            average: average,
            horizontal: horizontal,
            vertical: vertical
        )
    }

    private static func pixelShortlist(
        _ candidate: ImagePixelFingerprint,
        _ reference: ImagePixelFingerprint
    ) -> Int? {
        let relativeAspect = abs(candidate.aspect - reference.aspect)
            / max(candidate.aspect, reference.aspect)
        guard relativeAspect <= 0.008 else { return nil }
        let average = (candidate.average ^ reference.average).nonzeroBitCount
        let edges = (candidate.horizontal ^ reference.horizontal).nonzeroBitCount
            + (candidate.vertical ^ reference.vertical).nonzeroBitCount
        guard average <= 5, edges <= 10 else { return nil }
        return average * 2 + edges
    }

    private static func grayscalePixels(_ image: CGImage, width: Int, height: Int) -> [UInt8]? {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let made = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return made ? pixels : nil
    }

    private static func visionFingerprint(_ url: URL) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        let handler = VNImageRequestHandler(url: url, options: [:])
        do {
            try handler.perform([request])
            return request.results?.first
        } catch {
            return nil
        }
    }

    private static func visionDistance(
        _ lhs: VNFeaturePrintObservation,
        _ rhs: VNFeaturePrintObservation
    ) -> Float? {
        var distance: Float = 0
        do {
            try lhs.computeDistance(&distance, to: rhs)
            return distance.isFinite ? distance : nil
        } catch {
            return nil
        }
    }

    private static func hasCaptureEvidence(_ url: URL) -> Bool {
        let lower = url.lastPathComponent
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let markers = [
            "screenshot", "screen shot", "screen capture", "screen recording",
            "screenrecording", "screencapture", "снимок экрана", "запись экрана",
            "знімок екрана", "запис екрана", "cleanshot"
        ]
        if markers.contains(where: lower.contains) { return true }
        for name in ["com.apple.metadata:kMDItemIsScreenCapture", "com.apple.metadata:kMDItemImageIsScreenshot"] {
            let present = url.path.withCString { path in
                name.withCString { attribute in
                    getxattr(path, attribute, nil, 0, 0, 0) > 0
                }
            }
            if present { return true }
        }
        return false
    }

    private static func isInsideVisibleRoot(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].contains { name in
            let root = canonicalPath(home.appendingPathComponent(name))
            return path == root || path.hasPrefix(root + "/")
        }
    }

    private static func isHiddenContext(_ url: URL) -> Bool {
        ForensicRemnantScanner.isResidualContextForQA(url)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
