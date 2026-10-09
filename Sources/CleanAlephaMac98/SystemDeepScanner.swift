import CryptoKit
import Darwin
import Foundation

/// A deliberately narrow bridge into macOS' private per-user runtime storage.
///
/// We never enumerate another user's `/private/var/folders` tree. The only writable
/// targets come from `confstr`, are immediate children of this user's C/T roots, and
/// must pass the same age/special-file inspection again immediately before deletion.
enum SystemDeepScanner {
    enum RuntimeArea: String, Sendable, CaseIterable {
        case cache
        case temporary
        case sharedTemporary

        var idPrefix: String {
            switch self {
            case .cache: "darwin-cache-"
            case .temporary: "darwin-temp-"
            case .sharedTemporary: "private-tmp-"
            }
        }

        var minimumAgeDays: Int {
            switch self {
            case .cache: 14
            case .temporary: 7
            case .sharedTemporary: 1
            }
        }

        var root: URL? {
            switch self {
            case .cache: confstrURL(_CS_DARWIN_USER_CACHE_DIR)
            case .temporary: confstrURL(_CS_DARWIN_USER_TEMP_DIR)
            case .sharedTemporary: URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            }
        }
    }

    private struct TreeInspection {
        var newest: Date
        var unsafe: Bool
        var complete: Bool

        func eligible(area: RuntimeArea, now: Date) -> Bool {
            complete && !unsafe
                && newest <= now.addingTimeInterval(-Double(area.minimumAgeDays) * 86_400)
        }
    }

    private struct RuntimeCandidate {
        let area: RuntimeArea
        let url: URL
        let bytes: Int64
        let newest: Date
    }

    private static let minimumBytes: Int64 = 2_097_152
    private static let maximumWalkEntries = 25_000
    private static let unsafeNameFragments = [
        "cookie", "session", "login", "auth", "keychain", "credential",
        "account", "singleton", "socket", "token", "cloudkit", "fileprovider"
    ]

    static var cacheRootURL: URL? { RuntimeArea.cache.root }
    static var tempRootURL: URL? { RuntimeArea.temporary.root }
    static var sharedTempRootURL: URL? { RuntimeArea.sharedTemporary.root }

    static func items(
        now: Date = Date(),
        cancellation: ScanCancellation? = nil
    ) -> [JunkItem] {
        var rows: [JunkItem] = []
        for area in RuntimeArea.allCases {
            guard cancellation?.isCancelled != true else { return [] }
            guard let root = area.root else { continue }
            let scanned = runtimeItems(
                area: area,
                root: root,
                now: now,
                cancellation: cancellation
            )
            rows.append(contentsOf: scanned.cards)
            if scanned.remainder >= minimumBytes {
                rows.append(runtimeRemainderCard(area: area, root: root, bytes: scanned.remainder))
            }
        }
        guard cancellation?.isCancelled != true else { return [] }
        rows.append(contentsOf: systemAuditItems(cancellation: cancellation))
        return rows.sorted { $0.bytes > $1.bytes }
    }

    /// Structural permission used by Keep/UI. It does not mean the tree is still old.
    static func isExplicitRuntimeCard(_ item: JunkItem) -> Bool {
        guard item.kind == .deleteItem,
              let area = area(forID: item.id),
              let root = area.root,
              !isMountPoint(item.url) else { return false }
        if area == .sharedTemporary {
            return isAllowedSharedTempTarget(item.url, root: root)
        }
        return isImmediateChild(item.url, of: root)
    }

    /// Destructive permission used by Janitor. Re-check all invariants at clean time.
    static func isSafeDeletionCandidate(_ item: JunkItem, now: Date = Date()) -> Bool {
        guard isExplicitRuntimeCard(item),
              let area = area(forID: item.id),
              !Keep.isExtraProtected(item.url),
              let inspection = inspectTree(
                item.url,
                requiredUID: area == .sharedTemporary ? getuid() : nil
              ) else { return false }
        return inspection.eligible(area: area, now: now)
    }

    static func isSystemAuditCard(_ item: JunkItem) -> Bool {
        guard item.kind == .advice, item.id.hasPrefix("system-audit-") else { return false }
        let path = canonicalPath(item.url)
        if item.id == "system-audit-storage-ledger" {
            return path == canonicalPath(URL(fileURLWithPath: "/System/Volumes/Data"))
        }
        return auditRoots.contains { canonicalPath($0.url) == path }
            || RuntimeArea.allCases.contains { area in
                area.root.map { canonicalPath($0) == path } ?? false
            }
    }

