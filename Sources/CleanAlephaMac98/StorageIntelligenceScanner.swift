import CryptoKit
import Foundation

/// A content-driven pass over hidden user storage. Unlike the path catalog scanners,
/// this index does not need to know an app in advance: it rolls physical bytes up the
/// directory tree, recognizes cache-shaped trees, generated media, and exact duplicate
/// payloads. Destructive cards are restricted to semantically strong cache directories
/// and are fully re-inspected by Janitor immediately before cleanup.
enum StorageIntelligenceScanner {
    private struct Root {
        let url: URL
        let label: String
        let cleanupAllowed: Bool
        let entryBudget: Int

        init(url: URL, label: String, cleanupAllowed: Bool = true, entryBudget: Int = 120_000) {
            self.url = url
            self.label = label
            self.cleanupAllowed = cleanupAllowed
            self.entryBudget = entryBudget
        }
    }

    private struct DirectoryStats {
        var bytes: Int64 = 0
        var logicalBytes: Int64 = 0
        var files = 0
        var generatedMediaBytes: Int64 = 0
        var generatedMediaFiles = 0
        var ephemeralBytes: Int64 = 0
        var newest = Date.distantPast
        var containsSensitiveData = false
        var complete = true
    }

    private struct MediaFile {
        let url: URL
        let logicalBytes: Int64
        let allocatedBytes: Int64
        let mayShareFileContent: Bool
    }

    private struct Index {
        var directories: [String: DirectoryStats] = [:]
        var generatedMediaBySize: [Int64: [MediaFile]] = [:]
        var roots: [Root] = []
        var visited = 0
        var denied = 0
        var truncated = false
        var truncatedAt: String?
        var rootsStarted = 0
        var rootsFinished = 0
        var truncatedRoots = Set<String>()
        var generatedMediaCandidates = 0
    }

    private struct Limits {
        let maxEntries: Int
        let deadline: TimeInterval
        let tailEntriesPerRoot: Int
        let minimumEphemeralBytes: Int64
        let minimumHotspotBytes: Int64
        let minimumMediaBytes: Int64

        static let production = Limits(
            maxEntries: 550_000,
            deadline: 40,
            tailEntriesPerRoot: 768,
            minimumEphemeralBytes: 32 * 1_048_576,
            minimumHotspotBytes: 256 * 1_048_576,
            minimumMediaBytes: 64 * 1_048_576
        )
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var scanRoots: [Root] {
        var roots = [
            Root(url: home.appendingPathComponent("Library/Application Support"), label: "Application Support"),
            Root(url: home.appendingPathComponent(".claude"), label: "~/.claude"),
            Root(url: home.appendingPathComponent(".codex"), label: "~/.codex"),
            Root(url: home.appendingPathComponent(".cursor"), label: "~/.cursor"),
            Root(url: home.appendingPathComponent(".local/share"), label: "~/.local/share"),
            Root(url: home.appendingPathComponent("Library/Caches"), label: "Caches"),
            Root(url: home.appendingPathComponent("Library/Containers"), label: "Containers"),
            Root(url: home.appendingPathComponent("Library/Group Containers"), label: "Group Containers"),
            Root(url: home.appendingPathComponent("Library/WebKit"), label: "WebKit"),
            Root(url: home.appendingPathComponent("Library/Logs"), label: "Logs")
        ]
        roots.append(contentsOf: discoveredHiddenRoots(excluding: roots))
        roots.append(Root(url: home.appendingPathComponent(".cache"), label: "~/.cache"))
        return roots
    }

