import CryptoKit
import Foundation

/// Detects whole directory trees that are provably identical.
///
/// The cheap pass groups folders by relative paths, directory markers, file sizes and
/// counts. Only shape-equivalent trees receive full-file SHA-256 reads. Every cleanup
/// request rebuilds both Merkle snapshots immediately before deletion, so a folder that
/// gained, lost, or changed a file after scanning is refused.
enum DuplicateFolderScanner {
    struct AuditSummary: Sendable {
        let cards: [JunkItem]
        let indexedFolders: Int
        let shapeGroups: Int
        let exactGroups: Int
        let hashedFiles: Int
        let timedOut: Bool
        let totalJobs: Int
        let completedJobs: Int
        let nextCursor: Int
    }

    private struct Leaf {
        let relativePath: String
        let url: URL
        let logicalBytes: Int64
    }

    private struct Builder {
        let url: URL
        let modified: Date
        var leaves: [Leaf] = []
        var directories: [String] = []
        var logicalBytes: Int64 = 0
        var invalid = false
    }

    private struct Candidate {
        let url: URL
        let modified: Date
        let leaves: [Leaf]
        let directories: [String]
        let logicalBytes: Int64
        let shapeDigest: String
    }

    private struct StorageSummary {
        let reclaimableBytes: Int64
        let sharedStorage: Bool
    }

    private struct Snapshot: Equatable {
        let shapeDigest: String
        let contentDigest: String
        let fileCount: Int
        let reclaimableBytes: Int64
        let sharedStorage: Bool
    }

    private struct Registration: Sendable {
        let duplicate: URL
        let keeper: URL
        let auditOnly: Bool
    }

    private struct ScanJob {
        let root: URL
        let rootPath: String
        let top: URL
        let topPath: String
        let modified: Date
    }

    private static let minimumFolderBytes: Int64 = 4 * 1_048_576
    private static let minimumFiles = 2
    private static let maximumFilesPerFolder = 8_000
    private static let maximumEntries = 400_000
    private static let maximumEntriesPerJob = 40_000
    private static let maximumSecondsPerJob: TimeInterval = 6
    private static let maximumCandidateDepth = 4
    private static let normalDeadline: TimeInterval = 38
    private static let registryLock = NSLock()
    private static let resumeLock = NSLock()
    private static let resumeSignatureKey = "duplicateFolders.resumeSignature.v3"
    private static let resumeCursorKey = "duplicateFolders.resumeCursor.v3"
    private static let prunedDirectoryNames: Set<String> = [
        ".git", ".svn", ".hg", ".build", ".gradle", ".dart_tool", ".venv",
        "node_modules", "deriveddata", "pods", "__pycache__", "venv", "build", "target"
    ]
    nonisolated(unsafe) private static var registry: [String: Registration] = [:]
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func items(in roots: [URL]) -> [JunkItem] {
        audit(roots: roots).cards
    }

    static func audit(roots: [URL]) -> AuditSummary {
        scan(roots: roots, deadline: normalDeadline, resumeEnabled: true)
    }

    static func itemsForQA(roots: [URL]) -> [JunkItem] {
        scan(
            roots: roots,
            deadline: 15,
            minimumBytes: 1,
            minimumFileCount: 1,
            resumeEnabled: false
        ).cards
    }

    static func auditForQA(
        roots: [URL],
        maximumJobEntries: Int = maximumEntriesPerJob
    ) -> AuditSummary {
        scan(
            roots: roots,
            deadline: 15,
            minimumBytes: 1,
            minimumFileCount: 1,
            resumeEnabled: false,
            jobEntryLimit: maximumJobEntries
        )
    }

    static func rotatedIndicesForQA(count: Int, cursor: Int) -> [Int] {
        rotatedIndices(count: count, cursor: cursor)
    }

    static func nextCursorForQA(
        count: Int,
        attempted: [Int],
        firstIncomplete: Int?
    ) -> Int {
        nextCursor(count: count, attempted: attempted, firstIncomplete: firstIncomplete)
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        registryLock.lock()
        let registration = registry[item.id]
        registryLock.unlock()
        guard let registration,
              item.module == .duplicates,
              item.selected == false,
              canonicalPath(item.url) == canonicalPath(registration.duplicate) else { return false }
        return registration.auditOnly ? item.kind == .advice : item.kind == .deleteItem
    }

