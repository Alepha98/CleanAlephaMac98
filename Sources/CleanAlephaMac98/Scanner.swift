import CryptoKit
import Foundation

struct StageChunk: Sendable {
    var items: [JunkItem]
    var failed: Bool
}

private struct Gathered: Sendable {
    var items: [JunkItem]
    var failed: Bool = false
}

enum Scanner {
    static func home() -> URL { FileManager.default.homeDirectoryForCurrentUser }

    private static let minCacheBytes: Int64 = 2_097_152

    /// Chromium-family cache folders inside a profile — never Cookies / Login Data.
    private static let profileCacheNames: [String] = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "ShaderCache", "GrShaderCache"
    ]

    /// Never wipe the complete Service Worker directory: its registration database is
    /// session-adjacent. Only these two reproducible payload caches are safe targets.
    private static let serviceWorkerCacheNames: [String] = ["CacheStorage", "ScriptCache"]

    /// Apple caches we refuse to wipe (CloudKit / Music / etc.).
    private static let appleCacheDeny: Set<String> = [
        "CloudKit",
        "com.apple.Music",
        "com.apple.AMPLibraryAgent",
        "com.apple.AppleMediaServices",
        "com.apple.appstoreagent",
        "com.apple.itunescloudd",
        "com.apple.AvatarKit",
        "PassKit",
        "SiriEntityCache",
        "familycircled",
        "com.apple.ap.adprivacyd",
        "com.apple.VisualIntelligenceCore",
        "com.apple.intelligenceflow.intelligenceflowd",
        "com.apple.ctcategories.service",
        "com.apple.WorkflowKit.BackgroundShortcutRunner"
    ]

    /// Safe Apple cache folders we still list explicitly / allow from enumeration.
    private static let appleCacheAllow: Set<String> = [
        "com.apple.helpd",
        "GeoServices",
        "com.apple.geod",
        "com.apple.FontRegistry",
        "com.apple.QuickLook.thumbnailcache"
    ]

    /// Already covered by named junk / browser / deep cards — skip duplicate enum ids.
    private static let cachesCoveredElsewhere: Set<String> = [
        "go-build", "org.swift.swiftpm", "pnpm", "Google", "com.apple.Safari",
        "Homebrew", "com.spotify.client", "com.getdropbox.Dropbox",
        "com.microsoft.OneDrive", "pip", "CocoaPods", "ms-playwright",
        "com.apple.helpd", "GeoServices", "com.apple.geod",
        "com.apple.FontRegistry", "com.apple.QuickLook.thumbnailcache",
        "org.carthage.CarthageKit", "composer"
    ]

    /// Container caches we never list (Photos / analysis / iCloud-adjacent).
    private static let containerCacheDeny: Set<String> = [
        "com.apple.photoanalysisd",
        "com.apple.photolibraryd",
        "com.apple.Photos",
        "com.apple.photos.ImageConversionService",
        "com.apple.CloudDocs.MobileDocumentsFileProvider",
        "com.apple.bird",
        "com.apple.mediaanalysisd"
    ]

    enum ScanStage: Int, CaseIterable, Sendable {
        case junk, mail, trash, leftovers, large, duplicates, browsers, dev, messengers, privacy
        func items(cancellation: ScanCancellation? = nil) -> [JunkItem] {
            switch self {
            case .junk: Scanner.junk(cancellation: cancellation)
            case .mail: Scanner.mail()
            case .trash: Scanner.trash()
            case .leftovers: Scanner.leftovers().items
            case .large: Scanner.largeFiles().items
            case .duplicates: Scanner.duplicates().items
            case .browsers: Scanner.browsers()
            case .dev: Scanner.dev()
            case .messengers: Scanner.messengers()
            case .privacy: DeepScan.privacyItems()
            }
        }

        var module: Module {
            switch self {
            case .junk: .junk
            case .mail: .mail
            case .trash: .trash
            case .leftovers: .leftovers
            case .large: .large
            case .duplicates: .duplicates
            case .browsers: .browsers
            case .dev: .dev
            case .messengers: .messengers
            case .privacy: .privacy
            }
        }

        static func stages(for module: Module) -> [ScanStage] {
            if module == .smart { return Array(allCases) }
            return allCases.filter { $0.module == module }
        }
    }

    /// Isolates a stage so one bad folder does not abort the whole scan.
    static func safeItems(
        for stage: ScanStage,
        cancellation: ScanCancellation? = nil
    ) -> StageChunk {
        ScanThrottle.beginWorker()
        return autoreleasepool {
            guard cancellation?.isCancelled != true else {
                return StageChunk(items: [], failed: false)
            }
            var failed = false
            let raw: [JunkItem]
            switch stage {
            case .leftovers:
                let gathered = leftovers()
                raw = gathered.items
                failed = gathered.failed
            case .large:
                let gathered = largeFiles()
                raw = gathered.items
                failed = gathered.failed
            case .duplicates:
                let gathered = duplicates()
                raw = gathered.items
                failed = gathered.failed
            case .trash:
                raw = trash()
            default:
                raw = stage.items(cancellation: cancellation)
            }
            guard cancellation?.isCancelled != true else {
                return StageChunk(items: [], failed: false)
            }
            ScanThrottle.reliefIfNeeded()
            return StageChunk(
                items: raw.filter { shouldInclude($0, in: stage) },
                failed: failed
            )
        }
    }

    private static func shouldInclude(_ item: JunkItem, in stage: ScanStage) -> Bool {
        // Trash: any non-empty bin counts (even small). Large sparse files and APFS
        // clones stay visible even when deleting one path reclaims little or no space.
        let minBytes: Int64 = stage == .trash ? 1 : 16_384
        // Permission/audit cards intentionally have an unknown (zero) size. Dropping
        // them would turn "macOS denied access" into a misleading "nothing found".
        guard item.kind == .advice || stage == .large || stage == .duplicates
                || item.bytes > minBytes else { return false }
        if Keep.isDismissed(item.id) { return false }
        if Keep.isExtraProtected(item.url) { return false }
        if Keep.allowsExplicitCard(item) { return true }
        return !Keep.isProtected(item.url)
    }

    static func shouldIncludeForQA(_ item: JunkItem, in stage: ScanStage) -> Bool {
        shouldInclude(item, in: stage)
    }

    private static func item(
        _ id: String, _ module: Module, _ title: Line, _ subtitle: Line,
        _ rel: String, selected: Bool = true, kind: CleanKind = .wipeChildren, keeps: Bool = false
    ) -> JunkItem? {
        let url = home().appendingPathComponent(rel)
        let b = DiskSizer.bytes(at: url)
        guard b > 0 else { return nil }
        return JunkItem(id: id, module: module, title: title, subtitle: subtitle, url: url, bytes: b, selected: selected, kind: kind, keepsLogins: keeps)
    }

    private static func folderItem(
        id: String,
        module: Module,
        title: Line,
        subtitle: Line,
        url: URL,
        selected: Bool = true,
        kind: CleanKind = .wipeChildren,
        keeps: Bool = false,
        measureTimeout: TimeInterval? = nil
    ) -> JunkItem? {
        if Keep.isProtected(url) { return nil }
        let b: Int64
        if let measureTimeout {
            guard let measured = DiskSizer.boundedBytes(at: url, timeout: measureTimeout) else { return nil }
            b = measured
        } else {
            b = DiskSizer.bytes(at: url)
        }
        guard b >= minCacheBytes else { return nil }
        return JunkItem(
            id: id,
            module: module,
            title: title,
            subtitle: subtitle,
            url: url,
            bytes: b,
            selected: selected,
            kind: kind,
            keepsLogins: keeps
        )
    }

    static func junk(cancellation: ScanCancellation? = nil) -> [JunkItem] {
        var rows: [JunkItem] = []
        func appendPhase(_ label: String, _ work: () -> [JunkItem]) -> Bool {
            guard cancellation?.isCancelled != true else { return false }
            rows.append(contentsOf: measured(label, work))
            return cancellation?.isCancelled != true
        }
        func cancelled() -> [JunkItem] {
            CamLog.line("junk cancelled items=\(rows.count)")
            return []
        }
        let fixed: [(String, Line, String, Line)] = [
            ("logs", Line(ru: "Логи пользователя", en: "User logs"), "Library/Logs", Line(ru: "Диагностика, крэши, болтливые агенты", en: "Diagnostics, crashes, chatty agents")),
            ("crash", Line(ru: "Отчёты о падениях", en: "Crash reports"), "Library/Application Support/CrashReporter", Line(ru: "Старые CrashReporter", en: "Old CrashReporter files")),
            ("state", Line(ru: "Снимки окон", en: "Window snapshots"), "Library/Saved Application State", Line(ru: "Пересоздаются при открытии. По умолчанию выкл.", en: "Recreated when you reopen. Off by default.")),
            ("capcut", Line(ru: "Кэш CapCut", en: "CapCut cache"), "Movies/CapCut/User Data/Cache", Line(ru: "Проекты целы", en: "Projects stay")),
            ("claude-ui", Line(ru: "Кэш Claude UI", en: "Claude UI cache"), "Library/Application Support/Claude/Cache", Line(ru: "Не VM", en: "Not the VM")),
            ("claude-code", Line(ru: "Кэш Claude Code", en: "Claude Code cache"), "Library/Application Support/Claude/Code Cache", Line(ru: "Не VM", en: "Not the VM")),
            ("cursor-cache", Line(ru: "Кэш Cursor", en: "Cursor cache"), "Library/Application Support/Cursor/Cache", Line(ru: "Не чаты", en: "Not your chats")),
            ("cursor-gpu", Line(ru: "GPU-кэш Cursor", en: "Cursor GPU cache"), "Library/Application Support/Cursor/GPUCache", Line(ru: "Шейдеры", en: "Shaders")),
            ("cursor-logs", Line(ru: "Логи Cursor", en: "Cursor logs"), "Library/Application Support/Cursor/logs", Line(ru: "Логи редактора", en: "Editor logs")),
            ("cursor-cacheddata", Line(ru: "Cursor CachedData", en: "Cursor CachedData"), "Library/Application Support/Cursor/CachedData", Line(ru: "Не чаты", en: "Not your chats")),
            ("dl-incomplete", Line(ru: "Недокачанные загрузки", en: "Incomplete downloads"), "Library/Incomplete Downloads", Line(ru: "Оборванные .download / части", en: "Broken .download parts")),
            ("homebrew-cache", Line(ru: "Кэш Homebrew", en: "Homebrew cache"), "Library/Caches/Homebrew", Line(ru: "Бутылки скачаются снова", en: "Bottles re-download")),
            ("cursor-shipit", Line(ru: "Обновления Cursor (ShipIt)", en: "Cursor update leftovers"), "Library/Caches/com.todesktop.230313mzl4w4u92.ShipIt", Line(ru: "Старые пакеты обновлений", en: "Old update packages")),
            ("code-vsix", Line(ru: "Кэш расширений VS Code", en: "VS Code extension cache"), "Library/Application Support/Code/CachedExtensionVSIXs", Line(ru: "Перекачаются при нужде", en: "Re-download if needed")),
            ("code-cacheddata", Line(ru: "CachedData VS Code", en: "VS Code CachedData"), "Library/Application Support/Code/CachedData", Line(ru: "Не настройки", en: "Not settings")),
            ("code-cache", Line(ru: "Кэш VS Code", en: "VS Code Cache"), "Library/Application Support/Code/Cache", Line(ru: "Не настройки", en: "Not settings")),
            ("opencode-cache", Line(ru: "Кэш OpenCode", en: "OpenCode cache"), "Library/Application Support/ai.opencode.desktop/Cache", Line(ru: "Кэш приложения", en: "App cache")),
            ("cloudkit-cache", Line(ru: "Кэш CloudKit", en: "CloudKit cache"), "Library/Caches/CloudKit", Line(ru: "Пересоберётся. По умолчанию выкл.", en: "Rebuilds. Off by default."))
        ]
        guard appendPhase("junk fixed", { fixed.compactMap { entry in
            let selected = entry.0 != "cloudkit-cache" && entry.0 != "state"
            return item(entry.0, .junk, entry.1, entry.3, entry.2, selected: selected)
        } }) else { return cancelled() }
        guard appendPhase("junk user-caches", { enumeratedUserCaches() }) else { return cancelled() }
        guard appendPhase("junk dot-cache", { enumeratedDotCache() }) else { return cancelled() }
        guard appendPhase("junk containers", { enumeratedContainerCaches() }) else { return cancelled() }
        guard appendPhase("junk app-support", { enumeratedAppSupportCaches() }) else { return cancelled() }
        guard appendPhase("junk deep", { DeepScan.junkExtras() }) else { return cancelled() }
        guard appendPhase("junk hidden-captures", { HiddenCaptureScanner.items() }) else { return cancelled() }
        guard appendPhase("junk forensic-remnants", { ForensicRemnantScanner.items() }) else { return cancelled() }
        guard appendPhase("junk screenshot-provenance", { ScreenshotProvenanceScanner.items() }) else { return cancelled() }
        guard appendPhase("junk deep-media-forensics", {
            DeepMediaForensicsScanner.items(cancellation: cancellation)
        }) else { return cancelled() }
        guard appendPhase("junk system-deep", {
            SystemDeepScanner.items(cancellation: cancellation)
        }) else { return cancelled() }
        guard appendPhase("junk ai-storage", { AIStorageScanner.items(cancellation: cancellation) }) else { return cancelled() }
        guard appendPhase("junk artifacts", { ArtifactScanner.items() }) else { return cancelled() }
        guard appendPhase("junk hidden-trees", {
            HiddenTreeScanner.items(cancellation: cancellation)
        }) else { return cancelled() }
        guard appendPhase("junk intelligence", {
            StorageIntelligenceScanner.items(cancellation: cancellation)
        }) else { return cancelled() }
        guard appendPhase("junk installers", { oldInstallers() }) else { return cancelled() }
        guard appendPhase("junk ios-backups", { oldIOSBackups() }) else { return cancelled() }
        return dedupeByURL(rows).filter { !Keep.isDismissed($0.id) }.sorted { $0.bytes > $1.bytes }
    }

    private static func measured(_ label: String, _ work: () -> [JunkItem]) -> [JunkItem] {
        let started = Date()
        let rows = work()
        CamLog.line("\(label) items=\(rows.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
        return rows
    }

    /// Walk ~/Library/Containers/*/Data/Library/Caches — big gap vs CleanMyMac-style finds.
    private static func enumeratedContainerCaches() -> [JunkItem] {
        let root = home().appendingPathComponent("Library/Containers")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var candidates: [(id: String, url: URL)] = []
        var n = 0
        for container in kids {
            ScanThrottle.tickSync(every: 20, counter: &n)
            let id = container.lastPathComponent
            if containerCacheDeny.contains(id) { continue }
            if id.lowercased().contains("photo") { continue }
            if id.lowercased().contains("icloud") { continue }
            let cache = container.appendingPathComponent("Data/Library/Caches")
            if Keep.isProtected(cache) { continue }
            candidates.append((id, cache))
        }
        let sizes = DiskSizer.batchBytes(at: candidates.map(\.url), timeout: 7)
        return candidates.compactMap { candidate in
            let bytes = sizes[candidate.url.standardizedFileURL.path] ?? 0
            guard bytes >= minCacheBytes else { return nil }
            return JunkItem(
                id: "ccache-\(candidate.id)",
                module: .junk,
                title: Line(ru: "Кэш \(shortBundle(candidate.id))", en: "Cache \(shortBundle(candidate.id))"),
                subtitle: Line(ru: "Container cache", en: "Container cache"),
                url: candidate.url,
                bytes: bytes,
                selected: !candidate.id.hasPrefix("com.apple."),
                kind: .wipeChildren,
                keepsLogins: false
            )
        }
    }

    private static func shortBundle(_ id: String) -> String {
        if id.count <= 28 { return id }
        return String(id.suffix(24))
    }

    /// Application Support/*/Cache|GPUCache|Code Cache|CachedData — Electron apps pile up here.
    private static func enumeratedAppSupportCaches() -> [JunkItem] {
        let root = home().appendingPathComponent("Library/Application Support")
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let names = ["Cache", "GPUCache", "Code Cache", "CachedData", "DawnCache", "ShaderCache"]
        var out: [JunkItem] = []
        var n = 0
        for app in apps {
            ScanThrottle.tickSync(every: 15, counter: &n)
            let appName = app.lastPathComponent
            if appName.hasPrefix("com.apple") { continue }
            if Keep.isProtected(app) { continue }
            if appName == "Claude" { continue } // VM path protected separately; UI caches listed fixed
            for leaf in names {
                let url = app.appendingPathComponent(leaf)
                guard let item = folderItem(
                    id: "ascache-\(appName)-\(leaf)",
                    module: .junk,
                    title: Line(ru: "\(appName) · \(leaf)", en: "\(appName) · \(leaf)"),
                    subtitle: Line(ru: "Application Support", en: "Application Support"),
                    url: url,
                    selected: true,
                    measureTimeout: 1.2
                ) else { continue }
                out.append(item)
            }
        }
        return out
    }

    /// Old .dmg / .pkg in Downloads (secondary – off by default).
    private static func oldInstallers() -> [JunkItem] {
        let root = home().appendingPathComponent("Downloads")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
        var out: [JunkItem] = []
        for url in kids {
            let ext = url.pathExtension.lowercased()
            guard ["dmg", "pkg", "iso"].contains(ext) else { continue }
            guard let rv = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  rv.isRegularFile == true,
                  let size = rv.fileSize,
                  Int64(size) >= 20_000_000 else { continue }
            let old = (rv.contentModificationDate ?? .distantPast) < cutoff
            out.append(JunkItem(
                id: "installer-\(url.lastPathComponent.hashValue)",
                module: .junk,
                title: Line.proper(url.lastPathComponent),
                subtitle: Line(
                    ru: old ? "Старый установщик в Загрузках (≥30 дн.)" : "Установщик в Загрузках",
                    en: old ? "Old installer in Downloads (≥30 days)" : "Installer in Downloads"
                ),
                url: url,
                bytes: Int64(size),
                selected: false,
                kind: .deleteItem,
                keepsLogins: false
            ))
        }
        return out.sorted { $0.bytes > $1.bytes }
    }

    /// Finder-managed local device backups can occupy tens of gigabytes. Expose only
    /// complete, stale backup folders; never individual blobs that would corrupt a backup.
    /// They remain opt-in and outside the safe preset.
    private static func oldIOSBackups(now: Date = Date()) -> [JunkItem] {
        let root = home().appendingPathComponent("Library/Application Support/MobileSync/Backup")
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var candidates: [(url: URL, device: String, date: Date)] = []
        for url in children {
            guard let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey
            ]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let info = backupInfo(at: url)
            let date = info.date ?? values.contentModificationDate ?? .distantPast
            guard now.timeIntervalSince(date) >= 30 * 86_400 else { continue }
            candidates.append((url, info.device ?? "iPhone / iPad", date))
        }

        let sizes = DiskSizer.batchBytes(at: candidates.map(\.url), timeout: 18)
        return candidates.compactMap { candidate in
            let path = candidate.url.standardizedFileURL.path
            let bytes = sizes[path] ?? 0
            guard bytes >= 100_000_000 else { return nil }
            let ageDays = max(0, Int(now.timeIntervalSince(candidate.date) / 86_400))
            return JunkItem(
                id: "ios-backup-\(candidate.url.lastPathComponent)",
                module: .junk,
                title: Line(ru: "Бэкап · \(candidate.device)", en: "Backup · \(candidate.device)"),
                subtitle: Line(
                    ru: "Локальная копия целиком · \(ageDays) дн. · выкл.",
                    en: "Complete local backup · \(ageDays)d · off"
                ),
                url: candidate.url,
                bytes: bytes,
                selected: false,
                kind: .deleteItem,
                keepsLogins: false
            )
        }.sorted { $0.bytes > $1.bytes }
    }

    private static func backupInfo(at backup: URL) -> (device: String?, date: Date?) {
        let plist = backup.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let raw = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = raw as? [String: Any] else { return (nil, nil) }
        let device = (info["Device Name"] as? String) ?? (info["Display Name"] as? String)
        let date = (info["Last Backup Date"] as? Date) ?? (info["Date"] as? Date)
        return (device, date)
    }

    /// Walk ~/Library/Caches — one card per folder ≥ 8 MB.
    private static func enumeratedUserCaches() -> [JunkItem] {
        let root = home().appendingPathComponent("Library/Caches")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            if cachesCoveredElsewhere.contains(name) { continue }
            if appleCacheDeny.contains(name) { continue }
            if name.hasPrefix("com.apple."), !appleCacheAllow.contains(name) { continue }
            if Keep.isProtected(url) { continue }
            if Keep.names.contains(name) { continue }
            guard let item = folderItem(
                id: "ucache-\(name)",
                module: .junk,
                title: Line(ru: "Кэш \(name)", en: "Cache \(name)"),
                subtitle: Line(ru: "Library/Caches", en: "Library/Caches"),
                url: url,
                selected: true,
                measureTimeout: 1.2
            ) else { continue }
            out.append(item)
        }
        return out
    }

    /// Walk ~/.cache — huggingface / codex-runtimes off by default.
    private static func enumeratedDotCache() -> [JunkItem] {
        let root = home().appendingPathComponent(".cache")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let rebuildOff: Set<String> = ["huggingface", "codex-runtimes"]
        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            if Keep.isProtected(url) { continue }
            let off = rebuildOff.contains(name)
            guard let item = folderItem(
                id: "dotcache-\(name)",
                module: .junk,
                title: Line.proper("~/.cache/\(name)"),
                subtitle: off ? Copy.rebuildBadge : Line(ru: "Локальный кэш", en: "Local cache"),
                url: url,
                selected: !off
            ) else { continue }
            out.append(item)
        }
        return out
    }

    private static func mail() -> [JunkItem] {
        [
            item("mail-dl", .mail, Line(ru: "Загрузки Mail", en: "Mail Downloads"), Line(ru: "Вложения, скачанные из писем", en: "Attachments saved from mail"), "Library/Containers/com.apple.mail/Data/Library/Mail Downloads"),
            item("mail-dl2", .mail, Line(ru: "Загрузки Mail", en: "Mail Downloads"), Line(ru: "Классическая папка Mail", en: "Classic Mail folder"), "Library/Mail Downloads")
        ].compactMap { $0 }
    }

    private static func trash() -> [JunkItem] {
        var out: [JunkItem] = []
        let user = home().appendingPathComponent(".Trash")
        if let item = trashBin(
            id: "trash-user",
            title: Copy.trashUser,
            subtitle: Copy.trashUserSub,
            url: user
        ) {
            out.append(item)
        }

        // CloudDocs keeps a second hidden trash outside ~/.Trash. Finder exposes it only
        // with hidden files enabled, so classic cleaners commonly miss it entirely.
        let cloudTrash = home().appendingPathComponent("Library/Mobile Documents/.Trash")
        if let item = trashBin(
            id: "trash-icloud",
            title: Line(ru: "Скрытая корзина iCloud Drive", en: "Hidden iCloud Drive Trash"),
            subtitle: Line(
                ru: "Отдельно от обычной Корзины · удаление только вручную",
                en: "Separate from normal Trash · manual opt-in only"
            ),
            url: cloudTrash
        ) {
            out.append(item)
        }

        let uid = String(getuid())
        let vols = (try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes"),
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        for vol in vols {
            // Skip the boot volume alias; user trash already covers Macintosh HD home.
            let name = vol.lastPathComponent
            if name == "Macintosh HD" || name == "Recovery" { continue }
            let bin = vol.appendingPathComponent(".Trashes").appendingPathComponent(uid)
            if let item = trashBin(
                id: "trash-vol-\(name)",
                title: Line(ru: "\(Copy.trashVolume.ru) «\(name)»", en: "\(Copy.trashVolume.en) “\(name)”"),
                subtitle: Copy.trashUserSub,
                url: bin
            ) {
                out.append(item)
            }
        }
        return out
    }

    private static func trashBin(id: String, title: Line, subtitle: Line, url: URL) -> JunkItem? {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        guard let kids = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            // A TCC-denied Trash must never be reported as empty. The advice card cannot
            // be selected or passed to Janitor; it only tells the user why the scan is partial.
            return JunkItem(
                id: "\(id)-denied",
                module: .trash,
                title: title,
                subtitle: Line(
                    ru: "macOS запретила чтение · размер неизвестен · нужен Полный доступ к диску",
                    en: "macOS denied reading · size unknown · Full Disk Access required"
                ),
                url: url,
                bytes: 0,
                selected: false,
                kind: .advice,
                keepsLogins: true
            )
        }
        let visible = kids.filter { $0.lastPathComponent != ".DS_Store" }
        guard !visible.isEmpty else { return nil }
        var bytes = DiskSizer.trashBytes(at: url)
        if bytes <= 0 {
            // Still non-empty – show at least something so we never lie «чисто».
            bytes = max(Int64(visible.count) * 4_096, 4_096)
        }
        return JunkItem(
            id: id,
            module: .trash,
            title: title,
            subtitle: subtitle,
            url: url,
            bytes: bytes,
            selected: false,
            kind: .emptyTrash,
            keepsLogins: false
        )
    }

    private struct DuplicateCandidate {
        let url: URL
        let facts: FileStorageFacts
        let modified: Date
    }

    /// Duplicate files in the main user-document roots. The full hash proves equal
    /// content; inode and APFS content ids prevent fake reclaim estimates for links/clones.
    private static func duplicates() -> Gathered {
        let roots = [
            home().appendingPathComponent("Desktop"),
            home().appendingPathComponent("Documents"),
            home().appendingPathComponent("Downloads"),
            home().appendingPathComponent("Pictures"),
            home().appendingPathComponent("Movies")
        ]
        let folderCards = DuplicateFolderScanner.items(in: roots)
        var gathered = duplicates(in: roots, minimumLogicalBytes: 1_048_576)
        // One whole-folder result is easier to understand than dozens of child-file rows.
        // Suppress only children of a proven, removable duplicate tree; APFS/hard-link
        // audit cards do not hide independently useful file findings.
        let coveredFolders = folderCards
            .filter { $0.kind == .deleteItem }
            .map { $0.url.standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        gathered.items.removeAll { item in
            let path = item.url.standardizedFileURL.resolvingSymlinksInPath().path
            return coveredFolders.contains(where: { path.hasPrefix($0) })
        }
        gathered.items.append(contentsOf: folderCards)
        gathered.items.append(contentsOf: SimilarCaptureScanner.items())
        gathered.items = dedupeByURL(gathered.items).sorted { lhs, rhs in
            if lhs.kind == .advice, rhs.kind != .advice { return false }
            if lhs.kind != .advice, rhs.kind == .advice { return true }
            return lhs.bytes > rhs.bytes
        }
        ContentFingerprinter.flush()
        return gathered
    }

    private static func duplicates(
        in roots: [URL],
        minimumLogicalBytes minFile: Int64
    ) -> Gathered {
        let fm = FileManager.default
        var bySize: [Int64: [DuplicateCandidate]] = [:]
        var failed = false
        for root in roots {
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(FileStorageFacts.resourceKeys)
                    + [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                if fm.fileExists(atPath: root.path) { failed = true }
                continue
            }
            var n = 0
            for case let url as URL in en {
                n += 1
                if n > 40_000 { break }
                if Keep.isProtected(url) {
                    en.skipDescendants()
                    continue
                }
                guard let facts = FileStorageFacts.read(url),
                      !facts.isCloudPlaceholder,
                      facts.logicalBytes >= minFile else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                bySize[facts.logicalBytes, default: []].append(
                    DuplicateCandidate(url: url, facts: facts, modified: modified)
                )
            }
        }

        var items: [JunkItem] = []
        var group = 0
        for size in bySize.keys.sorted(by: >) {
            guard let candidates = bySize[size], candidates.count > 1 else { continue }
            // Size -> three samples -> full SHA-256. Full reads are reserved for files
            // whose beginning, middle, and end all match.
            var sampleBuckets: [String: [DuplicateCandidate]] = [:]
            for candidate in candidates {
                let sig = sampleContentSignature(candidate.url, size: size)
                sampleBuckets[sig, default: []].append(candidate)
            }
            var exactBuckets: [String: [DuplicateCandidate]] = [:]
            for sampled in sampleBuckets.values where sampled.count > 1 {
                for candidate in sampled {
                    let sig = contentSignature(candidate.url, size: size)
                    exactBuckets[sig, default: []].append(candidate)
                }
            }
            for (_, twins) in exactBuckets where twins.count > 1 {
                // Prefer a stable Documents/Desktop copy over a downloaded one, then the
                // oldest shallow path. Nothing is preselected: the final choice is human.
                let sorted = twins.sorted(by: duplicateKeeperOrder)
                let keeper = sorted[0]
                let contentPopulations = Dictionary(
                    grouping: sorted.compactMap { candidate -> (Int64, FileStorageFacts.InodeKey)? in
                        guard let id = candidate.facts.contentIdentifier,
                              candidate.facts.mayShareFileContent else { return nil }
                        return (id, candidate.facts.inodeKey)
                    },
                    by: { $0.0 }
                ).mapValues { Set($0.map { $0.1 }).count }

                for (i, candidate) in sorted.enumerated() where i > 0 {
                    group += 1
                    let url = candidate.url
                    let name = url.lastPathComponent
                    let sameInodeAsKeeper = candidate.facts.inodeKey == keeper.facts.inodeKey
                    let clonePopulation = candidate.facts.contentIdentifier
                        .flatMap { contentPopulations[$0] } ?? 1
                    // mayShare=true means this content stream participates in APFS
                    // cloning even when its sibling is outside our user-folder roots.
                    let isFullClone = candidate.facts.mayShareFileContent
                        && candidate.facts.contentIdentifier != nil
                    let reclaimable = candidate.facts.conservativeReclaimableBytes(
                        contentIdentifierPopulation: clonePopulation
                    )
                    let idPrefix = sameInodeAsKeeper || candidate.facts.isHardLinked
                        ? "dup-hardlink-"
                        : (isFullClone ? "dup-clone-" : "dup-")
                    let kind: CleanKind = idPrefix == "dup-hardlink-" || isFullClone
                        ? .advice
                        : .deleteItem
                    let subtitle: Line
                    if idPrefix == "dup-hardlink-" {
                        subtitle = Line(
                            ru: "Не вторая копия, а ещё одно имя того же файла · освобождение 0 Б · оставляем без удаления",
                            en: "Another name for the same file, not a second copy · frees 0 B · left untouched"
                        )
                    } else if isFullClone {
                        subtitle = Line(
                            ru: "Точный APFS-клон · оставить: \(PathFormat.tilde(keeper.url)) · удаление уберёт файл, но может освободить 0 Б",
                            en: "Exact APFS clone · keep: \(PathFormat.tilde(keeper.url)) · removal deletes the file but may free 0 B"
                        )
                    } else {
                        subtitle = Line(
                            ru: "Точная копия · оставить: \(PathFormat.tilde(keeper.url)) · освободится около \(ByteFormat.string(reclaimable, .ru))",
                            en: "Exact copy · keep: \(PathFormat.tilde(keeper.url)) · about \(ByteFormat.string(reclaimable, .en)) reclaimed"
                        )
                    }
                    items.append(JunkItem(
                        id: "\(idPrefix)\(group)-\(stablePathKey(url))",
                        module: .duplicates,
                        title: Line.proper(name),
                        subtitle: subtitle,
                        url: url,
                        bytes: reclaimable,
                        selected: false,
                        kind: kind,
                        keepsLogins: false
                    ))
                }
            }
            if items.count > 260 { break }
        }
        items.sort { $0.bytes > $1.bytes }
        ContentFingerprinter.flush()
        return Gathered(items: Array(items.prefix(240)), failed: failed)
    }

    static func duplicatesForQA(
        roots: [URL],
        minimumLogicalBytes: Int64 = 1
    ) -> [JunkItem] {
        duplicates(in: roots, minimumLogicalBytes: minimumLogicalBytes).items
    }

    private static func duplicateKeeperOrder(
        _ lhs: DuplicateCandidate,
        _ rhs: DuplicateCandidate
    ) -> Bool {
        func rank(_ url: URL) -> Int {
            let path = url.standardizedFileURL.path
            if path.contains("/Documents/") { return 0 }
            if path.contains("/Desktop/") { return 1 }
            if path.contains("/Downloads/") { return 3 }
            return 2
        }
        let leftRank = rank(lhs.url)
        let rightRank = rank(rhs.url)
        if leftRank != rightRank { return leftRank < rightRank }
        if lhs.url.pathComponents.count != rhs.url.pathComponents.count {
            return lhs.url.pathComponents.count < rhs.url.pathComponents.count
        }
        if lhs.modified != rhs.modified { return lhs.modified < rhs.modified }
        return lhs.url.path.localizedStandardCompare(rhs.url.path) == .orderedAscending
    }

    private static func stablePathKey(_ url: URL) -> String {
        SHA256.hash(data: Data(url.standardizedFileURL.path.utf8))
            .prefix(10)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    /// Exact content fingerprint. Size pre-grouping keeps this affordable; hashing the full
    /// file prevents same-size files with identical headers/footers from being misclassified.
    static func contentSignature(_ url: URL, size: Int64) -> String {
        ContentFingerprinter.fullSignature(url, expectedSize: size)
            ?? "\(size):unreadable:\(url.standardizedFileURL.path)"
    }

    private static func sampleContentSignature(_ url: URL, size: Int64) -> String {
        ContentFingerprinter.sampleSignature(url, expectedSize: size)
            ?? "\(size):unreadable:\(url.standardizedFileURL.path)"
    }

    private static func leftovers() -> Gathered {
        let fm = FileManager.default
        let apps = installedAppNames()
        let support = home().appendingPathComponent("Library/Application Support")
        var isDir: ObjCBool = false
        let supportExists = fm.fileExists(atPath: support.path, isDirectory: &isDir) && isDir.boolValue
        guard let names = try? fm.contentsOfDirectory(at: support, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return Gathered(items: [], failed: supportExists)
        }
        var out: [JunkItem] = []
        for url in names {
            let name = url.lastPathComponent
            if leftoverHasOwner(name, apps: apps) { continue }
            if name.lowercased().hasPrefix("com.apple") { continue }
            // Apple / iCloud support folders that are not an "uninstalled app".
            let systemSupport = Set([
                "CloudDocs", "FileProvider", "Knowledge", "iCloud",
                "CallHistoryTransactions", "CallHistoryDB", "CrashReporter",
                "SyncServices", "AddressBook", "DiskImages", "ControlCenter"
            ])
            if systemSupport.contains(name) { continue }
            if Keep.isProtected(url) { continue }
            let b = DiskSizer.bytes(at: url)
            guard b > 8_388_608 else { continue }
            out.append(JunkItem(id: "left-\(name)", module: .leftovers, title: Line.proper(name), subtitle: Copy.leftoverGone, url: url, bytes: b, selected: false, kind: .wipeChildren, keepsLogins: false))
        }
        out.append(contentsOf: DeepScan.leftoverExtras())
        let filtered = dedupeByURL(out).filter { !Keep.isDismissed($0.id) }.sorted { $0.bytes > $1.bytes }
        return Gathered(items: filtered, failed: false)
    }

    /// Skip leftovers that belong to an installed app — names from this Mac, not a fixed machine list.
    private static func leftoverHasOwner(_ folder: String, apps: [String]) -> Bool {
        let always = Set(["Apple", "com.apple", "CleanAlephaMac98", "Codex", "com.openai.chat", "ChatGPT"])
        if always.contains(folder) { return true }
        let lower = folder.lowercased()
        if lower.contains("openai"), apps.contains(where: {
            $0.localizedCaseInsensitiveContains("ChatGPT") || $0.localizedCaseInsensitiveContains("Codex")
        }) { return true }
        if lower.contains("anthropic"), apps.contains(where: { $0.localizedCaseInsensitiveContains("Claude") }) {
            return true
        }
        if apps.contains(where: { $0.localizedCaseInsensitiveContains(folder) || folder.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let aliases: [String: [String]] = [
            "Google": ["Google Chrome", "Chrome", "Google"],
            "Cursor": ["Cursor"],
            "Claude": ["Claude"],
            "com.openai.chat": ["ChatGPT", "OpenAI"],
            "Telegram Desktop": ["Telegram"],
            "Figma": ["Figma"],
            "Code": ["Visual Studio Code", "Code"],
            "zoom.us": ["zoom.us", "Zoom"],
            "Chromium": ["Chromium"],
            "Microsoft Edge": ["Microsoft Edge", "Edge"],
            "BraveSoftware": ["Brave Browser", "Brave"],
            "adspower_global": ["AdsPower", "adspower"],
            "dolphin_anty": ["dolphin_anty", "Dolphin{anty}"],
            "Yandex": ["Yandex"]
        ]
        if let names = aliases[folder] {
            return names.contains { alias in
                apps.contains { $0.localizedCaseInsensitiveContains(alias) }
            }
        }
        return false
    }

    private static func installedAppNames() -> [String] {
        var names: [String] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if let xs = try? FileManager.default.contentsOfDirectory(atPath: root) {
                names += xs.map { $0.replacingOccurrences(of: ".app", with: "") }
            }
        }
        return names
    }

    private struct LargeCandidate {
        let url: URL
        let facts: FileStorageFacts
        let modified: Date
    }

    private static func largeFiles() -> Gathered {
        let roots = [
            "Downloads", "Desktop", "Movies", "Documents", "Pictures", "Music"
        ].map { home().appendingPathComponent($0) }
        var candidates: [LargeCandidate] = []
        var failed = false
        let skip = Set(["Personal", "Education", "Work", "STEM", "Safari", "CloudDocs", "Photos"])
        let sessionAdjacent = Set([
            "Network", "Session Storage", "Sessions", "Local Storage", "LocalStorage",
            "IndexedDB", "WebStorage", "Service Worker", "Accounts", "accounts",
            "History", "History-journal", "postbox", "tdata", "user_data"
        ])
        let cutoffOld = Date().addingTimeInterval(-90 * 24 * 3600)
        for root in roots {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
            guard exists else { continue }
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: Array(FileStorageFacts.resourceKeys)
                    + [.contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                if isDir.boolValue { failed = true }
                continue
            }
            var depthGuard = 0
            let deepRoot = root.path.contains("/Library/")
            let limit = deepRoot ? 8_000 : 14_000
            for case let url as URL in en {
                depthGuard += 1
                if depthGuard > limit { break }
                if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                if sessionAdjacent.contains(url.lastPathComponent) || Keep.names.contains(url.lastPathComponent) {
                    en.skipDescendants()
                    continue
                }
                if Keep.isProtected(url) { en.skipDescendants(); continue }
                if ["node_modules", ".git", ".colima", "DerivedData", "CoreSimulator", "iOS DeviceSupport"].contains(url.lastPathComponent) {
                    en.skipDescendants()
                    continue
                }
                guard let facts = FileStorageFacts.read(url), !facts.isCloudPlaceholder else { continue }
                let sz = facts.logicalBytes
                let minSize: Int64 = deepRoot ? 120_000_000 : 50_000_000
                guard sz >= minSize else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                candidates.append(LargeCandidate(url: url, facts: facts, modified: modified))
            }
        }

        let contentPopulations = Dictionary(
            grouping: candidates.compactMap { candidate -> (Int64, FileStorageFacts.InodeKey)? in
                guard let id = candidate.facts.contentIdentifier,
                      candidate.facts.mayShareFileContent else { return nil }
                return (id, candidate.facts.inodeKey)
            },
            by: { $0.0 }
        ).mapValues { Set($0.map { $0.1 }).count }

        let found: [JunkItem] = candidates.map { candidate in
                let url = candidate.url
                let facts = candidate.facts
                let modified = candidate.modified
                let old = modified < cutoffOld
                let ageDays = max(0, Int(Date().timeIntervalSince(modified) / 86_400))
                let kindLabel: String = {
                    switch url.pathExtension.lowercased() {
                    case "mov", "mp4", "mkv", "m4v": return Copy.largeKindVideo.t(.ru)
                    case "zip", "dmg", "iso", "gz", "rar", "7z": return Copy.largeKindArchive.t(.ru)
                    case "psd", "ai", "sketch": return Copy.largeKindDesign.t(.ru)
                    default: return Copy.largeKindFile.t(.ru)
                    }
                }()
                let kindLabelEn: String = {
                    switch url.pathExtension.lowercased() {
                    case "mov", "mp4", "mkv", "m4v": return Copy.largeKindVideo.t(.en)
                    case "zip", "dmg", "iso", "gz", "rar", "7z": return Copy.largeKindArchive.t(.en)
                    case "psd", "ai", "sketch": return Copy.largeKindDesign.t(.en)
                    default: return Copy.largeKindFile.t(.en)
                    }
                }()
                let clonePopulation = facts.contentIdentifier.flatMap { contentPopulations[$0] } ?? 1
                let reclaimable = facts.conservativeReclaimableBytes(
                    contentIdentifierPopulation: clonePopulation
                )
                let storageRU: String
                let storageEN: String
                if facts.isHardLinked {
                    storageRU = "hard link · удаление одного имени может освободить 0 Б"
                    storageEN = "hard link · removing one name may reclaim 0 B"
                } else if facts.mayShareFileContent && clonePopulation > 1 {
                    storageRU = "APFS-клон · отдельная копия может занимать 0 Б"
                    storageEN = "APFS clone · this separate copy may use 0 B"
                } else if facts.isSparse || facts.allocatedBytes + 1_048_576 < facts.logicalBytes {
                    storageRU = "на диске \(ByteFormat.string(facts.allocatedBytes, .ru)) из \(ByteFormat.string(facts.logicalBytes, .ru))"
                    storageEN = "\(ByteFormat.string(facts.allocatedBytes, .en)) on disk of \(ByteFormat.string(facts.logicalBytes, .en)) logical"
                } else {
                    storageRU = "на диске \(ByteFormat.string(reclaimable, .ru))"
                    storageEN = "\(ByteFormat.string(reclaimable, .en)) on disk"
                }
                let sub = Line(
                    ru: (old
                        ? "\(kindLabel) · \(ageDays) дн. · \(PathFormat.tilde(url.deletingLastPathComponent()))"
                        : "\(kindLabel) · \(PathFormat.tilde(url.deletingLastPathComponent()))")
                        + " · \(storageRU)",
                    en: (old
                        ? "\(kindLabelEn) · \(ageDays)d · \(PathFormat.tilde(url.deletingLastPathComponent()))"
                        : "\(kindLabelEn) · \(PathFormat.tilde(url.deletingLastPathComponent()))")
                        + " · \(storageEN)"
                )
                let isSharedStorage = facts.isHardLinked || facts.mayShareFileContent
                return JunkItem(
                    id: "\(isSharedStorage ? "large-shared-" : "large-")\(stablePathKey(url))",
                    module: .large,
                    title: Line.proper(url.lastPathComponent),
                    subtitle: sub,
                    url: url,
                    bytes: reclaimable,
                    selected: false,
                    kind: isSharedStorage ? .advice : .deleteItem,
                    keepsLogins: false
                )
        }
        let items = found
            .filter { !Keep.isDismissed($0.id) }
            .sorted { $0.bytes > $1.bytes }
        return Gathered(items: Array(items.prefix(120)), failed: failed)
    }

    private static func browsers() -> [JunkItem] {
        var rows: [JunkItem] = []
        if let x = item("chrome-cache", .browsers, Line(ru: "Chrome – диск-кэш", en: "Chrome disk cache"), Line(ru: "Куки и пароли на месте", en: "Cookies and passwords stay"), "Library/Caches/Google/Chrome", keeps: true) {
            rows.append(x)
        }
        if let x = item("safari-cache", .browsers, Line(ru: "Safari – локальный кэш", en: "Safari local cache"), Line(ru: "Сессии на месте", en: "Sessions stay"), "Library/Caches/com.apple.Safari", keeps: true) {
            rows.append(x)
        }
        let store = home().appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/WebKit/WebsiteDataStore")
        let cacheNames = ["NetworkCache", "CacheStorage", "MediaCache"]
        var safariBytes: Int64 = 0
        if let kids = try? FileManager.default.contentsOfDirectory(at: store, includingPropertiesForKeys: nil) {
            for kid in kids {
                if cacheNames.contains(kid.lastPathComponent) {
                    safariBytes += DiskSizer.bytes(at: kid)
                } else {
                    for n in cacheNames {
                        safariBytes += DiskSizer.bytes(at: kid.appendingPathComponent(n))
                    }
                }
            }
        }
        if safariBytes > 0 {
            rows.append(JunkItem(id: "safari-net", module: .browsers, title: Line(ru: "Safari – сетевой кэш", en: "Safari network cache"), subtitle: Line(ru: "Логины целы", en: "Logins stay"), url: store, bytes: safariBytes, selected: true, kind: .safariNetworkCache, keepsLogins: true))
        }

        rows.append(contentsOf: chromiumProfileCaches(
            brand: "Chrome",
            root: home().appendingPathComponent("Library/Application Support/Google/Chrome")
        ))
        rows.append(contentsOf: chromiumProfileCaches(
            brand: "Chromium",
            root: home().appendingPathComponent("Library/Application Support/Chromium")
        ))
        rows.append(contentsOf: chromiumProfileCaches(
            brand: "Edge",
            root: home().appendingPathComponent("Library/Application Support/Microsoft Edge")
        ))
        rows.append(contentsOf: antidetectCaches(
            brand: "AdsPower",
            root: home().appendingPathComponent("Library/Application Support/adspower_global")
        ))
        rows.append(contentsOf: antidetectCaches(
            brand: "Dolphin",
            root: home().appendingPathComponent("Library/Application Support/dolphin_anty")
        ))
        rows.append(contentsOf: chromiumProfileCaches(
            brand: "Brave",
            root: home().appendingPathComponent("Library/Application Support/BraveSoftware/Brave-Browser")
        ))
        rows.append(contentsOf: chromiumProfileCaches(
            brand: "Yandex",
            root: home().appendingPathComponent("Library/Application Support/Yandex/YandexBrowser")
        ))
        rows.append(contentsOf: firefoxCaches())

        return dedupeByURL(rows).sorted { $0.bytes > $1.bytes }
    }

    private static func firefoxCaches() -> [JunkItem] {
        let root = home().appendingPathComponent("Library/Caches/Firefox/Profiles")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [JunkItem] = []
        for profile in kids {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: profile.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let pname = profile.lastPathComponent
            for cacheName in ["cache2", "startupCache", "thumbnails"] {
                let url = profile.appendingPathComponent(cacheName)
                if let item = folderItem(
                    id: "b-Firefox-\(pname)-\(cacheName)",
                    module: .browsers,
                    title: Line(ru: "Firefox – \(cacheName)", en: "Firefox – \(cacheName)"),
                    subtitle: Line(ru: "\(pname) · логины целы", en: "\(pname) · logins stay"),
                    url: url,
                    selected: true,
                    keeps: true
                ) {
                    out.append(item)
                }
            }
        }
        return out
    }

    /// Profile folders like Default / Profile 1 — only cache subdirs, never whole Support.
    private static func chromiumProfileCaches(brand: String, root: URL) -> [JunkItem] {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var out: [JunkItem] = []
        for profile in kids {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: profile.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let pname = profile.lastPathComponent
            let looksLikeProfile = pname == "Default"
                || pname.hasPrefix("Profile ")
                || pname.hasPrefix("Profile")
                || pname == "Guest Profile"
                || pname.hasPrefix("System Profile")
            if !looksLikeProfile { continue }
            for cacheName in profileCacheNames {
                let url = profile.appendingPathComponent(cacheName)
                guard let item = folderItem(
                    id: "b-\(brand)-\(pname)-\(cacheName)",
                    module: .browsers,
                    title: Line(ru: "\(brand) – \(cacheName)", en: "\(brand) – \(cacheName)"),
                    subtitle: Line(ru: "\(pname) · логины целы", en: "\(pname) · logins stay"),
                    url: url,
                    selected: true,
                    keeps: true
                ) else { continue }
                out.append(item)
            }
            for cacheName in serviceWorkerCacheNames {
                let url = profile.appendingPathComponent("Service Worker/\(cacheName)")
                guard let item = folderItem(
                    id: "b-\(brand)-\(pname)-ServiceWorker-\(cacheName)",
                    module: .browsers,
                    title: Line(ru: "\(brand) – Service Worker · \(cacheName)", en: "\(brand) – Service Worker · \(cacheName)"),
                    subtitle: Line(ru: "\(pname) · база сессий цела", en: "\(pname) · session database stays"),
                    url: url,
                    selected: true,
                    keeps: true
                ) else { continue }
                out.append(item)
            }
        }
        // Shared shader caches at Chrome root (not profile)
        for cacheName in ["ShaderCache", "GrShaderCache"] {
            let url = root.appendingPathComponent(cacheName)
            if let item = folderItem(
                id: "b-\(brand)-root-\(cacheName)",
                module: .browsers,
                title: Line(ru: "\(brand) – \(cacheName)", en: "\(brand) – \(cacheName)"),
                subtitle: Copy.loginsBadge,
                url: url,
                selected: true,
                keeps: true
            ) {
                out.append(item)
            }
        }
        return out
    }

    /// AdsPower / dolphin — only Cache / Code Cache / GPUCache / Service Worker trees.
    private static func antidetectCaches(brand: String, root: URL) -> [JunkItem] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [JunkItem] = []
        var seen = 0
        for case let url as URL in en {
            seen += 1
            if seen > 4_000 { break }
            let name = url.lastPathComponent
            guard profileCacheNames.contains(name) else { continue }
            // Only shallow-ish cache dirs (avoid walking into every blob inside)
            en.skipDescendants()
            guard let item = folderItem(
                id: "b-\(brand)-\(url.path.hashValue)",
                module: .browsers,
                title: Line(ru: "\(brand) – \(name)", en: "\(brand) – \(name)"),
                subtitle: Line(ru: "Только кэш профиля", en: "Profile cache only"),
                url: url,
                selected: true,
                keeps: true
            ) else { continue }
            out.append(item)
        }
        return out
    }

    private static func dev() -> [JunkItem] {
        var rows: [JunkItem] = [
            item("derived", .dev, Line.proper("Xcode DerivedData"), Line(ru: "Симулятор и DeviceSupport — отдельно, выкл.", en: "Simulator / DeviceSupport listed separately, off"), "Library/Developer/Xcode/DerivedData"),
            item("npm", .dev, Line.proper("npm cache"), Line.proper("_cacache"), ".npm/_cacache"),
            item("npx", .dev, Line.proper("npx cache"), Line.proper("_npx"), ".npm/_npx"),
            item("go-build", .dev, Line.proper("Go build cache"), Line.proper("go-build"), "Library/Caches/go-build"),
            item("swiftpm", .dev, Line.proper("SwiftPM cache"), Line.proper("org.swift.swiftpm"), "Library/Caches/org.swift.swiftpm"),
            item("pnpm", .dev, Line.proper("pnpm cache"), Line.proper("Library/Caches/pnpm"), "Library/Caches/pnpm")
        ].compactMap { $0 }
        rows.append(contentsOf: DeepScan.devExtras())
        return dedupeByURL(rows).filter { !Keep.isDismissed($0.id) }.sorted { $0.bytes > $1.bytes }
    }

    private static func messengers() -> [JunkItem] {
        var rows: [JunkItem] = []
        for account in telegramAccounts() {
            let acc = account.lastPathComponent
            if let x = messengerFolder(
                id: "tg-m-\(account.path.hashValue)",
                title: Line(ru: "Telegram медиа", en: "Telegram media"),
                subtitle: Line.proper(acc),
                url: account.appendingPathComponent("postbox/media"),
                selected: true,
                keepsLogins: true
            ) {
                rows.append(x)
            }
            if let x = messengerFolder(
                id: "tg-d-\(account.path.hashValue)",
                title: Line(ru: "Telegram история", en: "Telegram history"),
                subtitle: Line(ru: "Локальная база, по умолчанию выкл", en: "Local database, off by default"),
                url: account.appendingPathComponent("postbox/db"),
                selected: false
            ) {
                rows.append(x)
            }
        }
        if let x = item("msg", .messengers, Line(ru: "Вложения Сообщений", en: "Messages attachments"), Line(ru: "Без полного доступа почти ничего не видно", en: "Needs Full Disk Access or you'll see almost nothing"), "Library/Messages/Attachments", selected: false) {
            rows.append(x)
        }
        // `tdata/user_data` is not a cache boundary. Wiping it whole has logged users out
        // on some Telegram Desktop versions. Official Telegram paths put disposable bytes
        // only in these children; key_data(s), settings and the account map stay untouched.
        for userData in telegramDesktopUserDataRoots() {
            for leaf in ["cache", "media_cache"] {
                if let x = messengerFolder(
                    id: "tgdesk-\(leaf)-\(userData.lastPathComponent)",
                    title: Line(
                        ru: leaf == "cache" ? "Telegram Desktop кэш" : "Telegram Desktop медиа-кэш",
                        en: leaf == "cache" ? "Telegram Desktop cache" : "Telegram Desktop media cache"
                    ),
                    subtitle: Line(
                        ru: "Только tdata/\(userData.lastPathComponent)/\(leaf) · ключи входа не затрагиваются",
                        en: "Only tdata/\(userData.lastPathComponent)/\(leaf) · login keys stay untouched"
                    ),
                    url: userData.appendingPathComponent(leaf),
                    selected: true,
                    keepsLogins: true
                ) {
                    rows.append(x)
                }
            }
        }
        return rows
    }

    private static func messengerFolder(
        id: String,
        title: Line,
        subtitle: Line,
        url: URL,
        selected: Bool,
        keepsLogins: Bool = false
    ) -> JunkItem? {
        let explicitTelegramCache = id.hasPrefix("tgdesk-cache-") || id.hasPrefix("tgdesk-media_cache-")
            ? Keep.isTelegramDesktopCache(url) : false
        if Keep.isExtraProtected(url) { return nil }
        if Keep.isProtected(url), !explicitTelegramCache { return nil }
        let b = explicitTelegramCache
            ? (DiskSizer.duSK(url, timeout: 4) ?? 0)
            : DiskSizer.bytes(at: url)
        guard b > 16_384 else { return nil }
        return JunkItem(
            id: id,
            module: .messengers,
            title: title,
            subtitle: subtitle,
            url: url,
            bytes: b,
            selected: selected,
            kind: .wipeChildren,
            keepsLogins: keepsLogins
        )
    }

    private static func telegramDesktopUserDataRoots() -> [URL] {
        let fm = FileManager.default
        let tdata = home().appendingPathComponent("Library/Application Support/Telegram Desktop/tdata")
        guard let children = try? fm.contentsOfDirectory(
            at: tdata,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        return children.filter { url in
            let name = url.lastPathComponent
            let validName = name == "user_data"
                || (name.hasPrefix("user_data#")
                    && !name.dropFirst("user_data#".count).isEmpty
                    && name.dropFirst("user_data#".count).allSatisfy(\.isNumber))
            guard validName,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Any Telegram on this Mac: keepcoder, Desktop, whatever lives under Group Containers.
    private static func telegramAccounts() -> [URL] {
        let fm = FileManager.default
        let gc = home().appendingPathComponent("Library/Group Containers")
        guard let kids = try? fm.contentsOfDirectory(
            at: gc,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var accounts: [URL] = []
        var seen = Set<String>()
        for container in kids {
            let n = container.lastPathComponent.lowercased()
            guard n.contains("telegram") || n.contains("keepcoder") else { continue }
            for account in telegramAccounts(in: container, depth: 0) {
                let key = account.standardizedFileURL.path
                if seen.contains(key) { continue }
                seen.insert(key)
                accounts.append(account)
            }
        }
        return accounts.sorted { $0.path < $1.path }
    }

    private static func telegramAccounts(in url: URL, depth: Int) -> [URL] {
        if depth > 3 { return [] }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return [] }
        if url.lastPathComponent.hasPrefix("account-") { return [url] }
        guard let kids = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var found: [URL] = []
        for kid in kids {
            found.append(contentsOf: telegramAccounts(in: kid, depth: depth + 1))
        }
        return found
    }

    private static func dedupeByURL(_ items: [JunkItem]) -> [JunkItem] {
        var seen = Set<String>()
        var out: [JunkItem] = []
        for item in items {
            let path = item.url.standardizedFileURL.path
            let key: String
            if item.kind == .advice || item.kind == .deleteCaptureRemnants {
                key = "\(item.id)|\(path)"
            } else {
                key = path
            }
            if seen.contains(key) { continue }
            seen.insert(key)
            out.append(item)
        }
        return out
    }

    static func volume() -> (total: Int64, used: Int64, free: Int64) {
        let url = URL(fileURLWithPath: "/System/Volumes/Data")
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let rv = try? url.resourceValues(forKeys: keys),
              let total = rv.volumeTotalCapacity,
              let free = rv.volumeAvailableCapacityForImportantUsage,
              total > 0 else {
            return (0, 0, 0)
        }
        let total64 = Int64(total)
        let free64 = min(max(0, Int64(free)), total64)
        return (total64, total64 - free64, free64)
    }

    /// Best-effort size of protected folders for the disk ring. May undercount if du times out.
    static func protectedBytes() -> Int64 {
        let start = Date()
        var total: Int64 = 0
        for url in Keep.protectedRoots() {
            if Date().timeIntervalSince(start) > 8 { break }
            if let n = DiskSizer.duSK(url, timeout: 2.2), n > 0 {
                total += n
            }
        }
        return total
    }
}