    /// Discover future tools without granting their unknown layouts deletion rights.
    /// Credential/config roots and large VM/build stores stay outside this content walk.
    private static func discoveredHiddenRoots(excluding fixed: [Root]) -> [Root] {
        let denied = Set([
            ".", "..", ".Trash", ".git", ".ssh", ".gnupg", ".aws", ".kube",
            ".config", ".docker", ".colima", ".gradle", ".cache"
        ])
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else { return [] }
        let fixedPaths = fixed.map { $0.url.standardizedFileURL.path }
        return children.compactMap { url -> Root? in
            let name = url.lastPathComponent
            guard name.hasPrefix("."), !denied.contains(name),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isDirectory == true, values.isSymbolicLink != true else { return nil }
            let path = url.standardizedFileURL.path
            let overlaps = fixedPaths.contains { fixedPath in
                path == fixedPath || path.hasPrefix(fixedPath + "/") || fixedPath.hasPrefix(path + "/")
            }
            guard !overlaps else { return nil }
            return Root(url: url, label: "~/\(name)", cleanupAllowed: false, entryBudget: 18_000)
        }.sorted { $0.label < $1.label }
    }

    /// Roots that are large real working sets rather than cleanup candidates. They are
    /// represented elsewhere in Space Lens and must not consume the bounded index budget.
    private static let traversalDenyFragments = [
        "/.colima/", "/Parallels/", "/.gradle/", "/CoreSimulator/",
        "/iOS DeviceSupport/", "/MobileSync/Backup/", "/Photos Library.photoslibrary/",
        "/Claude/vm_bundles/", "/Mobile Documents/com~apple~CloudDocs/"
    ]

    private static let ephemeralNames: Set<String> = [
        "cache", "caches", "code cache", "gpucache", "gpu cache",
        "shadercache", "shader cache", "grshadercache", "dawncache",
        "dawngraphitecache", "dawnwebgpucache", "cacheddata", "crx cache",
        "cachestorage", "cache storage", "scriptcache", "script cache",
        "logs", "log", "crashpad", "crashes", "crash reports",
        "temp", "tmp", "temporary", ".trash", "trash",
        "thumbnails", "thumbnail cache", "diagnostics"
    ]

    private static let sensitiveFragments = [
        "session", "auth", "account", "cookie", "login", "keychain",
        "credential", "identity", "wallet", "token", "secret",
        "local storage", "localstorage", "indexeddb", "webstorage",
        "service worker", "preferences", "settings", "tdata", "postbox"
    ]

    private static let sensitiveExactNames = Set(Keep.names.map(normalized))

    private static let generatedPathMarkers = [
        "screenshot", "screen shot", "screen recording", "capture",
        "generated", "generation", "output", "outputs", "artifact",
        "artifacts", "upload", "uploads", "attachment", "attachments",
        "tool result", "tool-results", "generated images", "visualization",
        "снимок экрана", "запись экрана"
    ]

    private static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "avif", "heic", "heif",
        "tif", "tiff", "bmp", "mov", "mp4", "m4v", "webm"
    ]