    static func isSafeDeletionCandidate(_ item: JunkItem) -> Bool {
        registryLock.lock()
        let registration = registry[item.id]
        registryLock.unlock()
        guard let registration, !registration.auditOnly,
              item.kind == .deleteItem,
              canonicalPath(item.url) == canonicalPath(registration.duplicate),
              isInsideUserDocumentRoot(registration.duplicate),
              isInsideUserDocumentRoot(registration.keeper),
              !isSensitiveDatabasePath(registration.duplicate),
              !isSensitiveDatabasePath(registration.keeper),
              !Keep.isExtraProtected(registration.duplicate),
              !Keep.isExtraProtected(registration.keeper),
              let duplicate = strictSnapshot(of: registration.duplicate),
              let keeper = strictSnapshot(of: registration.keeper),
              duplicate.shapeDigest == keeper.shapeDigest,
              duplicate.contentDigest == keeper.contentDigest,
              duplicate.fileCount == keeper.fileCount,
              duplicate.reclaimableBytes > 0,
              !duplicate.sharedStorage else { return false }
        return true
    }

    private static func rotatedIndices(count: Int, cursor: Int) -> [Int] {
        guard count > 0 else { return [] }
        let start = min(max(0, cursor), count - 1)
        return (0..<count).map { (start + $0) % count }
    }

    private static func nextCursor(
        count: Int,
        attempted: [Int],
        firstIncomplete: Int?
    ) -> Int {
        guard count > 0 else { return 0 }
        if let firstIncomplete { return (firstIncomplete + 1) % count }
        if attempted.count < count, let last = attempted.last { return (last + 1) % count }
        return 0
    }

    private static func scan(
        roots: [URL],
        deadline: TimeInterval,
        minimumBytes: Int64 = minimumFolderBytes,
        minimumFileCount: Int = minimumFiles,
        resumeEnabled: Bool,
        jobEntryLimit: Int = maximumEntriesPerJob
    ) -> AuditSummary {
        let started = Date()
        let deadlineDate = started.addingTimeInterval(deadline)
        // Discovery must not consume the time needed to verify shortlisted trees.
        let verificationReserve = min(10, max(2, deadline * 0.25))
        let discoveryDeadline = deadlineDate.addingTimeInterval(-verificationReserve)
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .isVolumeKey, .contentModificationDateKey,
            .fileSizeKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey
        ]
        var builders: [String: Builder] = [:]
        var visited = 0
        var timedOut = false

        func candidateKeys(rootPath: String, components: [String], includeSelf: Bool) -> [String] {
            let parentCount = includeSelf ? components.count : max(0, components.count - 1)
            guard parentCount > 0 else { return [] }
            return (1...min(maximumCandidateDepth, parentCount)).map { depth in
                rootPath + "/" + components.prefix(depth).joined(separator: "/")
            }
        }

        func invalidateTop(_ top: String) {
            let affected = builders.keys.filter { $0 == top || $0.hasPrefix(top + "/") }
            for key in affected { builders[key]?.invalid = true }
        }

