import CryptoKit
import Darwin
import Foundation

/// Exhaustive read-only media pass for hidden storage. It does not trust extensions,
/// Spotlight, file names, or an application catalogue: `find` enumerates every accessible
/// regular file above 64 KiB and the scanner reads its binary header. The result is grouped
/// by the actual hidden owner tree and is never directly deletable.
enum DeepMediaForensicsScanner {
    private struct Root {
        let url: URL
        let timeout: TimeInterval
    }

    private struct Group {
        let url: URL
        var bytes: Int64 = 0
        var files = 0
        var images = 0
        var videos = 0
        var captureEvidence = 0
        var largest: Int64 = 0
    }

    private struct ScanResult {
        var groups: [String: Group] = [:]
        var enumerated = 0
        var candidates = 0
        var media = 0
        var denied = 0
        var timedOut = false
    }

    private struct Candidate: Sendable {
        let url: URL
        let path: String
        let allocated: Int64
    }

    private final class MediaAccumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Group] = [:]
        private var openedStorage = 0
        private var seenContentIdentifiers = Set<Int64>()

        func inspect(_ candidate: Candidate, cancellation: ScanCancellation?) {
            guard cancellation?.isCancelled != true else { return }
            guard let kind = mediaKind(at: candidate.path) else { return }
            let owner = ownerRoot(for: candidate.url)
            let key = canonicalPath(owner)
            let evidence = hasCaptureEvidence(candidate.url)
            let facts = FileStorageFacts.read(candidate.url)
            lock.lock()
            let effectiveAllocated: Int64
            if let facts, facts.mayShareFileContent,
               let contentID = facts.contentIdentifier {
                effectiveAllocated = seenContentIdentifiers.insert(contentID).inserted
                    ? candidate.allocated
                    : 0
            } else {
                effectiveAllocated = candidate.allocated
            }
            var group = storage[key] ?? Group(url: owner)
            group.bytes += effectiveAllocated
            group.files += 1
            group.largest = max(group.largest, effectiveAllocated)
            switch kind {
            case .image: group.images += 1
            case .video: group.videos += 1
            }
            if evidence { group.captureEvidence += 1 }
            storage[key] = group
            openedStorage += 1
            lock.unlock()
        }

        func snapshot() -> (groups: [String: Group], opened: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (storage, openedStorage)
        }
    }

    private enum MediaKind {
        case image
        case video
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func items(cancellation: ScanCancellation? = nil) -> [JunkItem] {
        let started = Date()
        let result = scan(cancellation: cancellation)
        guard cancellation?.isCancelled != true else { return [] }
        var rows = result.groups.values
            .filter { $0.bytes >= 4 * 1_048_576 || $0.largest >= 2 * 1_048_576 }
            .sorted { $0.bytes > $1.bytes }
            .prefix(36)
            .map { group in
                let stateRU = result.timedOut
                    ? "проход частичный: достигнут лимит времени"
                    : "доступная область пройдена полностью"
                let stateEN = result.timedOut
                    ? "partial pass: time limit reached"
                    : "accessible scope completed"
                return JunkItem(
                    id: "forensic-magic-media-\(stableKey(canonicalPath(group.url)))",
                    module: .junk,
                    title: Line(
                        ru: "Бинарный поиск · скрытые медиа",
                        en: "Binary scan · hidden media"
                    ),
                    subtitle: Line(
                        ru: "\(group.files) файлов: \(group.images) изображений, \(group.videos) видео · признаков capture/upload: \(group.captureEvidence) · физический объём без повторного счёта hard link/APFS clone · \(stateRU) · только аудит",
                        en: "\(group.files) files: \(group.images) images, \(group.videos) videos · capture/upload evidence: \(group.captureEvidence) · physical size without recounting hard links/APFS clones · \(stateEN) · audit only"
                    ),
                    url: group.url,
                    bytes: group.bytes,
                    selected: false,
                    kind: .advice,
                    keepsLogins: true
                )
            }
        if result.denied > 0 {
            rows.append(JunkItem(
                id: "forensic-magic-denied-coverage",
                module: .junk,
                title: Line(
                    ru: "Бинарный поиск · закрытые деревья",
                    en: "Binary scan · denied trees"
                ),
                subtitle: Line(
                    ru: "\(result.denied) переходов запрещены macOS · эти файлы не считаются проверенными или пустыми · нужен Полный доступ к диску · только аудит",
                    en: "macOS denied \(result.denied) traversals · those files are not treated as scanned or empty · Full Disk Access required · audit only"
                ),
                url: SystemDeepScanner.tempRootURL ?? home.appendingPathComponent("Library"),
                bytes: 0,
                selected: false,
                kind: .advice,
                keepsLogins: true
            ))
        }
        CamLog.line(
            "deep media enumerated=\(result.enumerated) candidates=\(result.candidates) media=\(result.media) "
                + "groups=\(result.groups.count) denied=\(result.denied) "
                + "timedOut=\(result.timedOut) rows=\(rows.count) "
                + "ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
        return rows
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        if item.id == "forensic-magic-denied-coverage" {
            return item.kind == .advice && item.selected == false
                && canonicalPath(item.url) == canonicalPath(
                    SystemDeepScanner.tempRootURL ?? home.appendingPathComponent("Library")
                )
        }
        return item.kind == .advice
            && item.selected == false
            && item.id == "forensic-magic-media-\(stableKey(canonicalPath(item.url)))"
            && isHiddenContext(item.url)
    }

    private static func scan(cancellation: ScanCancellation?) -> ScanResult {
        let started = Date()
        let deadline: TimeInterval = 105
        var result = ScanResult()
        var seenFileIDs = Set<String>()
        var candidates: [Candidate] = []
        for root in scanRoots() {
            guard cancellation?.isCancelled != true else { return result }
            let elapsed = Date().timeIntervalSince(started)
            guard elapsed < deadline else {
                result.timedOut = true
                break
            }
            guard FileManager.default.fileExists(atPath: root.url.path) else { continue }
            let ran = CamProcess.runData(
                path: "/usr/bin/find",
                arguments: [
                    "-x", root.url.path, "-type", "f",
                    "-size", "+65535c", "-print0"
                ],
                timeout: min(root.timeout, max(1, deadline - elapsed)),
                cancellation: cancellation
            )
            result.timedOut = result.timedOut || ran.timedOut
            let errorText = String(decoding: ran.err, as: UTF8.self)
            result.denied += errorText
                .split(whereSeparator: \.isNewline)
                .filter { $0.localizedCaseInsensitiveContains("operation not permitted")
                    || $0.localizedCaseInsensitiveContains("permission denied") }
                .count

            for rawPath in ran.out.split(separator: 0, omittingEmptySubsequences: true) {
                if cancellation?.isCancelled == true { return result }
                result.enumerated += 1
                if result.enumerated > 350_000 {
                    result.timedOut = true
                    return result
                }
                let path = String(decoding: rawPath, as: UTF8.self)
                let url = URL(fileURLWithPath: path)
                guard isHiddenContext(url) else { continue }
                var info = stat()
                let status = path.withCString { lstat($0, &info) }
                guard status == 0, (info.st_mode & S_IFMT) == S_IFREG else { continue }
                guard (info.st_flags & UInt32(SF_DATALESS)) == 0 else { continue }
                let fileID = "\(info.st_dev):\(info.st_ino)"
                guard !seenFileIDs.contains(fileID) else { continue }
                seenFileIDs.insert(fileID)
                let allocated = Int64(info.st_blocks) * 512
                guard allocated > 0 else { continue }
                result.candidates += 1
                candidates.append(Candidate(url: url, path: path, allocated: allocated))
            }
        }
        let accumulator = MediaAccumulator()
        let scanCandidates = candidates
        DispatchQueue.concurrentPerform(iterations: scanCandidates.count) { index in
            accumulator.inspect(scanCandidates[index], cancellation: cancellation)
        }
        let snapshot = accumulator.snapshot()
        result.groups = snapshot.groups
        result.media = snapshot.opened
        return result
    }

    private static func scanRoots() -> [Root] {
        var roots = [Root(url: home, timeout: 70)]
        if let temp = SystemDeepScanner.tempRootURL {
            roots.append(Root(url: temp.deletingLastPathComponent(), timeout: 25))
        }
        roots.append(Root(url: URL(fileURLWithPath: "/private/tmp"), timeout: 15))
        return roots
    }

    private static func mediaKind(at path: String) -> MediaKind? {
        var bytes = [UInt8](repeating: 0, count: 32)
        let fd = path.withCString { open($0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let count = read(fd, &bytes, bytes.count)
        guard count >= 3 else { return nil }
        let n = Int(count)

        if n >= 8, Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
            return .image
        }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .image }
        if n >= 6, String(bytes: bytes[0..<6], encoding: .ascii)?.hasPrefix("GIF8") == true {
            return .image
        }
        if n >= 4 {
            let prefix = Array(bytes[0..<4])
            if prefix == [0x49, 0x49, 0x2A, 0x00]
                || prefix == [0x4D, 0x4D, 0x00, 0x2A]
                || prefix == [0x42, 0x4D, bytes[2], bytes[3]]
                || prefix == [0x00, 0x00, 0x01, 0x00] {
                return .image
            }
        }
        if n >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" {
            return .image
        }
        if n >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
            let stillBrands = Set(["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"])
            return stillBrands.contains(brand) ? .image : .video
        }
        if n >= 4, Array(bytes[0..<4]) == [0x1A, 0x45, 0xDF, 0xA3] { return .video }
        if n >= 2, bytes[0] == 0xFF, bytes[1] == 0x0A { return .image } // JPEG XL codestream
        if n >= 12, Array(bytes[4..<12]) == [0x4A, 0x58, 0x4C, 0x20, 0x0D, 0x0A, 0x87, 0x0A] {
            return .image
        }
        return nil
    }

    private static func hasCaptureEvidence(_ url: URL) -> Bool {
        let lower = url.path
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let markers = [
            "screenshot", "screen shot", "screenrecord", "screen recording",
            "screencapture", "capture", "снимок экрана", "запись экрана",
            "/uploads/", "/pending-uploads/", "/outputs/", "/generated_images/",
            "/temporaryitems/", "/.trash/", "/.trashes/", "/autosave information/"
        ]
        if markers.contains(where: lower.contains) { return true }
        return url.path.withCString { path in
            "com.apple.metadata:kMDItemIsScreenCapture".withCString { name in
                getxattr(path, name, nil, 0, 0, 0) > 0
            }
        }
    }

    private static func ownerRoot(for url: URL) -> URL {
        let path = canonicalPath(url)
        let homePath = canonicalPath(home)
        if path.hasPrefix(homePath + "/") {
            let relative = String(path.dropFirst(homePath.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            guard let first = components.first else { return home }
            if first == "Library" {
                guard components.count >= 2 else { return home.appendingPathComponent("Library") }
                let second = components[1]
                let ownerDepthNames = Set([
                    "Application Support", "Caches", "Containers", "Group Containers",
                    "CloudStorage", "Mobile Documents", "WebKit"
                ])
                let depth = ownerDepthNames.contains(second) ? min(3, components.count) : min(2, components.count)
                return components.prefix(depth).reduce(home) { $0.appendingPathComponent($1) }
            }
            if first.hasPrefix(".") {
                let depth = [".cache", ".local"].contains(first) ? min(3, components.count) : 1
                return components.prefix(depth).reduce(home) { $0.appendingPathComponent($1) }
            }
            if let hiddenIndex = components.firstIndex(where: { $0.hasPrefix(".") }) {
                return components.prefix(hiddenIndex + 1).reduce(home) { $0.appendingPathComponent($1) }
            }
        }
        if path.hasPrefix("/private/var/folders/") {
            let components = url.standardizedFileURL.pathComponents
            let pivot = components.firstIndex(where: { $0 == "T" || $0 == "C" })
            let depth = min((pivot ?? max(0, components.count - 2)) + 2, components.count - 1)
            return URL(fileURLWithPath: "/").appendingPathComponent(
                components.dropFirst().prefix(depth).joined(separator: "/")
            )
        }
        if path.hasPrefix("/private/tmp/") {
            let relative = String(path.dropFirst("/private/tmp/".count))
            let first = relative.split(separator: "/").first.map(String.init) ?? ""
            return URL(fileURLWithPath: "/private/tmp").appendingPathComponent(first)
        }
        return url.deletingLastPathComponent()
    }

    private static func isHiddenContext(_ url: URL) -> Bool {
        ForensicRemnantScanner.isResidualContextForQA(url)
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - QA

    static func mediaKindForQA(_ data: Data) -> String? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3 else { return nil }
        if bytes.count >= 8,
           Array(bytes[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] { return "image" }
        if bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return "image" }
        if bytes.count >= 12, String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return "media" }
        if bytes.count >= 4, Array(bytes[0..<4]) == [0x1A, 0x45, 0xDF, 0xA3] { return "video" }
        return nil
    }
}