    static func items(
        now: Date = Date(),
        cancellation: ScanCancellation? = nil
    ) -> [JunkItem] {
        let started = Date()
        let index = buildIndex(
            roots: scanRoots,
            now: now,
            limits: .production,
            cancellation: cancellation
        )
        guard cancellation?.isCancelled != true else { return [] }
        var rows: [JunkItem] = []
        let ephemeral = ephemeralCards(from: index)
        rows.append(contentsOf: ephemeral)
        rows.append(contentsOf: duplicateCards(from: index))
        rows.append(contentsOf: mediaCards(from: index))
        rows.append(contentsOf: hotspotCards(from: index, excluding: Set(ephemeral.map { canonical($0.url) })))
        if let coverage = coverageCard(from: index) { rows.append(coverage) }
        CamLog.line(
            "intelligence scan entries=\(index.visited) dirs=\(index.directories.count) "
                + "denied=\(index.denied) truncated=\(index.truncated) at=\(index.truncatedAt ?? "none") "
                + "roots=\(index.rootsStarted)/\(index.roots.count) finished=\(index.rootsFinished) "
                + "rows=\(rows.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
        return dedupe(rows).sorted { lhs, rhs in
            if lhs.selected != rhs.selected { return lhs.selected && !rhs.selected }
            return lhs.bytes > rhs.bytes
        }
    }

    /// Structural permission for UI/Keep. Advice cards can point inside protected chat
    /// stores; only an exact, revalidated `intel-ephemeral-*` card is ever writable.
    static func isExplicitCard(_ item: JunkItem) -> Bool {
        let path = canonical(item.url)
        if item.id == "intel-coverage-partial" {
            return (item.module == .junk || item.module == .deepSearch) && item.kind == .advice && item.selected == false
                && path == canonical(home)
        }
        guard isBelowScanRoot(item.url), path != canonicalRoot(for: item.url) else { return false }
        if item.id == "intel-ephemeral-\(stableKey(path))" {
            return (item.module == .junk || item.module == .deepSearch) && item.kind == .wipeChildren && isBelowCleanupRoot(item.url)
        }
        let advicePrefixes = ["intel-hotspot-", "intel-media-", "intel-duplicate-"]
        return (item.module == .junk || item.module == .deepSearch)
            && item.kind == .advice
            && advicePrefixes.contains(where: { item.id.hasPrefix($0) })
    }

    static func isSafeDeletionCandidate(_ item: JunkItem) -> Bool {
        guard isExplicitCard(item), item.id.hasPrefix("intel-ephemeral-"),
              item.kind == .wipeChildren, !Keep.isExtraProtected(item.url),
              !Keep.isProtected(item.url), isStrongEphemeralName(item.url.lastPathComponent) else {
            return false
        }
        return inspectEphemeralTree(item.url, limit: 250_000)
    }

    /// A cache can still be written by a CLI, renderer, or helper that NSWorkspace
    /// cannot identify. A timeout is treated as busy, never as permission to wipe.
    static func blockingProcessName(for item: JunkItem) -> String? {
        guard isExplicitCard(item), item.id.hasPrefix("intel-ephemeral-") else { return nil }
        let ran = CamProcess.run(
            path: "/usr/sbin/lsof",
            arguments: ["+D", item.url.path, "-Fpc", "-nP"],
            timeout: 3
        )
        if ran.timedOut { return "active process" }
        var currentPID: String?
        for line in ran.out.split(whereSeparator: \.isNewline) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            if marker == "p" {
                currentPID = value
            } else if marker == "c", currentPID != String(getpid()) {
                let lower = value.lowercased()
                if lower != "lsof" && !lower.contains("cleanal") {
                    return value.isEmpty ? "active process" : value
                }
            }
        }
        return nil
    }

    // MARK: - One-pass index

    private static func buildIndex(
        roots: [Root],
        now: Date,
        limits: Limits,
        cancellation: ScanCancellation? = nil
    ) -> Index {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .fileResourceIdentifierKey,
            .fileContentIdentifierKey, .mayShareFileContentKey,
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]
        let started = Date()
        var index = Index()
        index.roots = roots.filter { fm.fileExists(atPath: $0.url.path) }
        var seenFileIDs = Set<String>()
        var seenContentIDs = Set<Int64>()
        var signatureProbes = 0
        var deadlineReached = false

