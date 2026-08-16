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
        "Cache", "Code Cache", "GPUCache", "Service Worker", "DawnCache", "ShaderCache", "GrShaderCache"
    ]

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
        func items() -> [JunkItem] {
            switch self {
            case .junk: Scanner.junk()
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
    static func safeItems(for stage: ScanStage) -> StageChunk {
        ScanThrottle.beginWorker()
        return autoreleasepool {
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
                raw = stage.items()
            }
            ScanThrottle.reliefIfNeeded()
            // Trash: any non-empty bin counts (even small). Others keep the 16KB floor.
            let minBytes: Int64 = stage == .trash ? 1 : 16_384
            return StageChunk(
                items: raw.filter { item in
                    guard item.bytes > minBytes else { return false }
                    if Keep.isDismissed(item.id) { return false }
                    if Keep.allowsExplicitCard(item) { return true }
                    return !Keep.isProtected(item.url)
                },
                failed: failed
            )
        }
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
        keeps: Bool = false
    ) -> JunkItem? {
        if Keep.isProtected(url) { return nil }
        let b = DiskSizer.bytes(at: url)
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

    static func junk() -> [JunkItem] {
        var rows: [JunkItem] = []
        let fixed: [(String, Line, String, Line)] = [
            ("logs", Line(ru: "Логи пользователя", en: "User logs"), "Library/Logs", Line(ru: "Диагностика, крэши, болтливые агенты", en: "Diagnostics, crashes, chatty agents")),
            ("crash", Line(ru: "Отчёты о падениях", en: "Crash reports"), "Library/Application Support/CrashReporter", Line(ru: "Старые CrashReporter", en: "Old CrashReporter files")),
            ("state", Line(ru: "Снимки окон", en: "Window snapshots"), "Library/Saved Application State", Line(ru: "Пересоздаются при открытии", en: "Recreated when you reopen")),
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
        rows.append(contentsOf: fixed.compactMap { entry in
            let selected = entry.0 != "cloudkit-cache"
            return item(entry.0, .junk, entry.1, entry.3, entry.2, selected: selected)
        })
        rows.append(contentsOf: enumeratedUserCaches())
        rows.append(contentsOf: enumeratedDotCache())
        rows.append(contentsOf: enumeratedContainerCaches())
        rows.append(contentsOf: enumeratedAppSupportCaches())
        rows.append(contentsOf: DeepScan.junkExtras())
        rows.append(contentsOf: oldInstallers())
        return dedupeByURL(rows).filter { !Keep.isDismissed($0.id) }.sorted { $0.bytes > $1.bytes }
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
        var out: [JunkItem] = []
        var n = 0
        for container in kids {
            ScanThrottle.tickSync(every: 20, counter: &n)
            let id = container.lastPathComponent
            if containerCacheDeny.contains(id) { continue }
            if id.lowercased().contains("photo") { continue }
            if id.lowercased().contains("icloud") { continue }
            let cache = container.appendingPathComponent("Data/Library/Caches")
            if Keep.isProtected(cache) { continue }
            guard let item = folderItem(
                id: "ccache-\(id)",
                module: .junk,
                title: Line(ru: "Кэш \(shortBundle(id))", en: "Cache \(shortBundle(id))"),
                subtitle: Line(ru: "Container cache", en: "Container cache"),
                url: cache,
                selected: !id.hasPrefix("com.apple."),
                kind: .wipeChildren
            ) else { continue }
            out.append(item)
        }
        return out
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
                    selected: true
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
                selected: true
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
        let kids = (try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil,
            options: []
        )) ?? []
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

    /// Duplicate files (same size + same sample hash) in Desktop / Documents / Downloads.
    private static func duplicates() -> Gathered {
        let roots = [
            home().appendingPathComponent("Desktop"),
            home().appendingPathComponent("Documents"),
            home().appendingPathComponent("Downloads")
        ]
        let fm = FileManager.default
        var bySize: [Int64: [URL]] = [:]
        var failed = false
        let minFile: Int64 = 1_048_576 // 1 MB – skip tiny noise
        for root in roots {
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isDirectoryKey],
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
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                      rv.isRegularFile == true,
                      let size = rv.fileSize,
                      Int64(size) >= minFile else { continue }
                bySize[Int64(size), default: []].append(url)
            }
        }

        var items: [JunkItem] = []
        var group = 0
        for (size, urls) in bySize where urls.count > 1 {
            var buckets: [String: [URL]] = [:]
            for url in urls {
                let sig = fileSignature(url, size: size)
                buckets[sig, default: []].append(url)
            }
            for (_, twins) in buckets where twins.count > 1 {
                // Keep the oldest path selected=false for all; user picks. Mark all but first as deletable extras.
                let sorted = twins.sorted { $0.path < $1.path }
                for (i, url) in sorted.enumerated() where i > 0 {
                    group += 1
                    let name = url.lastPathComponent
                    items.append(JunkItem(
                        id: "dup-\(group)-\(url.path.hashValue)",
                        module: .duplicates,
                        title: Line.proper(name),
                        subtitle: Line(
                            ru: "\(Copy.dupKeepOne.ru) \(ByteFormat.string(size, .ru))",
                            en: "\(Copy.dupKeepOne.en) \(ByteFormat.string(size, .en))"
                        ),
                        url: url,
                        bytes: size,
                        selected: false,
                        kind: .deleteItem,
                        keepsLogins: false
                    ))
                }
            }
            if items.count > 80 { break }
        }
        items.sort { $0.bytes > $1.bytes }
        return Gathered(items: Array(items.prefix(60)), failed: failed)
    }

    /// Fast fingerprint: size + prefix/suffix bytes (not cryptographic; enough for cleanup).
    private static func fileSignature(_ url: URL, size: Int64) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "\(size):\(url.path)" }
        defer { try? fh.close() }
        let head = (try? fh.read(upToCount: 64 * 1024)) ?? Data()
        var tail = Data()
        if size > 128 * 1024 {
            try? fh.seek(toOffset: UInt64(size - 64 * 1024))
            tail = (try? fh.read(upToCount: 64 * 1024)) ?? Data()
        }
        var hasher = Hasher()
        hasher.combine(size)
        hasher.combine(head)
        hasher.combine(tail)
        return "\(size):\(hasher.finalize())"
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
        let always = Set(["Apple", "com.apple", "CleanAlephaMac98"])
        if always.contains(folder) { return true }
        if apps.contains(where: { $0.localizedCaseInsensitiveContains(folder) || folder.localizedCaseInsensitiveContains($0) }) {
            return true
        }
        let aliases: [String: [String]] = [
            "Google": ["Google Chrome", "Chrome", "Google"],
            "Cursor": ["Cursor"],
            "Claude": ["Claude"],
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

    private static func largeFiles() -> Gathered {
        let roots = [
            "Downloads", "Desktop", "Movies", "Documents",
            "Library/Application Support", "Library/Containers"
        ].map { home().appendingPathComponent($0) }
        var found: [JunkItem] = []
        var failed = false
        let skip = Set(["Personal", "Education", "Work", "STEM", "Safari", "CloudDocs", "Photos"])
        let cutoffOld = Date().addingTimeInterval(-90 * 24 * 3600)
        for root in roots {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
            guard exists else { continue }
            guard let en = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
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
                if Keep.isProtected(url) { en.skipDescendants(); continue }
                if ["node_modules", ".git", ".colima", "DerivedData", "CoreSimulator", "iOS DeviceSupport"].contains(url.lastPathComponent) {
                    en.skipDescendants()
                    continue
                }
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      rv.isRegularFile == true else { continue }
                let sz = Int64(rv.fileSize ?? 0)
                let minSize: Int64 = deepRoot ? 120_000_000 : 50_000_000
                guard sz >= minSize else { continue }
                let modified = rv.contentModificationDate ?? .distantPast
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
                let sub = Line(
                    ru: old
                        ? "\(kindLabel) · \(ageDays) дн. · \(PathFormat.tilde(url.deletingLastPathComponent()))"
                        : "\(kindLabel) · \(PathFormat.tilde(url.deletingLastPathComponent()))",
                    en: old
                        ? "\(kindLabelEn) · \(ageDays)d · \(PathFormat.tilde(url.deletingLastPathComponent()))"
                        : "\(kindLabelEn) · \(PathFormat.tilde(url.deletingLastPathComponent()))"
                )
                found.append(JunkItem(
                    id: "large-\(url.path.hashValue)",
                    module: .large,
                    title: Line.proper(url.lastPathComponent),
                    subtitle: sub,
                    url: url,
                    bytes: sz,
                    selected: false,
                    kind: .deleteItem,
                    keepsLogins: false
                ))
            }
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
                selected: true
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
        if let x = item("tgdesk", .messengers, Line.proper("Telegram Desktop cache"), Line.proper("tdata/user_data"), "Library/Application Support/Telegram Desktop/tdata/user_data") {
            rows.append(x)
        }
        return rows
    }

    private static func messengerFolder(id: String, title: Line, subtitle: Line, url: URL, selected: Bool) -> JunkItem? {
        if Keep.isProtected(url) { return nil }
        let b = DiskSizer.bytes(at: url)
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
            keepsLogins: false
        )
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
            let key = item.url.standardizedFileURL.path
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