    /// Bundle-ish token for SessionGuard's generic running-app check.
    static func runtimeOwnerToken(for url: URL) -> String? {
        for area in RuntimeArea.allCases {
            guard let root = area.root, isDescendant(url, of: root) else { continue }
            let rootComponents = root.pathComponents
            let components = URL(fileURLWithPath: canonicalPath(url)).pathComponents
            guard components.count > rootComponents.count else { return nil }
            return components[rootComponents.count]
        }
        return nil
    }

    static func isOldSafeTreeForQA(_ url: URL, area: RuntimeArea, now: Date) -> Bool {
        inspectTree(url, requiredUID: area == .sharedTemporary ? getuid() : nil)?
            .eligible(area: area, now: now) == true
    }

    /// NSWorkspace sees GUI owners; lsof catches CLI helpers, renderers, and agents.
    /// This only runs for an explicitly selected deep card, never during normal scan.
    static func blockingProcessName(for item: JunkItem) -> String? {
        guard isExplicitRuntimeCard(item) else { return nil }
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
                continue
            }
            if marker == "c", currentPID != String(getpid()) {
                let lower = value.lowercased()
                if lower != "lsof" && !lower.contains("cleanal") {
                    return value.isEmpty ? "active process" : value
                }
            }
        }
        return nil
    }

    private static func runtimeItems(
        area: RuntimeArea,
        root: URL,
        now: Date,
        cancellation: ScanCancellation? = nil
    ) -> (cards: [JunkItem], remainder: Int64) {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: []
        ) else { return ([], bestEffortBytes(root)) }

        let eligibleNames = children.filter { child in
            let name = child.lastPathComponent
            guard !name.isEmpty,
                  !name.hasPrefix("."),
                  !name.lowercased().hasPrefix("com.apple."),
                  name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
            if area == .sharedTemporary, !ownedByCurrentUser(child) { return false }
            return true
        }
        let candidateURLs = expandedCandidates(eligibleNames, area: area)
        let sizes = rawBatchBytes(candidateURLs, timeout: 8, cancellation: cancellation)
        var candidates: [RuntimeCandidate] = []
        var n = 0
        for child in candidateURLs {
            if cancellation?.isCancelled == true { return ([], 0) }
            ScanThrottle.tickSync(every: 30, counter: &n)
            if area == .temporary {
                let lower = child.lastPathComponent.lowercased()
                if lower == "temporaryitems"
                    || lower.contains("screencapture")
                    || HiddenCaptureScanner.isKnownDarwinCapture(child) { continue }
            }
            let bytes = sizes[canonicalPath(child)] ?? 0
            guard bytes >= minimumBytes,
                  let inspection = inspectTree(
                    child,
                    requiredUID: area == .sharedTemporary ? getuid() : nil
                  ),
                  inspection.eligible(area: area, now: now) else { continue }
            candidates.append(RuntimeCandidate(
                area: area,
                url: child,
                bytes: bytes,
                newest: inspection.newest
            ))
        }

        let cards = candidates.map { candidateCard($0, now: now) }
        let offered = candidates.reduce(Int64(0)) { $0 + $1.bytes }
        let hiddenCaptures = area == .temporary
            ? HiddenCaptureScanner.bytesInsideDarwinTemp(root, now: now)
            : 0
        let total: Int64
        if area == .sharedTemporary {
            total = rawBatchBytes(
                eligibleNames,
                timeout: 8,
                cancellation: cancellation
            ).values.reduce(0, +)
        } else {
            total = bestEffortBytes(root)
        }
        return (cards, max(0, total - offered - hiddenCaptures))
    }

    /// `/private/tmp/claude-UID` is a live multiplexer. Offer old UUID sessions below it,
    /// never the broad owner root whose newest file could hide large stale siblings.
    private static func expandedCandidates(_ urls: [URL], area: RuntimeArea) -> [URL] {
        guard area == .sharedTemporary else { return urls }
        let claudeName = "claude-\(getuid())"
        var result: [URL] = []
        for url in urls {
            guard url.lastPathComponent == claudeName else {
                result.append(url)
                continue
            }
            let projects = safeDirectoryChildren(url)
            for project in projects {
                for session in safeDirectoryChildren(project)
                    where looksLikeUUID(session.lastPathComponent) {
                    result.append(session)
                }
            }
        }
        return result
    }

    private static func safeDirectoryChildren(_ root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ))?.filter { url in
            guard ownedByCurrentUser(url),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        } ?? []
    }

    private static func candidateCard(_ candidate: RuntimeCandidate, now: Date) -> JunkItem {
        let age = max(0, Int(now.timeIntervalSince(candidate.newest) / 86_400))
        let name = candidate.url.lastPathComponent
        let kindRU: String
        let kindEN: String
        switch candidate.area {
        case .cache:
            kindRU = "Системный cache"
            kindEN = "System cache"
        case .temporary:
            kindRU = "Системные временные данные"
            kindEN = "System temporary data"
        case .sharedTemporary:
            kindRU = "Скрытый /private/tmp"
            kindEN = "Hidden /private/tmp"
        }
        return JunkItem(
            id: candidate.area.idPrefix + stableKey(candidate.url),
            module: .junk,
            title: Line(ru: "\(kindRU) · \(name)", en: "\(kindEN) · \(name)"),
            subtitle: Line(
                ru: "Глубокий каталог текущего пользователя · без изменений \(age) дн. · вручную",
                en: "Deep current-user folder · unchanged for \(age) days · manual"
            ),
            url: candidate.url,
            bytes: candidate.bytes,
            selected: false,
            kind: .deleteItem,
            keepsLogins: true
        )
    }

    private static func runtimeRemainderCard(area: RuntimeArea, root: URL, bytes: Int64) -> JunkItem {
        let title: Line
        switch area {
        case .cache:
            title = Line(ru: "Активный системный cache", en: "Active system cache")
        case .temporary:
            title = Line(ru: "Активные временные данные", en: "Active temporary data")
        case .sharedTemporary:
            title = Line(
                ru: "Активный /private/tmp текущего пользователя",
                en: "Active current-user /private/tmp"
            )
        }
        return JunkItem(
            id: "system-audit-darwin-\(area.rawValue)",
            module: .junk,
            title: title,
            subtitle: Line(
                ru: "Только анализ: свежие, активные или защищённые объекты macOS",
                en: "Read-only: recent, active, or protected macOS objects"
            ),
            url: root,
            bytes: bytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    private static let auditRoots: [(id: String, title: Line, subtitle: Line, url: URL)] = [
        (
            "system-audit-library-caches",
            Line(ru: "Общие кэши приложений", en: "Shared application caches"),
            Line(ru: "Только анализ: /Library/Caches, очисткой управляют приложения и macOS", en: "Read-only: /Library/Caches, managed by apps and macOS"),
            URL(fileURLWithPath: "/Library/Caches")
        ),
        (
            "system-audit-library-logs",
            Line(ru: "Общие логи приложений", en: "Shared application logs"),
            Line(ru: "Только анализ: /Library/Logs, для очистки нужны отдельные правила", en: "Read-only: /Library/Logs needs app-specific rules"),
            URL(fileURLWithPath: "/Library/Logs")
        ),
        (
            "system-audit-var-log",
            Line(ru: "Системные логи macOS", en: "macOS system logs"),
            Line(ru: "Только анализ: /private/var/log, ротацией управляет macOS", en: "Read-only: /private/var/log, rotated by macOS"),
            URL(fileURLWithPath: "/private/var/log")
        ),
        (
            "system-audit-diagnostics",
            Line(ru: "Системная диагностика", en: "System diagnostics"),
            Line(ru: "Только анализ: диагностические архивы macOS", en: "Read-only: macOS diagnostic archives"),
            URL(fileURLWithPath: "/private/var/db/diagnostics")
        ),
        (
            "system-audit-powerlog",
            Line(ru: "История энергопотребления macOS", en: "macOS power history"),
            Line(ru: "Только анализ: системные powerlog-базы; ротацией управляет macOS", en: "Read-only: system powerlog databases; macOS manages rotation"),
            URL(fileURLWithPath: "/private/var/db/powerlog")
        ),
        (
            "system-audit-uuidtext",
            Line(ru: "Символы системных логов", en: "System log symbols"),
            Line(ru: "Только анализ: служебная база unified logging", en: "Read-only: unified logging support database"),
            URL(fileURLWithPath: "/private/var/db/uuidtext")
        ),
        (
            "system-audit-var-vm",
            Line(ru: "Sleep image macOS", en: "macOS sleep image"),
            Line(ru: "Только анализ: образ гибернации; macOS пересоздаёт и освобождает его сама", en: "Read-only: hibernation image; macOS recreates and releases it automatically"),
            URL(fileURLWithPath: "/private/var/vm")
        ),
        (
            "system-audit-swap-volume",
            Line(ru: "Физические swap-файлы macOS", en: "macOS physical swap files"),
            Line(ru: "Только анализ: активная виртуальная память; ручное удаление запрещено", en: "Read-only: active virtual memory; manual deletion is prohibited"),
            URL(fileURLWithPath: "/System/Volumes/VM")
        )
    ]

    private static func systemAuditItems(
        cancellation: ScanCancellation? = nil
    ) -> [JunkItem] {
        guard cancellation?.isCancelled != true else { return [] }
        let snapshot = apfsSnapshotSummary()
        var rows = auditRoots.compactMap { entry -> JunkItem? in
            guard cancellation?.isCancelled != true else { return nil }
            let bytes = bestEffortBytes(entry.url)
            guard bytes >= minimumBytes else { return nil }
            var subtitle = entry.subtitle
            if entry.id == "system-audit-swap-volume", let snapshot {
                subtitle = Line(
                    ru: "\(subtitle.ru) · APFS-снимков: \(snapshot.total), удаляемых: \(snapshot.purgeable)",
                    en: "\(subtitle.en) · APFS snapshots: \(snapshot.total), purgeable: \(snapshot.purgeable)"
                )
            }
            return JunkItem(
                id: entry.id,
                module: .junk,
                title: entry.title,
                subtitle: subtitle,
                url: entry.url,
                bytes: bytes,
                selected: false,
                kind: .advice,
                keepsLogins: false
            )
        }
        if let ledger = storageLedgerCard(snapshot: snapshot) {
            rows.append(ledger)
        }
        return rows
    }

    /// Separate immediately free bytes from capacity macOS can reclaim on demand.
    /// This prevents APFS snapshots/purgeable storage from being misreported as an
    /// ordinary hidden folder or added to the app's cleanup promise.
    private static func storageLedgerCard(
        snapshot: (total: Int, purgeable: Int)?
    ) -> JunkItem? {
        let volume = URL(fileURLWithPath: "/System/Volumes/Data", isDirectory: true)
        let keys: Set<URLResourceKey> = [
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? volume.resourceValues(forKeys: keys) else { return nil }
        let immediatelyFree = Int64(max(0, values.volumeAvailableCapacity ?? 0))
        let availableForImportant = max(
            immediatelyFree,
            values.volumeAvailableCapacityForImportantUsage ?? immediatelyFree
        )
        let systemReserve = max(0, availableForImportant - immediatelyFree)
        let revisions = URL(fileURLWithPath: "/System/Volumes/Data/.DocumentRevisions-V100")
        let hasDocumentVersions = FileManager.default.fileExists(atPath: revisions.path)
        guard systemReserve > 0 || snapshot != nil || hasDocumentVersions else { return nil }

        let snapshotsRU: String
        let snapshotsEN: String
        if let snapshot {
            snapshotsRU = "APFS-снимков: \(snapshot.total), помечено удаляемыми: \(snapshot.purgeable)"
            snapshotsEN = "APFS snapshots: \(snapshot.total), marked purgeable: \(snapshot.purgeable)"
        } else {
            snapshotsRU = "список APFS-снимков недоступен"
            snapshotsEN = "APFS snapshot list unavailable"
        }
        let revisionsRU = hasDocumentVersions
            ? " · версии документов защищены macOS"
            : ""
        let revisionsEN = hasDocumentVersions
            ? " · document versions are protected by macOS"
            : ""
        return JunkItem(
            id: "system-audit-storage-ledger",
            module: .junk,
            title: Line(
                ru: "Системно удерживаемое место macOS",
                en: "Space managed by macOS"
            ),
            subtitle: Line(
                ru: "Свободно сейчас: \(ByteFormat.string(immediatelyFree, .ru)) · резерв по оценке macOS: \(ByteFormat.string(systemReserve, .ru)) · \(snapshotsRU)\(revisionsRU) · только анализ",
                en: "Free now: \(ByteFormat.string(immediatelyFree, .en)) · macOS reclaimable estimate: \(ByteFormat.string(systemReserve, .en)) · \(snapshotsEN)\(revisionsEN) · read-only"
            ),
            url: volume,
            bytes: systemReserve,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    private static func inspectTree(_ url: URL, requiredUID: uid_t? = nil) -> TreeInspection? {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .isDirectoryKey, .isRegularFileKey,
            .isSymbolicLinkKey, .fileResourceTypeKey
        ]
        guard let rootValues = try? url.resourceValues(forKeys: keys),
              rootValues.isSymbolicLink != true,
              rootValues.isDirectory == true || rootValues.isRegularFile == true,
              !isMountPoint(url) else { return nil }
        if let requiredUID, !isOwned(url, by: requiredUID) { return nil }
        if hasUnsafeName(url.lastPathComponent) { return nil }

        var inspection = TreeInspection(
            newest: rootValues.contentModificationDate ?? .distantPast,
            unsafe: false,
            complete: true
        )
        let inspectionRoot = url.standardizedFileURL.resolvingSymlinksInPath()
        guard rootValues.isDirectory == true else { return inspection }

        var traversalFailed = false
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            }
        ) else { return nil }

        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited > maximumWalkEntries {
                inspection.complete = false
                break
            }
            if hasUnsafeName(child.lastPathComponent) {
                inspection.unsafe = true
                break
            }
            guard let values = try? child.resourceValues(forKeys: keys) else {
                inspection.complete = false
                break
            }
            if let requiredUID, !isOwned(child, by: requiredUID) {
                inspection.unsafe = true
                break
            }
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                if !symlinkResolvesInside(child, root: inspectionRoot) {
                    CamLog.line("deep runtime external symlink \(child.path) -> \(child.resolvingSymlinksInPath().path)")
                    inspection.unsafe = true
                    break
                }
                continue
            }
            if values.isDirectory == true, isMountPoint(child) {
                CamLog.line("deep runtime mounted tree \(child.path)")
                inspection.unsafe = true
                break
            }
            if values.isDirectory != true && values.isRegularFile != true {
                CamLog.line("deep runtime special file \(child.path)")
                inspection.unsafe = true
                break
            }
            if let modified = values.contentModificationDate, modified > inspection.newest {
                inspection.newest = modified
            }
        }
        if traversalFailed { inspection.complete = false }
        return inspection
    }

    private static func symlinkResolvesInside(_ url: URL, root: URL) -> Bool {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        return resolved.hasPrefix(rootPath + "/")
    }

    private static func hasUnsafeName(_ name: String) -> Bool {
        if Keep.names.contains(name) { return true }
        let lower = name.lowercased()
        return unsafeNameFragments.contains { lower.contains($0) }
    }

    private static func rawBatchBytes(
        _ urls: [URL],
        timeout: TimeInterval,
        cancellation: ScanCancellation? = nil
    ) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for start in stride(from: 0, to: urls.count, by: 220) {
            if cancellation?.isCancelled == true { break }
            let batch = Array(urls[start..<min(start + 220, urls.count)])
            let ran = CamProcess.run(
                path: "/usr/bin/du",
                arguments: ["-sk"] + batch.map(\.path),
                timeout: timeout,
                cancellation: cancellation
            )
            guard !ran.timedOut else { continue }
            for line in ran.out.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
                guard fields.count == 2,
                      let kb = Int64(fields[0].trimmingCharacters(in: .whitespaces)) else { continue }
                result[canonicalPath(URL(fileURLWithPath: String(fields[1])))] = kb * 1024
            }
        }
        return result
    }

    private static func bestEffortBytes(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let ran = CamProcess.run(path: "/usr/bin/du", arguments: ["-sk", url.path], timeout: 8)
        guard !ran.timedOut,
              let kbText = ran.out.split(whereSeparator: { $0.isWhitespace }).first,
              let kb = Int64(kbText) else { return 0 }
        return kb * 1024
    }

    private static func apfsSnapshotSummary() -> (total: Int, purgeable: Int)? {
        var snapshotsByID: [String: Bool] = [:]
        var completed = false
        for volume in ["/", "/System/Volumes/Data"] {
            let ran = CamProcess.run(
                path: "/usr/sbin/diskutil",
                arguments: ["apfs", "listSnapshots", volume, "-plist"],
                timeout: 5
            )
            guard !ran.timedOut,
                  let data = ran.out.data(using: .utf8),
                  let plist = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ),
                  let dictionary = plist as? [String: Any],
                  let snapshots = dictionary["Snapshots"] as? [[String: Any]] else { continue }
            completed = true
            for (index, snapshot) in snapshots.enumerated() {
                let id = snapshot["SnapshotUUID"] as? String
                    ?? snapshot["SnapshotName"] as? String
                    ?? "\(volume)#\(index)"
                snapshotsByID[id] = snapshotsByID[id] == true
                    || (snapshot["Purgeable"] as? Bool) == true
            }
        }
        guard completed else { return nil }
        return (
            total: snapshotsByID.count,
            purgeable: snapshotsByID.values.filter { $0 }.count
        )
    }

    private static func area(forID id: String) -> RuntimeArea? {
        if id.hasPrefix(RuntimeArea.cache.idPrefix) { return .cache }
        if id.hasPrefix(RuntimeArea.temporary.idPrefix) { return .temporary }
        if id.hasPrefix(RuntimeArea.sharedTemporary.idPrefix) { return .sharedTemporary }
        return nil
    }

    private static func isAllowedSharedTempTarget(_ url: URL, root: URL) -> Bool {
        let target = canonicalPath(url)
        let rootPath = canonicalPath(root)
        guard target.hasPrefix(rootPath + "/"), target != rootPath,
              pathComponentsAreOwnedAndNotSymlinks(url, below: root) else { return false }
        let targetComponents = URL(fileURLWithPath: target).pathComponents
        let rootComponents = URL(fileURLWithPath: rootPath).pathComponents
        let relative = Array(targetComponents.dropFirst(rootComponents.count))
        if relative.count == 1 { return true }
        return relative.count == 3
            && relative[0] == "claude-\(getuid())"
            && looksLikeUUID(relative[2])
    }

    private static func pathComponentsAreOwnedAndNotSymlinks(_ url: URL, below root: URL) -> Bool {
        let canonicalRoot = URL(fileURLWithPath: canonicalPath(root), isDirectory: true)
        let canonicalTarget = URL(fileURLWithPath: canonicalPath(url))
        let rootComponents = canonicalRoot.pathComponents
        let targetComponents = canonicalTarget.pathComponents
        guard targetComponents.starts(with: rootComponents) else { return false }
        var current = canonicalRoot
        for component in targetComponents.dropFirst(rootComponents.count) {
            current.appendPathComponent(component)
            var info = stat()
            guard lstat(current.path, &info) == 0,
                  info.st_uid == getuid(),
                  (info.st_mode & S_IFMT) != S_IFLNK else { return false }
        }
        return true
    }

    private static func ownedByCurrentUser(_ url: URL) -> Bool {
        isOwned(url, by: getuid())
    }

    /// A temp-looking directory can actually be an APFS image mounted by macOS/Xcode.
    /// Removing its mount point is never a cleanup operation. `stat`, unlike `lstat`,
    /// exposes the mounted filesystem's device id, which differs from the parent.
    private static func isMountPoint(_ url: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent()
        guard parent.path != url.standardizedFileURL.path else { return false }
        var targetInfo = stat()
        var parentInfo = stat()
        guard stat(url.path, &targetInfo) == 0 else { return false }
        guard stat(parent.path, &parentInfo) == 0 else { return true }
        return targetInfo.st_dev != parentInfo.st_dev
    }

    private static func isOwned(_ url: URL, by uid: uid_t) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == uid
    }

    private static func looksLikeUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    static func isMountPointForQA(_ url: URL) -> Bool {
        isMountPoint(url)
    }

    private static func isImmediateChild(_ url: URL, of root: URL) -> Bool {
        let target = URL(fileURLWithPath: canonicalPath(url))
        return canonicalPath(target.deletingLastPathComponent()) == canonicalPath(root)
            && canonicalPath(target) != canonicalPath(root)
    }

    private static func isDescendant(_ url: URL, of root: URL) -> Bool {
        let path = canonicalPath(url)
        let rootPath = canonicalPath(root)
        return path.hasPrefix(rootPath + "/")
    }

    static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(canonicalPath(url).utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func confstrURL(_ key: Int32) -> URL? {
        let count = confstr(key, nil, 0)
        guard count > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(key, &buffer, count) > 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        let path = String(decoding: bytes, as: UTF8.self)
        guard path.hasPrefix("/"), path != "/" else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    }
}