        rootLoop: for root in index.roots {
            if cancellation?.isCancelled == true { break }
            index.rootsStarted += 1
            let rootPath = root.url.standardizedFileURL.path
            index.directories[rootPath] = DirectoryStats()
            var errors: [URL] = []
            var rootVisited = 0
            let rootBudget = deadlineReached
                ? min(root.entryBudget, limits.tailEntriesPerRoot)
                : root.entryBudget
            guard let enumerator = fm.enumerator(
                at: root.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { url, _ in
                    errors.append(url)
                    return true
                }
            ) else {
                index.denied += 1
                markIncomplete(root.url, within: root.url, index: &index)
                continue
            }

            var rootTruncated = false
            var globalStop = false
            for case let url as URL in enumerator {
                if cancellation?.isCancelled == true {
                    rootTruncated = true
                    globalStop = true
                    break
                }
                index.visited += 1
                rootVisited += 1
                if index.visited > limits.maxEntries {
                    index.truncated = true
                    if index.truncatedAt == nil { index.truncatedAt = root.label }
                    index.truncatedRoots.insert(root.label)
                    rootTruncated = true
                    globalStop = true
                    break
                }
                if !deadlineReached, index.visited % 512 == 0,
                   Date().timeIntervalSince(started) > limits.deadline {
                    // A large early tree must not hide every root that follows it.
                    // After the normal deadline, open each remaining tree with a small
                    // tail budget. Partial totals stay conservative and non-deletable.
                    deadlineReached = true
                    index.truncated = true
                    if index.truncatedAt == nil { index.truncatedAt = root.label }
                    index.truncatedRoots.insert(root.label)
                    rootTruncated = true
                    break
                }
                if rootVisited > rootBudget {
                    index.truncated = true
                    if index.truncatedAt == nil { index.truncatedAt = root.label }
                    index.truncatedRoots.insert(root.label)
                    rootTruncated = true
                    break
                }
                if index.visited % 2_000 == 0 { ScanThrottle.reliefIfNeeded() }
                if Keep.isExtraProtected(url) {
                    enumerator.skipDescendants()
                    continue
                }
                let path = url.standardizedFileURL.path
                if shouldSkipTraversal(path) {
                    enumerator.skipDescendants()
                    continue
                }
                guard let values = try? url.resourceValues(forKeys: keys) else {
                    errors.append(url)
                    continue
                }
                if values.isSymbolicLink == true {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
                if values.isDirectory == true {
                    if index.directories[path] == nil {
                        index.directories[path] = DirectoryStats()
                    }
                    continue
                }
                guard values.isRegularFile == true else { continue }

                if values.isUbiquitousItem == true,
                   values.ubiquitousItemDownloadingStatus != .current {
                    continue // never materialize an iCloud/File Provider placeholder
                }

                if let identifier = values.fileResourceIdentifier {
                    let key = String(reflecting: identifier)
                    if seenFileIDs.contains(key) { continue }
                    seenFileIDs.insert(key)
                }
                let logical = Int64(values.fileSize ?? 0)
                let rawAllocated = Int64(
                    values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
                )
                guard rawAllocated > 0 else { continue } // sparse zero blocks
                let mayShare = values.mayShareFileContent == true
                    && values.fileContentIdentifier != nil
                let allocated: Int64
                if mayShare, let contentID = values.fileContentIdentifier {
                    allocated = seenContentIDs.insert(contentID).inserted ? rawAllocated : 0
                } else {
                    allocated = rawAllocated
                }
                let modified = values.contentModificationDate ?? .distantPast
                let components = url.standardizedFileURL.pathComponents.map(normalized)
                let ephemeral = components.contains(where: ephemeralNames.contains)
                let sensitive = components.contains(where: isSensitiveName)
                let generated = components.contains { component in
                    generatedPathMarkers.contains { component.contains($0) }
                }
                var media = mediaExtensions.contains(url.pathExtension.lowercased())
                if !media, generated, logical >= 64 * 1024, signatureProbes < 6_000 {
                    signatureProbes += 1
                    media = hasMediaMagic(readPrefix(url, count: 24))
                }
                let oldGeneratedMedia = generated && media && now.timeIntervalSince(modified) >= 14 * 86_400

                for ancestor in lexicalAncestors(
                    path: url.deletingLastPathComponent().standardizedFileURL.path,
                    rootPath: rootPath
                ) {
                    var stats = index.directories[ancestor, default: DirectoryStats()]
                    stats.bytes += allocated
                    stats.logicalBytes += logical
                    stats.files += 1
                    stats.newest = max(stats.newest, modified)
                    if ephemeral { stats.ephemeralBytes += allocated }
                    if sensitive { stats.containsSensitiveData = true }
                    if oldGeneratedMedia {
                        stats.generatedMediaBytes += allocated
                        stats.generatedMediaFiles += 1
                    }
                    index.directories[ancestor] = stats
                }
                if oldGeneratedMedia, logical >= 512 * 1024,
                   index.generatedMediaCandidates < 24_000 {
                    index.generatedMediaBySize[logical, default: []].append(
                        MediaFile(
                            url: url,
                            logicalBytes: logical,
                            allocatedBytes: allocated,
                            mayShareFileContent: mayShare
                        )
                    )
                    index.generatedMediaCandidates += 1
                }
            }
            index.denied += errors.count
            for errorURL in errors { markIncomplete(errorURL, within: root.url, index: &index) }
            if rootTruncated {
                markIncomplete(root.url, within: root.url, index: &index)
                if globalStop { break rootLoop }
            } else {
                index.rootsFinished += 1
            }
        }
        return index
    }

