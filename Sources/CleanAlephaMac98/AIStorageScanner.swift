import Foundation
import SQLite3

/// Finds AI-tool storage that classic cache scanners miss because the payload is packed
/// into SQLite blobs or extension-manager tombstones instead of normal media files.
///
/// The Cursor conversation database is analysis-only: Cursor owns its reachability graph
/// and provides built-in GC commands. We only delete extension payloads that Cursor itself
/// has marked obsolete, and re-check that marker immediately before Janitor may act.
enum AIStorageScanner {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var cursorDatabase: URL {
        home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
    }

    private static var cursorExtensions: URL {
        home.appendingPathComponent(".cursor/extensions")
    }

    private static var cursorExtensionTrash: URL {
        home.appendingPathComponent(
            "Library/Application Support/Cursor/CachedExtensionVSIXs/.trash"
        )
    }

    private static var cursorAgentVersions: URL {
        home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/anysphere.cursor-agent-worker/agent-cli/"
                + ".local/share/cursor-agent/versions"
        )
    }

    private static var codexRuntimeRoot: URL {
        home.appendingPathComponent(".cache/codex-runtimes")
    }

    private static var opencodeLogs: URL {
        home.appendingPathComponent(".local/share/opencode/log")
    }

    private static var codexStateDatabase: URL {
        home.appendingPathComponent(".codex/state_5.sqlite")
    }

    private static var codexSessions: URL {
        home.appendingPathComponent(".codex/sessions")
    }

    private static var codexArchivedSessions: URL {
        home.appendingPathComponent(".codex/archived_sessions")
    }

    private static var codexGeneratedImages: URL {
        home.appendingPathComponent(".codex/generated_images")
    }

    private static var claudeLocalSessions: URL {
        home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
    }

    static func items(cancellation: ScanCancellation? = nil) -> [JunkItem] {
        var rows: [JunkItem] = []
        func shouldStop() -> Bool { cancellation?.isCancelled == true }
        if let database = cursorDatabaseCard() { rows.append(database) }
        if shouldStop() { return [] }
        if let orphanChats = cursorOrphanChatCard() { rows.append(orphanChats) }
        if shouldStop() { return [] }
        if let orphanBlobs = cursorOrphanBlobCard(cancellation: cancellation) { rows.append(orphanBlobs) }
        if shouldStop() { return [] }
        if let orphanRollouts = codexOrphanRolloutCard() { rows.append(orphanRollouts) }
        if shouldStop() { return [] }
        if let orphanImages = codexOrphanGeneratedImagesCard() { rows.append(orphanImages) }
        if shouldStop() { return [] }
        if let orphanClaude = claudeOrphanLocalSessionsCard() { rows.append(orphanClaude) }
        if shouldStop() { return [] }
        if let trash = cursorExtensionTrashCard() { rows.append(trash) }
        if shouldStop() { return [] }
        rows.append(contentsOf: obsoleteCursorExtensionCards())
        if shouldStop() { return [] }
        rows.append(contentsOf: oldCursorAgentVersionCards())
        if shouldStop() { return [] }
        rows.append(contentsOf: staleCodexRuntimeInstallerCards())
        if shouldStop() { return [] }
        if let logs = opencodeLogCard() { rows.append(logs) }
        return rows.sorted { lhs, rhs in
            if lhs.kind == .advice, rhs.kind != .advice { return true }
            if rhs.kind == .advice, lhs.kind != .advice { return false }
            return lhs.bytes > rhs.bytes
        }
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        if item.id == "ai-cursor-state-db" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(cursorDatabase)
        }
        if item.id == "ai-cursor-orphan-chat-records" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(cursorDatabase)
        }
        if item.id == "ai-cursor-unreachable-blobs" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(cursorDatabase)
        }
        if item.id == "ai-codex-orphan-rollouts" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(codexSessions)
        }
        if item.id == "ai-codex-orphan-generated-images" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(codexGeneratedImages)
        }
        if item.id == "ai-claude-orphan-local-sessions" {
            return item.kind == .advice
                && canonicalPath(item.url) == canonicalPath(claudeLocalSessions)
        }
        if item.id == "ai-cursor-extension-trash" {
            return item.kind == .wipeChildren
                && canonicalPath(item.url) == canonicalPath(cursorExtensionTrash)
        }
        if item.id == "ai-opencode-logs" {
            return item.kind == .wipeChildren
                && canonicalPath(item.url) == canonicalPath(opencodeLogs)
        }
        if item.id.hasPrefix("ai-cursor-agent-old-") {
            return isOldCursorAgentVersionCard(item)
        }
        if item.id.hasPrefix("ai-codex-runtime-install-") {
            return isStaleCodexRuntimeInstallerCard(item)
        }
        return isObsoleteExtensionCard(item)
    }

    /// Destructive permission for Janitor. The scan-time manifest is never trusted later.
    static func isSafeDeletionCandidate(_ item: JunkItem) -> Bool {
        if item.id == "ai-cursor-extension-trash" {
            return item.kind == .wipeChildren
                && canonicalPath(item.url) == canonicalPath(cursorExtensionTrash)
                && isDirectoryWithoutSymlink(item.url)
        }
        if item.id == "ai-opencode-logs" {
            return item.kind == .wipeChildren
                && canonicalPath(item.url) == canonicalPath(opencodeLogs)
                && isDirectoryWithoutSymlink(item.url)
        }
        if item.id.hasPrefix("ai-cursor-agent-old-") {
            return isOldCursorAgentVersionCard(item)
        }
        if item.id.hasPrefix("ai-codex-runtime-install-") {
            return isStaleCodexRuntimeInstallerCard(item)
        }
        return isObsoleteExtensionCard(item)
    }

    static func manifestNamesForQA(_ data: Data) -> Set<String> {
        obsoleteExtensionNames(from: data)
    }

    private static func cursorDatabaseCard() -> JunkItem? {
        let bytes = DiskSizer.duSK(cursorDatabase, timeout: 2) ?? allocatedBytes(cursorDatabase)
        guard bytes >= 100 * 1_048_576 else { return nil }
        let blobCount = cursorAgentBlobCount()
        return JunkItem(
            id: "ai-cursor-state-db",
            module: .junk,
            title: Line(ru: "Cursor · скрытая база AI-истории", en: "Cursor · hidden AI history database"),
            subtitle: Line(
                ru: "Только анализ · \(blobCount) Agent blobs · недостижимые блоки определяются графом ссылок Cursor GC",
                en: "Read-only · \(blobCount) Agent blobs · unreachable blocks require Cursor's reachability GC"
            ),
            url: cursorDatabase,
            bytes: bytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    /// Per-conversation rows whose composer UUID no longer exists in Cursor's live/archive
    /// header table. This is deliberately audit-only: removing rows behind Cursor's back can
    /// leave its content-addressed Agent blob graph inconsistent.
    private static func cursorOrphanChatCard() -> JunkItem? {
        let sql = """
        WITH candidate(key, composer_id) AS (
          SELECT key, substr(key, length('composerData:') + 1, 36)
            FROM cursorDiskKV WHERE key GLOB 'composerData:*'
          UNION ALL
          SELECT key, substr(key, length('bubbleId:') + 1, 36)
            FROM cursorDiskKV WHERE key GLOB 'bubbleId:*'
          UNION ALL
          SELECT key, substr(key, length('checkpointId:') + 1, 36)
            FROM cursorDiskKV WHERE key GLOB 'checkpointId:*'
          UNION ALL
          SELECT key, substr(key, length('codeBlockDiff:') + 1, 36)
            FROM cursorDiskKV WHERE key GLOB 'codeBlockDiff:*'
          UNION ALL
          SELECT key, substr(key, length('codeBlockPartialInlineDiffFates:') + 1, 36)
            FROM cursorDiskKV WHERE key GLOB 'codeBlockPartialInlineDiffFates:*'
        )
        SELECT count(*), coalesce(sum(
                 length(c.key) + coalesce((
                   SELECT length(k.value) FROM cursorDiskKV k WHERE k.key = c.key
                 ), 0)
               ), 0)
          FROM candidate c
         WHERE length(c.composer_id) = 36
           AND NOT EXISTS (
             SELECT 1 FROM composerHeaders h WHERE h.composerId = c.composer_id
           )
        """
        guard let result = sqlitePair(at: cursorDatabase, sql: sql), result.0 > 0 else { return nil }
        return JunkItem(
            id: "ai-cursor-orphan-chat-records",
            module: .junk,
            title: Line(ru: "Cursor · остатки удалённых чатов", en: "Cursor · deleted-chat remnants"),
            subtitle: Line(
                ru: "\(result.0) записей больше не имеют заголовка живого/архивного чата · только аудит",
                en: "\(result.0) records no longer have a live/archived chat header · audit only"
            ),
            url: cursorDatabase,
            bytes: result.1,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    /// A read-only, content-addressed graph walk. The card is never actionable because the
    /// installed Cursor build must repeat its private protobuf walk immediately before GC.
    private static func cursorOrphanBlobCard(
        cancellation: ScanCancellation? = nil
    ) -> JunkItem? {
        guard let result = CursorBlobReachability.audit(
            database: cursorDatabase,
            cancellation: cancellation
        ),
              result.complete,
              result.candidateBlobs > 0,
              result.candidateLogicalBytes > 0 else { return nil }
        return JunkItem(
            id: "ai-cursor-unreachable-blobs",
            module: .junk,
            title: Line(
                ru: "Cursor · бесхозные блоки удалённых чатов",
                en: "Cursor · unreachable deleted-chat blobs"
            ),
            subtitle: Line(
                ru: "\(result.candidateBlobs) из \(result.totalBlobs) Agent blobs не достигнуты консервативным графом · перед удалением нужен native Cursor GC · только аудит",
                en: "\(result.candidateBlobs) of \(result.totalBlobs) Agent blobs were not reached by the conservative graph · native Cursor GC must recheck before deletion · audit only"
            ),
            url: cursorDatabase,
            bytes: result.candidateLogicalBytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    /// Rollout JSONL files not referenced by the authoritative Codex thread database.
    private static func codexOrphanRolloutCard() -> JunkItem? {
        let live = sqliteTextSet(at: codexStateDatabase, sql: "SELECT rollout_path FROM threads")
        guard !live.isEmpty else { return nil }
        var count = 0
        var bytes: Int64 = 0
        for root in [codexSessions, codexArchivedSessions] {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey, .fileSizeKey
                ],
                options: []
            ) else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "jsonl" {
                guard let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey, .fileSizeKey
                ]), values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let path = url.standardizedFileURL.path
                guard !live.contains(path) else { continue }
                count += 1
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        guard count > 0 else { return nil }
        return JunkItem(
            id: "ai-codex-orphan-rollouts",
            module: .junk,
            title: Line(ru: "Codex · журналы удалённых задач", en: "Codex · deleted-task rollouts"),
            subtitle: Line(
                ru: "\(count) JSONL больше не привязаны ни к живой, ни к архивной задаче · только аудит",
                en: "\(count) JSONL files are no longer linked to a live or archived task · audit only"
            ),
            url: codexSessions,
            bytes: bytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    private static func codexOrphanGeneratedImagesCard() -> JunkItem? {
        let live = sqliteTextSet(at: codexStateDatabase, sql: "SELECT id FROM threads")
        guard !live.isEmpty else { return nil }
        let directories = childDirectories(at: codexGeneratedImages)
        let orphans = directories.filter { !live.contains($0.lastPathComponent) }
        let bytes = orphans.reduce(Int64(0)) { partial, url in
            partial + (DiskSizer.duSK(url, timeout: 3) ?? 0)
        }
        guard !orphans.isEmpty, bytes > 0 else { return nil }
        return JunkItem(
            id: "ai-codex-orphan-generated-images",
            module: .junk,
            title: Line(ru: "Codex · outputs удалённых задач", en: "Codex · deleted-task outputs"),
            subtitle: Line(
                ru: "\(orphans.count) каталогов изображений не имеют задачи-владельца · только аудит",
                en: "\(orphans.count) generated-image directories have no owning task · audit only"
            ),
            url: codexGeneratedImages,
            bytes: bytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    /// Claude Cowork/local-agent keeps one `local_UUID.json` descriptor beside every
    /// `local_UUID` work tree. A tree with no descriptor is no longer reachable in the UI.
    private static func claudeOrphanLocalSessionsCard() -> JunkItem? {
        guard let enumerator = FileManager.default.enumerator(
            at: claudeLocalSessions,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return nil }
        var orphans: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 80_000 { break }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true, values.isSymbolicLink != true,
                  looksLikeClaudeLocalSession(url.lastPathComponent) else { continue }
            enumerator.skipDescendants()
            let descriptor = url.deletingLastPathComponent()
                .appendingPathComponent(url.lastPathComponent + ".json")
            if !FileManager.default.fileExists(atPath: descriptor.path) {
                orphans.append(url)
            }
        }
        let bytes = orphans.reduce(Int64(0)) { partial, url in
            partial + (DiskSizer.duSK(url, timeout: 3) ?? 0)
        }
        guard !orphans.isEmpty, bytes > 0 else { return nil }
        return JunkItem(
            id: "ai-claude-orphan-local-sessions",
            module: .junk,
            title: Line(ru: "Claude · остатки удалённых локальных чатов", en: "Claude · deleted local-chat remnants"),
            subtitle: Line(
                ru: "\(orphans.count) рабочих контейнеров больше не имеют индексного JSON · только аудит",
                en: "\(orphans.count) work containers no longer have an index JSON · audit only"
            ),
            url: claudeLocalSessions,
            bytes: bytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    private static func cursorAgentBlobCount() -> Int64 {
        sqlitePair(
            at: cursorDatabase,
            sql: "SELECT count(*), 0 FROM cursorDiskKV WHERE key GLOB 'agentKv:blob:*'"
        )?.0 ?? 0
    }

    private static func cursorExtensionTrashCard() -> JunkItem? {
        let bytes = DiskSizer.duSK(cursorExtensionTrash, timeout: 3) ?? 0
        guard bytes >= 1_048_576, isDirectoryWithoutSymlink(cursorExtensionTrash) else { return nil }
        return JunkItem(
            id: "ai-cursor-extension-trash",
            module: .junk,
            title: Line(ru: "Cursor · корзина обновлений AI", en: "Cursor · discarded AI updates"),
            subtitle: Line(
                ru: "Пакеты расширений, уже перемещённые Cursor в .trash · аккаунты и чаты целы",
                en: "Extension packages already moved to .trash by Cursor · accounts and chats stay"
            ),
            url: cursorExtensionTrash,
            bytes: bytes,
            selected: true,
            kind: .wipeChildren,
            keepsLogins: true
        )
    }

    private static func obsoleteCursorExtensionCards() -> [JunkItem] {
        let manifest = cursorExtensions.appendingPathComponent(".obsolete")
        guard let data = try? Data(contentsOf: manifest, options: [.mappedIfSafe]) else { return [] }
        let names = obsoleteExtensionNames(from: data)
        return names.compactMap { name in
            let url = cursorExtensions.appendingPathComponent(name, isDirectory: true)
            guard isImmediateChild(url, of: cursorExtensions), isDirectoryWithoutSymlink(url) else { return nil }
            let bytes = DiskSizer.duSK(url, timeout: 2) ?? 0
            guard bytes >= 1_048_576 else { return nil }
            return JunkItem(
                id: "ai-cursor-obsolete-\(stableKey(name))",
                module: .junk,
                title: Line(
                    ru: "Cursor · старое расширение \(displayName(name))",
                    en: "Cursor · obsolete extension \(displayName(name))"
                ),
                subtitle: Line(
                    ru: "Cursor сам пометил эту версию obsolete · новая версия остаётся",
                    en: "Cursor marked this version obsolete · the newer version stays"
                ),
                url: url,
                bytes: bytes,
                selected: false,
                kind: .deleteItem,
                keepsLogins: true
            )
        }
    }

    private static func oldCursorAgentVersionCards(now: Date = Date()) -> [JunkItem] {
        let versions = childDirectories(at: cursorAgentVersions)
            .filter { looksLikeCursorAgentVersion($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard let newest = versions.last else { return [] }
        return versions.dropLast().compactMap { url in
            guard isOlder(url, than: 7, now: now) else { return nil }
            let bytes = DiskSizer.duSK(url, timeout: 3) ?? 0
            guard bytes >= 1_048_576 else { return nil }
            return JunkItem(
                id: "ai-cursor-agent-old-\(stableKey(url.lastPathComponent))",
                module: .junk,
                title: Line(ru: "Cursor Agent · старая версия", en: "Cursor Agent · old version"),
                subtitle: Line(
                    ru: "\(url.lastPathComponent) · актуальная \(newest.lastPathComponent) остаётся · выкл.",
                    en: "\(url.lastPathComponent) · current \(newest.lastPathComponent) stays · off"
                ),
                url: url,
                bytes: bytes,
                selected: false,
                kind: .deleteItem,
                keepsLogins: true
            )
        }
    }

    private static func staleCodexRuntimeInstallerCards(now: Date = Date()) -> [JunkItem] {
        childDirectories(at: codexRuntimeRoot).compactMap { url in
            guard url.lastPathComponent.hasPrefix("codex-runtime-install-"),
                  isOlder(url, than: 2, now: now) else { return nil }
            let bytes = DiskSizer.duSK(url, timeout: 3) ?? 0
            guard bytes >= 1_048_576 else { return nil }
            return JunkItem(
                id: "ai-codex-runtime-install-\(stableKey(url.lastPathComponent))",
                module: .junk,
                title: Line(ru: "Codex · остаток установки runtime", en: "Codex · runtime install remnant"),
                subtitle: Line(
                    ru: "Незавершённая/старая staging-копия · основной runtime остаётся · выкл.",
                    en: "Stale/incomplete staging copy · primary runtime stays · off"
                ),
                url: url,
                bytes: bytes,
                selected: false,
                kind: .deleteItem,
                keepsLogins: true
            )
        }
    }

    private static func opencodeLogCard() -> JunkItem? {
        let bytes = DiskSizer.duSK(opencodeLogs, timeout: 3) ?? 0
        guard bytes >= 1_048_576, isDirectoryWithoutSymlink(opencodeLogs) else { return nil }
        return JunkItem(
            id: "ai-opencode-logs",
            module: .junk,
            title: Line(ru: "OpenCode · старые логи", en: "OpenCode · old logs"),
            subtitle: Line(ru: "Диагностические логи · чаты и база остаются", en: "Diagnostic logs · chats and database stay"),
            url: opencodeLogs,
            bytes: bytes,
            selected: true,
            kind: .wipeChildren,
            keepsLogins: true
        )
    }

    private static func isObsoleteExtensionCard(_ item: JunkItem) -> Bool {
        guard item.id.hasPrefix("ai-cursor-obsolete-"), item.kind == .deleteItem,
              isImmediateChild(item.url, of: cursorExtensions),
              isDirectoryWithoutSymlink(item.url) else { return false }
        let manifest = cursorExtensions.appendingPathComponent(".obsolete")
        guard let data = try? Data(contentsOf: manifest, options: [.mappedIfSafe]) else { return false }
        return obsoleteExtensionNames(from: data).contains(item.url.lastPathComponent)
    }

    private static func isOldCursorAgentVersionCard(_ item: JunkItem) -> Bool {
        guard item.id == "ai-cursor-agent-old-\(stableKey(item.url.lastPathComponent))",
              item.kind == .deleteItem,
              isImmediateChild(item.url, of: cursorAgentVersions),
              isDirectoryWithoutSymlink(item.url),
              looksLikeCursorAgentVersion(item.url.lastPathComponent),
              isOlder(item.url, than: 7) else { return false }
        return childDirectories(at: cursorAgentVersions).contains { sibling in
            looksLikeCursorAgentVersion(sibling.lastPathComponent)
                && sibling.lastPathComponent > item.url.lastPathComponent
        }
    }

    private static func isStaleCodexRuntimeInstallerCard(_ item: JunkItem) -> Bool {
        item.id == "ai-codex-runtime-install-\(stableKey(item.url.lastPathComponent))"
            && item.kind == .deleteItem
            && isImmediateChild(item.url, of: codexRuntimeRoot)
            && item.url.lastPathComponent.hasPrefix("codex-runtime-install-")
            && isDirectoryWithoutSymlink(item.url)
            && isOlder(item.url, than: 2)
    }

    private static func childDirectories(at root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ))?.filter(isDirectoryWithoutSymlink) ?? []
    }

    private static func looksLikeCursorAgentVersion(_ value: String) -> Bool {
        let parts = value.split(separator: "-", maxSplits: 1)
        guard parts.count == 2, parts[0].split(separator: ".").count == 3,
              parts[1].count >= 6 else { return false }
        return parts[0].split(separator: ".").allSatisfy { Int($0) != nil }
            && parts[1].allSatisfy { $0.isHexDigit }
    }

    private static func looksLikeClaudeLocalSession(_ value: String) -> Bool {
        guard value.hasPrefix("local_") else { return false }
        return UUID(uuidString: String(value.dropFirst("local_".count))) != nil
    }

    private static func sqlitePair(at url: URL, sql: String) -> (Int64, Int64)? {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close_v2(database) }
            return nil
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (sqlite3_column_int64(statement, 0), sqlite3_column_int64(statement, 1))
    }

    private static func sqliteTextSet(at url: URL, sql: String) -> Set<String> {
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close_v2(database) }
            return []
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 1_500)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var values = Set<String>()
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let text = sqlite3_column_text(statement, 0) else { continue }
            values.insert(String(cString: text))
        }
        return values
    }

    private static func isOlder(_ url: URL, than days: Int, now: Date = Date()) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate else { return false }
        return now.timeIntervalSince(modified) >= Double(days) * 86_400
    }

    private static func obsoleteExtensionNames(from data: Data) -> Set<String> {
        guard data.count <= 2_097_152,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        return Set(object.compactMap { name, marker -> String? in
            guard (marker as? Bool) == true, isSafeExtensionName(name) else { return nil }
            return name
        })
    }

    private static func isSafeExtensionName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("."), name != "..", name.count <= 240 else { return false }
        guard name.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        return !name.contains("/") && !name.contains("\\") && !name.contains(":")
    }

    private static func isImmediateChild(_ url: URL, of root: URL) -> Bool {
        let parent = url.standardizedFileURL.deletingLastPathComponent().path
        return parent == root.standardizedFileURL.path
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func allocatedBytes(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
    }

    private static func displayName(_ name: String) -> String {
        if name.count <= 46 { return name }
        return String(name.prefix(43)) + "…"
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