        // Each top-level directory is an independent job. A single enormous project can
        // no longer consume the entire scan budget and starve Pictures/Movies/Downloads.
        var jobs: [ScanJob] = []
        var rootListingDenied = false
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: []
            ) else {
                if fm.fileExists(atPath: rootPath) { rootListingDenied = true }
                continue
            }
            for top in children {
                guard let values = try? top.resourceValues(forKeys: keys),
                      values.isDirectory == true,
                      values.isSymbolicLink != true,
                      values.isPackage != true,
                      values.isVolume != true,
                      !prunedDirectoryNames.contains(top.lastPathComponent.lowercased()),
                      !isSensitiveDatabaseBoundary(top),
                      !Keep.isProtected(top),
                      !Keep.isExtraProtected(top) else { continue }
                jobs.append(ScanJob(
                    root: root,
                    rootPath: rootPath,
                    top: top,
                    topPath: top.standardizedFileURL.path,
                    modified: values.contentModificationDate ?? .distantPast
                ))
            }
        }
        jobs.sort {
            $0.topPath.localizedStandardCompare($1.topPath) == .orderedAscending
        }

        // The signature belongs to the selected scan scope, not the volatile job list.
        // Creating one new Downloads folder must not reset progress to the beginning.
        let jobSignature = stableKey(
            roots.map { $0.standardizedFileURL.path }.sorted().joined(separator: "\0")
        )
        let storedCursor: Int
        if resumeEnabled {
            resumeLock.lock()
            let defaults = UserDefaults.standard
            storedCursor = defaults.string(forKey: resumeSignatureKey) == jobSignature
                ? defaults.integer(forKey: resumeCursorKey)
                : 0
            resumeLock.unlock()
        } else {
            storedCursor = 0
        }
        let order = rotatedIndices(count: jobs.count, cursor: storedCursor)
        var attempted: [Int] = []
        var firstIncomplete: Int?
        var completedJobs = 0
        var stopAll = false

        for jobIndex in order {
            if stopAll || Date() >= discoveryDeadline || visited >= maximumEntries {
                timedOut = true
                break
            }
            let job = jobs[jobIndex]
            attempted.append(jobIndex)
            builders[job.topPath] = Builder(url: job.top, modified: job.modified)
            let jobDeadline = min(
                discoveryDeadline,
                Date().addingTimeInterval(maximumSecondsPerJob)
            )
            var jobVisited = 0
            var jobDenied = false
            var jobComplete = true
            guard let enumerator = fm.enumerator(
                at: job.top,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    jobDenied = true
                    return true
                }
            ) else {
                invalidateTop(job.topPath)
                if firstIncomplete == nil { firstIncomplete = jobIndex }
                timedOut = true
                continue
            }

            for case let url as URL in enumerator {
                visited += 1
                jobVisited += 1
                if visited > maximumEntries || Date() >= discoveryDeadline {
                    jobComplete = false
                    stopAll = true
                    break
                }
                if jobVisited > max(1, jobEntryLimit) || Date() >= jobDeadline {
                    jobComplete = false
                    break
                }
                let path = url.standardizedFileURL.path
                guard path.hasPrefix(job.topPath + "/") else {
                    enumerator.skipDescendants()
                    continue
                }
                let relative = String(path.dropFirst(job.rootPath.count + 1))
                let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
                guard !components.isEmpty else { continue }
                guard let values = try? url.resourceValues(forKeys: keys) else {
                    jobDenied = true
                    continue
                }

                let pruned = values.isDirectory == true
                    && prunedDirectoryNames.contains(url.lastPathComponent.lowercased())
                let sensitiveDatabase = values.isDirectory == true
                    && isSensitiveDatabaseBoundary(url)
                let unsafe = values.isSymbolicLink == true
                    || values.isPackage == true
                    || values.isVolume == true
                    || pruned
                    || sensitiveDatabase
                    || Keep.isExtraProtected(url)
                    || (values.isDirectory == true && Keep.isProtected(url))
                if unsafe {
                    for key in candidateKeys(rootPath: job.rootPath, components: components, includeSelf: false) {
                        if builders[key] != nil { builders[key]!.invalid = true }
                    }
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }

                if values.isDirectory == true {
                    let depth = components.count
                    if depth <= maximumCandidateDepth {
                        builders[path] = builders[path] ?? Builder(
                            url: url,
                            modified: values.contentModificationDate ?? .distantPast
                        )
                    }
                    for key in candidateKeys(rootPath: job.rootPath, components: components, includeSelf: false) {
                        guard var builder = builders[key] else { continue }
                        let base = key
                        let marker = String(path.dropFirst(min(path.count, base.count + 1)))
                            .precomposedStringWithCanonicalMapping
                        if !marker.isEmpty { builder.directories.append(marker) }
                        builders[key] = builder
                    }
                    continue
                }

                if url.lastPathComponent == ".DS_Store" { continue }
                let isCloudPlaceholder = values.isUbiquitousItem == true
                    && values.ubiquitousItemDownloadingStatus != .current
                guard values.isRegularFile == true,
                      !isCloudPlaceholder,
                      let logicalBytes = values.fileSize.map(Int64.init),
                      logicalBytes >= 0 else {
                    for key in candidateKeys(rootPath: job.rootPath, components: components, includeSelf: false) {
                        if builders[key] != nil { builders[key]!.invalid = true }
                    }
                    continue
                }
                for key in candidateKeys(rootPath: job.rootPath, components: components, includeSelf: false) {
                    guard var builder = builders[key] else { continue }
                    let base = key
                    let relativePath = String(path.dropFirst(min(path.count, base.count + 1)))
                        .precomposedStringWithCanonicalMapping
                    builder.leaves.append(Leaf(
                        relativePath: relativePath,
                        url: url,
                        logicalBytes: logicalBytes
                    ))
                    builder.logicalBytes += logicalBytes
                    builders[key] = builder
                }
            }
            if jobDenied || !jobComplete {
                invalidateTop(job.topPath)
                if firstIncomplete == nil { firstIncomplete = jobIndex }
                timedOut = true
            } else {
                completedJobs += 1
            }
        }

        if attempted.count < jobs.count || rootListingDenied { timedOut = true }
        let nextResumeCursor = nextCursor(
            count: jobs.count,
            attempted: attempted,
            firstIncomplete: firstIncomplete
        )
        let candidates = builders.values.compactMap { builder -> Candidate? in
            guard !builder.invalid,
                  builder.leaves.count >= minimumFileCount,
                  builder.leaves.count <= maximumFilesPerFolder,
                  builder.logicalBytes >= minimumBytes else { return nil }
            let digest = shapeDigest(
                leaves: builder.leaves,
                directories: builder.directories
            )
            return Candidate(
                url: builder.url,
                modified: builder.modified,
                leaves: builder.leaves,
                directories: builder.directories,
                logicalBytes: builder.logicalBytes,
                shapeDigest: digest
            )
        }

        let shapeBuckets = Dictionary(grouping: candidates) {
            "\($0.leaves.count):\($0.directories.count):\($0.logicalBytes):\($0.shapeDigest)"
        }.values.filter { $0.count > 1 }
        var hashedFiles = 0
        var exactBuckets: [[Candidate]] = []
        for bucket in shapeBuckets {
            if Date() >= deadlineDate { timedOut = true; break }
            var byContent: [String: [Candidate]] = [:]
            for candidate in bucket {
                guard let digest = contentDigest(
                    candidate.leaves,
                    hashedFiles: &hashedFiles,
                    deadline: deadlineDate
                ) else {
                    if Date() >= deadlineDate { timedOut = true }
                    continue
                }
                byContent[digest, default: []].append(candidate)
            }
            exactBuckets.append(contentsOf: byContent.values.filter { $0.count > 1 })
        }

        exactBuckets.sort { ($0.map(\.logicalBytes).max() ?? 0) > ($1.map(\.logicalBytes).max() ?? 0) }
        var cards: [JunkItem] = []
        var coveredRoots: [String] = []
        var registrations: [String: Registration] = [:]
        for group in exactBuckets {
            var sorted = group.compactMap { candidate -> (Candidate, StorageSummary)? in
                guard let storage = storageSummary(for: candidate, deadline: deadlineDate) else {
                    return nil
                }
                return (candidate, storage)
            }.sorted { keeperOrder($0.0, $1.0) }
            guard !sorted.isEmpty else { continue }
            let keeper = sorted.removeFirst()
            for (duplicate, storage) in sorted {
                let duplicatePath = canonicalPath(duplicate.url)
                if coveredRoots.contains(where: { duplicatePath.hasPrefix($0 + "/") }) { continue }
                let auditOnly = storage.sharedStorage
                let id = "dup-folder-\(auditOnly ? "shared-" : "")\(stableKey(duplicatePath))"
                let detailRU = auditOnly
                    ? "часть блоков общая с hard link/APFS-клоном · только аудит"
                    : "перед очисткой обе папки будут сравнены заново · ручной выбор"
                let detailEN = auditOnly
                    ? "some blocks are shared by a hard link/APFS clone · audit only"
                    : "both folders are compared again before cleanup · manual choice"
                cards.append(JunkItem(
                    id: id,
                    module: .duplicates,
                    title: Line(
                        ru: "Целая папка-дубликат · \(duplicate.url.lastPathComponent)",
                        en: "Whole duplicate folder · \(duplicate.url.lastPathComponent)"
                    ),
                    subtitle: Line(
                        ru: "100% одинаковое дерево: \(duplicate.leaves.count) файлов · оставить: \(PathFormat.tilde(keeper.0.url)) · \(detailRU)",
                        en: "100% identical tree: \(duplicate.leaves.count) files · keep: \(PathFormat.tilde(keeper.0.url)) · \(detailEN)"
                    ),
                    url: duplicate.url,
                    bytes: storage.reclaimableBytes,
                    selected: false,
                    kind: auditOnly ? .advice : .deleteItem,
                    keepsLogins: false
                ))
                registrations[id] = Registration(
                    duplicate: duplicate.url,
                    keeper: keeper.0.url,
                    auditOnly: auditOnly
                )
                if !auditOnly { coveredRoots.append(duplicatePath) }
            }
        }
        if timedOut {
            cards.append(JunkItem(
                id: "dup-folder-partial-coverage",
                module: .duplicates,
                title: Line(
                    ru: "Часть папок будет проверена в следующий проход",
                    en: "Some folders will be checked on the next pass"
                ),
                subtitle: Line(
                    ru: "Завершено верхних папок: \(completedJobs)/\(jobs.count) · проверено объектов: \(visited) · следующий проход начнётся с другой точки · незавершённые деревья отброшены",
                    en: "Top-level folders completed: \(completedJobs)/\(jobs.count) · entries checked: \(visited) · the next pass starts elsewhere · unfinished trees discarded"
                ),
                url: roots.first ?? home,
                bytes: 0,
                selected: false,
                kind: .advice,
                keepsLogins: true
            ))
        }
        registryLock.lock()
        registry = registrations
        registryLock.unlock()
        ContentFingerprinter.flush()
        // Commit progress only after results and their safety registry are complete. A
        // terminated scan retries the same region instead of silently skipping it.
        if resumeEnabled {
            resumeLock.lock()
            let defaults = UserDefaults.standard
            defaults.set(jobSignature, forKey: resumeSignatureKey)
            defaults.set(nextResumeCursor, forKey: resumeCursorKey)
            resumeLock.unlock()
        }
        CamLog.line(
            "duplicate folders visited=\(visited) indexed=\(builders.count) candidates=\(candidates.count) "
                + "shapeGroups=\(shapeBuckets.count) exactGroups=\(exactBuckets.count) "
                + "hashedFiles=\(hashedFiles) cards=\(cards.count) timedOut=\(timedOut) "
                + "jobs=\(completedJobs)/\(jobs.count) cursor=\(storedCursor)->\(nextResumeCursor)"
        )
        return AuditSummary(
            cards: cards.sorted { $0.bytes > $1.bytes },
            indexedFolders: builders.count,
            shapeGroups: shapeBuckets.count,
            exactGroups: exactBuckets.count,
            hashedFiles: hashedFiles,
            timedOut: timedOut,
            totalJobs: jobs.count,
            completedJobs: completedJobs,
            nextCursor: nextResumeCursor
        )
    }

    private static func strictSnapshot(of root: URL) -> Snapshot? {
        guard isInsideUserDocumentRoot(root),
              !isSensitiveDatabasePath(root),
              !isSensitiveDatabaseBoundary(root),
              !Keep.isProtected(root),
              !Keep.isExtraProtected(root) else {
            return nil
        }
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .isVolumeKey
        ]
        var denied = false
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys) + Array(FileStorageFacts.resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in
                denied = true
                return false
            }
        ) else { return nil }
        let rootPath = canonicalPath(root)
        var leaves: [Leaf] = []
        var directories: [String] = []
        var reclaimable: Int64 = 0
        var shared = false
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > maximumEntries { return nil }
            let path = canonicalPath(url)
            guard path.hasPrefix(rootPath + "/"),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true,
                  values.isPackage != true,
                  values.isVolume != true,
                  !(values.isDirectory == true && isSensitiveDatabaseBoundary(url)),
                  !Keep.isProtected(url),
                  !Keep.isExtraProtected(url) else { return nil }
            let relative = String(path.dropFirst(rootPath.count + 1))
                .precomposedStringWithCanonicalMapping
            if values.isDirectory == true {
                directories.append(relative)
                continue
            }
            guard values.isRegularFile == true else { return nil }
            if url.lastPathComponent == ".DS_Store" { continue }
            guard let facts = FileStorageFacts.read(url), !facts.isCloudPlaceholder else { return nil }
            leaves.append(Leaf(relativePath: relative, url: url, logicalBytes: facts.logicalBytes))
            if facts.isHardLinked || (facts.mayShareFileContent && facts.contentIdentifier != nil) {
                shared = true
            } else {
                reclaimable += facts.allocatedBytes
            }
        }
        guard !denied, !leaves.isEmpty else { return nil }
        var hashed = 0
        guard let content = contentDigest(leaves, hashedFiles: &hashed) else { return nil }
        return Snapshot(
            shapeDigest: shapeDigest(leaves: leaves, directories: directories),
            contentDigest: content,
            fileCount: leaves.count,
            reclaimableBytes: reclaimable,
            sharedStorage: shared
        )
    }

    private static func shapeDigest(leaves: [Leaf], directories: [String]) -> String {
        var digest = SHA256()
        for directory in directories.sorted() {
            digest.update(data: Data("D:\(directory)\0".utf8))
        }
        for leaf in leaves.sorted(by: { $0.relativePath < $1.relativePath }) {
            digest.update(data: Data("F:\(leaf.relativePath):\(leaf.logicalBytes)\0".utf8))
        }
        return Data(digest.finalize()).base64EncodedString()
    }

    private static func contentDigest(
        _ leaves: [Leaf],
        hashedFiles: inout Int,
        deadline: Date? = nil
    ) -> String? {
        var digest = SHA256()
        for leaf in leaves.sorted(by: { $0.relativePath < $1.relativePath }) {
            if let deadline, Date() >= deadline { return nil }
            guard let signature = ContentFingerprinter.fullSignature(
                leaf.url,
                expectedSize: leaf.logicalBytes
            ) else { return nil }
            hashedFiles += 1
            digest.update(data: Data("\(leaf.relativePath)\0\(signature)\0".utf8))
        }
        return Data(digest.finalize()).base64EncodedString()
    }

    /// Expensive APFS allocation/clone and cloud-placeholder metadata is read only after
    /// a folder's entire relative tree and sizes have matched another candidate.
    private static func storageSummary(
        for candidate: Candidate,
        deadline: Date? = nil
    ) -> StorageSummary? {
        var reclaimable: Int64 = 0
        var shared = false
        for leaf in candidate.leaves {
            if let deadline, Date() >= deadline { return nil }
            guard let facts = FileStorageFacts.read(leaf.url),
                  !facts.isCloudPlaceholder,
                  facts.logicalBytes == leaf.logicalBytes else { return nil }
            if facts.isHardLinked || (facts.mayShareFileContent && facts.contentIdentifier != nil) {
                shared = true
            } else {
                reclaimable += facts.allocatedBytes
            }
        }
        return StorageSummary(reclaimableBytes: reclaimable, sharedStorage: shared)
    }

    private static func keeperOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        func rank(_ url: URL) -> Int {
            let path = canonicalPath(url)
            if path.contains("/Documents/") { return 0 }
            if path.contains("/Pictures/") || path.contains("/Movies/") { return 1 }
            if path.contains("/Desktop/") { return 2 }
            if path.contains("/Downloads/") { return 4 }
            return 3
        }
        let left = rank(lhs.url)
        let right = rank(rhs.url)
        if left != right { return left < right }
        if lhs.url.pathComponents.count != rhs.url.pathComponents.count {
            return lhs.url.pathComponents.count < rhs.url.pathComponents.count
        }
        if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
    }

    private static func isInsideUserDocumentRoot(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        return ["Desktop", "Documents", "Downloads", "Pictures", "Movies"].contains { name in
            let root = canonicalPath(home.appendingPathComponent(name))
            return path.hasPrefix(root + "/")
        }
    }

    /// Byte-identical database pages from two instances are not disposable duplicates.
    /// The boundary is recognized both by conventional hidden data-directory names and
    /// by engine marker files, so renamed stores remain protected.
    private static func isSensitiveDatabaseBoundary(_ url: URL) -> Bool {
        if isSensitiveDatabasePath(url) { return true }
        let lower = url.lastPathComponent.lowercased()
        let markerWorthChecking = lower.hasPrefix(".")
            || lower.contains("data") || lower.contains("db")
            || lower.contains("postgres") || lower.contains("mongo")
            || lower.contains("mysql") || lower.contains("redis")
            || lower.contains("elastic")
        guard markerWorthChecking else { return false }
        let markers = [
            "PG_VERSION", "global/pg_control", "postmaster.opts",
            "WiredTiger", "WiredTiger.wt", "mongod.lock",
            "auto.cnf", "ibdata1", "ib_logfile0",
            "dump.rdb", "appendonly.aof", "nodes/0/_state"
        ]
        return markers.contains {
            FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    private static func isSensitiveDatabasePath(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { component in
            let lower = component.lowercased()
            if lower.hasPrefix(".pg") || lower.hasPrefix(".mongo")
                || lower.hasPrefix(".mysql") || lower.hasPrefix(".redis")
                || lower.hasPrefix(".elastic") { return true }
            return [
                "postgres", "postgresql", "postgres-data", "postgres_data",
                "mongodb", "mongo-data", "mongo_data", "mysql-data", "mysql_data",
                "redis-data", "redis_data", "elasticsearch-data", "elasticsearch_data"
            ].contains(lower)
        }
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