    private static func markIncomplete(_ url: URL, within root: URL, index: inout Index) {
        for path in lexicalAncestors(
            path: url.standardizedFileURL.path,
            rootPath: root.standardizedFileURL.path
        ) {
            var stats = index.directories[path, default: DirectoryStats()]
            stats.complete = false
            index.directories[path] = stats
        }
    }

    // MARK: - Findings

    private static func coverageCard(from index: Index) -> JunkItem? {
        guard index.truncated || index.denied > 0 || index.rootsStarted < index.roots.count else {
            return nil
        }
        let allOpened = index.rootsStarted == index.roots.count
        let coverageRU = allOpened
            ? "открыта каждая из \(index.roots.count) веток"
            : "открыто \(index.rootsStarted) из \(index.roots.count) веток"
        let coverageEN = allOpened
            ? "all \(index.roots.count) roots opened"
            : "\(index.rootsStarted) of \(index.roots.count) roots opened"
        return JunkItem(
            id: "intel-coverage-partial",
            module: .junk,
            title: Line(ru: "Глубокий индекс · границы покрытия", en: "Deep index · coverage limits"),
            subtitle: Line(
                ru: "\(coverageRU) · полностью \(index.rootsFinished) · частично \(index.truncatedRoots.count) · запретов macOS: \(index.denied) · неполные данные не удаляются",
                en: "\(coverageEN) · \(index.rootsFinished) complete · \(index.truncatedRoots.count) partial · macOS denials: \(index.denied) · incomplete data is never deleted"
            ),
            url: home,
            bytes: 0,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    private static func ephemeralCards(from index: Index) -> [JunkItem] {
        let minimum = Limits.production.minimumEphemeralBytes
        let candidates = index.directories.compactMap { path, stats -> JunkItem? in
            let url = URL(fileURLWithPath: path)
            guard stats.complete, stats.bytes >= minimum, stats.files > 0,
                  stats.ephemeralBytes * 100 >= stats.bytes * 92,
                  !stats.containsSensitiveData, isStrongEphemeralName(url.lastPathComponent),
                  isBelowLexicalCleanupRoot(path, roots: index.roots),
                  !Keep.isProtected(url), !Keep.isExtraProtected(url) else {
                return nil
            }
            let owner = ownerLabel(for: url, roots: index.roots)
            return JunkItem(
                id: "intel-ephemeral-\(stableKey(path))",
                module: .junk,
                title: Line(ru: "Найденный кэш · \(owner)", en: "Discovered cache · \(owner)"),
                subtitle: Line(
                    ru: "Глубокий индекс · \(stats.files) файлов · без данных входа",
                    en: "Deep index · \(stats.files) files · no sign-in data"
                ),
                url: url,
                bytes: stats.bytes,
                selected: true,
                kind: .wipeChildren,
                keepsLogins: true
            )
        }
        return nonOverlapping(candidates.sorted { $0.bytes > $1.bytes }, limit: 28)
    }

    private static func hotspotCards(from index: Index, excluding: Set<String>) -> [JunkItem] {
        let minimum = Limits.production.minimumHotspotBytes
        let candidates = index.directories.compactMap { path, stats -> JunkItem? in
            let url = URL(fileURLWithPath: path)
            guard stats.bytes >= minimum, stats.files > 0, isBelowLexicalScanRoot(path),
                  lexicalRoot(for: path) != path, !isInsideAny(path, roots: excluding),
                  !isCoveredByDedicatedAudit(path),
                  isTerminalHotspot(path: path, bytes: stats.bytes, directories: index.directories) else {
                return nil
            }
            let owner = ownerLabel(for: url, roots: index.roots)
            let state = stats.complete ? "полный подсчёт" : "минимум, часть закрыта macOS"
            let enState = stats.complete ? "complete count" : "minimum; part denied by macOS"
            let protected = stats.containsSensitiveData || Keep.isProtected(url)
            return JunkItem(
                id: "intel-hotspot-\(stableKey(path))",
                module: .junk,
                title: Line(ru: "Скрытое хранилище · \(owner)", en: "Hidden storage · \(owner)"),
                subtitle: Line(
                    ru: "\(stats.files) файлов · \(state)\(protected ? " · защищено, только аудит" : " · только аудит")",
                    en: "\(stats.files) files · \(enState)\(protected ? " · protected, audit only" : " · audit only")"
                ),
                url: url,
                bytes: stats.bytes,
                selected: false,
                kind: .advice,
                keepsLogins: true
            )
        }
        return nonOverlapping(candidates.sorted { $0.bytes > $1.bytes }, limit: 18)
    }

    private static func mediaCards(from index: Index) -> [JunkItem] {
        let minimum = Limits.production.minimumMediaBytes
        let candidates = index.directories.compactMap { path, stats -> JunkItem? in
            let url = URL(fileURLWithPath: path)
            guard stats.generatedMediaBytes >= minimum, stats.generatedMediaFiles >= 3,
                  isBelowLexicalScanRoot(path), lexicalRoot(for: path) != path,
                  isTerminalMediaGroup(path: path, bytes: stats.generatedMediaBytes, directories: index.directories) else {
                return nil
            }
            return JunkItem(
                id: "intel-media-\(stableKey(path))",
                module: .junk,
                title: Line(ru: "Старые скрытые медиа-копии", en: "Old hidden media copies"),
                subtitle: Line(
                    ru: "\(stats.generatedMediaFiles) файлов · uploads/outputs/captures · только аудит",
                    en: "\(stats.generatedMediaFiles) files · uploads/outputs/captures · audit only"
                ),
                url: url,
                bytes: stats.generatedMediaBytes,
                selected: false,
                kind: .advice,
                keepsLogins: true
            )
        }
        return nonOverlapping(candidates.sorted { $0.bytes > $1.bytes }, limit: 16)
    }

    private static func duplicateCards(from index: Index) -> [JunkItem] {
        var rows: [JunkItem] = []
        var hashBudget: Int64 = 3 * 1_073_741_824
        let groups = index.generatedMediaBySize
            .filter { $0.value.count > 1 }
            .sorted { lhs, rhs in lhs.key * Int64(lhs.value.count - 1) > rhs.key * Int64(rhs.value.count - 1) }

        for (size, files) in groups {
            if rows.count >= 20 || hashBudget < size { break }
            var quickBuckets: [String: [MediaFile]] = [:]
            for file in files {
                quickBuckets[quickSignature(file.url, size: file.logicalBytes), default: []].append(file)
            }
            for quick in quickBuckets.values where quick.count > 1 {
                var exactBuckets: [String: [MediaFile]] = [:]
                for file in quick where hashBudget >= file.logicalBytes {
                    hashBudget -= file.logicalBytes
                    exactBuckets[fullSignature(file.url, size: file.logicalBytes), default: []].append(file)
                }
                for exact in exactBuckets.values where exact.count > 1 {
                    let sorted = exact.sorted { $0.url.path < $1.url.path }
                    let reclaimable = sorted.dropFirst().reduce(Int64(0)) {
                        $0 + ($1.mayShareFileContent ? 0 : $1.allocatedBytes)
                    }
                    guard reclaimable >= 8 * 1_048_576, let first = sorted.first else { continue }
                    let path = canonical(first.url)
                    rows.append(JunkItem(
                        id: "intel-duplicate-\(stableKey(path))",
                        module: .junk,
                        title: Line(ru: "Точные скрытые копии · \(sorted.count)", en: "Exact hidden copies · \(sorted.count)"),
                        subtitle: Line(
                            ru: "Одинаковое содержимое в outputs/uploads · оценка экономии · только аудит",
                            en: "Identical contents in outputs/uploads · estimated saving · audit only"
                        ),
                        url: first.url,
                        bytes: reclaimable,
                        selected: false,
                        kind: .advice,
                        keepsLogins: true
                    ))
                    if rows.count >= 20 { break }
                }
                if rows.count >= 20 { break }
            }
        }
        return rows.sorted { $0.bytes > $1.bytes }
    }

    // MARK: - Safety and classification

    private static func inspectEphemeralTree(_ url: URL, limit: Int) -> Bool {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var traversalFailed = false
        guard let root = try? url.resourceValues(forKeys: keys), root.isDirectory == true,
              root.isSymbolicLink != true, isStrongEphemeralName(url.lastPathComponent),
              !pathContainsSensitiveName(url), !Keep.isProtected(url), !Keep.isExtraProtected(url),
              let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: Array(keys),
                options: [],
                errorHandler: { _, _ in
                    traversalFailed = true
                    return false
                }
              ) else { return false }
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited > limit || Keep.isProtected(child) || Keep.isExtraProtected(child)
                || pathContainsSensitiveName(child) { return false }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isDirectory == true || values.isRegularFile == true else { return false }
        }
        return !traversalFailed
    }

    private static func isTerminalHotspot(
        path: String,
        bytes: Int64,
        directories: [String: DirectoryStats]
    ) -> Bool {
        !directories.contains { childPath, child in
            childPath != path
                && URL(fileURLWithPath: childPath).deletingLastPathComponent().path == path
                && child.bytes * 100 >= bytes * 45
        }
    }

    private static func isTerminalMediaGroup(
        path: String,
        bytes: Int64,
        directories: [String: DirectoryStats]
    ) -> Bool {
        !directories.contains { childPath, child in
            childPath != path
                && URL(fileURLWithPath: childPath).deletingLastPathComponent().path == path
                && child.generatedMediaBytes * 100 >= bytes * 55
        }
    }

    private static func isStrongEphemeralName(_ value: String) -> Bool {
        ephemeralNames.contains(normalized(value))
    }

    private static func isSensitiveName(_ value: String) -> Bool {
        sensitiveExactNames.contains(value) || sensitiveFragments.contains { value.contains($0) }
    }

    private static func isCoveredByDedicatedAudit(_ path: String) -> Bool {
        path.hasSuffix("/Library/Application Support/Cursor/User/globalStorage")
    }

    private static func pathContainsSensitiveName(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.map(normalized).contains(where: isSensitiveName)
    }

    private static func shouldSkipTraversal(_ path: String) -> Bool {
        let wrapped = path.hasSuffix("/") ? path : path + "/"
        return traversalDenyFragments.contains { wrapped.contains($0) }
    }

    private static func isBelowScanRoot(_ url: URL) -> Bool {
        let path = canonical(url)
        return scanRoots.contains { root in
            let rootPath = canonical(root.url)
            return path.hasPrefix(rootPath + "/")
        }
    }

    private static func isBelowCleanupRoot(_ url: URL) -> Bool {
        let path = canonical(url)
        return scanRoots.contains { root in
            guard root.cleanupAllowed else { return false }
            let rootPath = canonical(root.url)
            return path.hasPrefix(rootPath + "/")
        }
    }

    private static func isBelowLexicalScanRoot(_ path: String) -> Bool {
        scanRoots.contains { root in
            let rootPath = root.url.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/")
        }
    }

    private static func isBelowLexicalCleanupRoot(_ path: String, roots: [Root]) -> Bool {
        roots.contains { root in
            guard root.cleanupAllowed else { return false }
            let rootPath = root.url.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/")
        }
    }

    private static func canonicalRoot(for url: URL) -> String? {
        let path = canonical(url)
        return scanRoots
            .map { canonical($0.url) }
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }

    private static func lexicalRoot(for path: String) -> String? {
        scanRoots
            .map { $0.url.standardizedFileURL.path }
            .filter { path == $0 || path.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }

    private static func lexicalAncestors(path: String, rootPath: String) -> [String] {
        var current = URL(fileURLWithPath: path).standardizedFileURL
        var rows: [String] = []
        while true {
            let currentPath = current.path
            guard currentPath == rootPath || currentPath.hasPrefix(rootPath + "/") else { break }
            rows.append(currentPath)
            if currentPath == rootPath { break }
            let parent = current.deletingLastPathComponent()
            if parent.path == currentPath { break }
            current = parent
        }
        return rows
    }

    private static func nonOverlapping(_ rows: [JunkItem], limit: Int) -> [JunkItem] {
        var selected: [JunkItem] = []
        for row in rows {
            let path = canonical(row.url)
            let overlaps = selected.contains { other in
                let otherPath = canonical(other.url)
                return path == otherPath || path.hasPrefix(otherPath + "/") || otherPath.hasPrefix(path + "/")
            }
            if !overlaps { selected.append(row) }
            if selected.count >= limit { break }
        }
        return selected
    }

    private static func isInsideAny(_ path: String, roots: Set<String>) -> Bool {
        roots.contains { root in path == root || path.hasPrefix(root + "/") }
    }

    private static func dedupe(_ rows: [JunkItem]) -> [JunkItem] {
        var seen = Set<String>()
        return rows.filter { row in
            let key = "\(canonical(row.url))|\(row.kind)"
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func ownerLabel(for url: URL, roots: [Root]) -> String {
        let path = canonical(url)
        guard let root = roots
            .filter({ path.hasPrefix(canonical($0.url) + "/") })
            .max(by: { canonical($0.url).count < canonical($1.url).count }) else {
            return url.lastPathComponent
        }
        let relative = String(path.dropFirst(canonical(root.url).count + 1))
        let components = relative.split(separator: "/").map(String.init)
        if root.label == "Containers" || root.label == "Group Containers" {
            return components.first ?? root.label
        }
        if root.label == "Application Support" || root.label.hasPrefix("~/.") {
            return components.first ?? root.label
        }
        return components.first ?? root.label
    }

    private static func readPrefix(_ url: URL, count: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Data() }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: count)) ?? Data()
    }

    private static func hasMediaMagic(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        if bytes.count >= 8, bytes.prefix(8) == [137, 80, 78, 71, 13, 10, 26, 10] { return true }
        if bytes.count >= 3, bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff { return true }
        if bytes.count >= 6, String(bytes: bytes.prefix(6), encoding: .ascii)?.hasPrefix("GIF8") == true { return true }
        if bytes.count >= 12,
           String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
           String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP" { return true }
        if bytes.count >= 8 {
            let tiff = Array(bytes.prefix(4))
            if tiff == [0x49, 0x49, 0x2a, 0x00] || tiff == [0x4d, 0x4d, 0x00, 0x2a] { return true }
            if String(bytes: bytes[4..<8], encoding: .ascii) == "ftyp" { return true }
        }
        return false
    }

    private static func quickSignature(_ url: URL, size: Int64) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "unreadable:\(url.path)" }
        defer { try? handle.close() }
        var data = Data()
        let sample: UInt64 = 64 * 1024
        for offset in [UInt64(0), UInt64(max(0, size / 2 - Int64(sample / 2))), UInt64(max(0, size - Int64(sample)))] {
            do {
                try handle.seek(toOffset: offset)
                if let part = try handle.read(upToCount: Int(sample)) { data.append(part) }
            } catch {
                return "unreadable:\(url.path)"
            }
        }
        let digest = SHA256.hash(data: data)
        return "\(size):\(Data(digest).base64EncodedString())"
    }

    private static func fullSignature(_ url: URL, size: Int64) -> String {
        Scanner.contentSignature(url, size: size)
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - QA hooks

    static func isStrongEphemeralNameForQA(_ value: String) -> Bool {
        isStrongEphemeralName(value)
    }

    static func hasMediaMagicForQA(_ data: Data) -> Bool {
        hasMediaMagic(data)
    }

    static func quickSignatureForQA(_ url: URL, size: Int64) -> String {
        quickSignature(url, size: size)
    }

    static func ephemeralIDForQA(_ url: URL) -> String {
        "intel-ephemeral-\(stableKey(canonical(url)))"
    }

    static var coverageIDForQA: String { "intel-coverage-partial" }
}
