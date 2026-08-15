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

    private static let minCacheBytes: Int64 = 8_388_608

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
        "GeoServices"
    ]

    /// Already covered by named junk / browser / dev cards — skip duplicate enum ids.
    private static let cachesCoveredElsewhere: Set<String> = [
        "Homebrew", "CocoaPods", "pip", "ms-playwright", "go-build",
        "org.swift.swiftpm", "pnpm", "Google", "com.apple.Safari", "com.apple.helpd", "GeoServices"
    ]

    enum ScanStage: Int, CaseIterable, Sendable {
        case junk, mail, trash, leftovers, large, browsers, dev, messengers
        func items() -> [JunkItem] {
            switch self {
            case .junk: Scanner.junk()
            case .mail: Scanner.mail()
            case .trash: Scanner.trash()
            case .leftovers: Scanner.leftovers().items
            case .large: Scanner.largeFiles().items
            case .browsers: Scanner.browsers()
            case .dev: Scanner.dev()
            case .messengers: Scanner.messengers()
            }
        }

        var module: Module {
            switch self {
            case .junk: .junk
            case .mail: .mail
            case .trash: .trash
            case .leftovers: .leftovers
            case .large: .large
            case .browsers: .browsers
            case .dev: .dev
            case .messengers: .messengers
            }
        }

        static func stages(for module: Module) -> [ScanStage] {
            if module == .smart { return Array(allCases) }
            return allCases.filter { $0.module == module }
        }
    }

    /// Isolates a stage so one bad folder does not abort the whole scan.
    static func safeItems(for stage: ScanStage) -> StageChunk {
        autoreleasepool {
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
            default:
                raw = stage.items()
            }
            return StageChunk(
                items: raw.filter { $0.bytes > 16_384 && !Keep.isProtected($0.url) },
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
            ("cursor-cacheddata", Line(ru: "Cursor CachedData", en: "Cursor CachedData"), "Library/Application Support/Cursor/CachedData", Line(ru: "Не чаты", en: "Not your chats"))
        ]
        rows.append(contentsOf: fixed.compactMap { item($0.0, .junk, $0.1, $0.3, $0.2) })
        rows.append(contentsOf: enumeratedUserCaches())
        rows.append(contentsOf: enumeratedDotCache())
        return dedupeByURL(rows).sorted { $0.bytes > $1.bytes }
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
        let url = home().appendingPathComponent(".Trash")
        let b = DiskSizer.bytes(at: url)
        guard b > 0 else { return [] }
        return [JunkItem(id: "trash", module: .trash, title: Line(ru: "Корзина пользователя", en: "User Trash"), subtitle: Line(ru: "Файл ещё можно вернуть, пока не очистили", en: "Still recoverable until we empty it"), url: url, bytes: b, selected: false, kind: .emptyTrash, keepsLogins: false)]
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
            if Keep.isProtected(url) { continue }
            let b = DiskSizer.bytes(at: url)
            guard b > 8_388_608 else { continue }
            out.append(JunkItem(id: "left-\(name)", module: .leftovers, title: Line.proper(name), subtitle: Copy.leftoverGone, url: url, bytes: b, selected: false, kind: .wipeChildren, keepsLogins: false))
        }
        return Gathered(items: out.sorted { $0.bytes > $1.bytes }, failed: false)
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
        let roots = ["Downloads", "Desktop", "Movies", "Documents"].map { home().appendingPathComponent($0) }
        var found: [JunkItem] = []
        var failed = false
        let skip = Set(["Personal", "Education", "Work", "STEM", "Safari", "CloudDocs"])
        for root in roots {
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir)
            guard exists else { continue }
            guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
                if isDir.boolValue { failed = true }
                continue
            }
            var depthGuard = 0
            for case let url as URL in en {
                depthGuard += 1
                if depthGuard > 12_000 { break }
                if skip.contains(url.lastPathComponent) { en.skipDescendants(); continue }
                if Keep.isProtected(url) { en.skipDescendants(); continue }
                if ["node_modules", ".git", ".colima", "DerivedData"].contains(url.lastPathComponent) { en.skipDescendants(); continue }
                guard let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), rv.isRegularFile == true else { continue }
                let sz = Int64(rv.fileSize ?? 0)
                guard sz >= 80_000_000 else { continue }
                found.append(JunkItem(id: "large-\(url.path)", module: .large, title: Line.proper(url.lastPathComponent), subtitle: Line.proper(PathFormat.tilde(url.deletingLastPathComponent())), url: url, bytes: sz, selected: false, kind: .deleteItem, keepsLogins: false))
            }
        }
        return Gathered(items: found.sorted { $0.bytes > $1.bytes }, failed: failed)
    }

    private static func browsers() -> [JunkItem] {
        var rows: [JunkItem] = []
        if let x = item("chrome-cache", .browsers, Line(ru: "Chrome — диск-кэш", en: "Chrome disk cache"), Line(ru: "Куки и пароли на месте", en: "Cookies and passwords stay"), "Library/Caches/Google/Chrome", keeps: true) {
            rows.append(x)
        }
        if let x = item("safari-cache", .browsers, Line(ru: "Safari — локальный кэш", en: "Safari local cache"), Line(ru: "Не контейнер сессий", en: "Not the session container"), "Library/Caches/com.apple.Safari", keeps: true) {
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
            rows.append(JunkItem(id: "safari-net", module: .browsers, title: Line(ru: "Safari — сетевой кэш", en: "Safari network cache"), subtitle: Line(ru: "Входы не сбрасываем", en: "Logins stay"), url: store, bytes: safariBytes, selected: true, kind: .safariNetworkCache, keepsLogins: true))
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
                    title: Line(ru: "Firefox — \(cacheName)", en: "Firefox — \(cacheName)"),
                    subtitle: Line(ru: "\(pname) · логины целы", en: "\(pname) · logins intact"),
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
                    title: Line(ru: "\(brand) — \(cacheName)", en: "\(brand) — \(cacheName)"),
                    subtitle: Line(ru: "\(pname) · логины целы", en: "\(pname) · logins intact"),
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
                title: Line(ru: "\(brand) — \(cacheName)", en: "\(brand) — \(cacheName)"),
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
                title: Line(ru: "\(brand) — \(name)", en: "\(brand) — \(name)"),
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
        [
            item("derived", .dev, Line.proper("Xcode DerivedData"), Line(ru: "Симулятор и DeviceSupport не трогаем", en: "Simulator and DeviceSupport stay"), "Library/Developer/Xcode/DerivedData"),
            item("npm", .dev, Line.proper("npm cache"), Line.proper("_cacache"), ".npm/_cacache"),
            item("npx", .dev, Line.proper("npx cache"), Line.proper("_npx"), ".npm/_npx"),
            item("go-build", .dev, Line.proper("Go build cache"), Line.proper("go-build"), "Library/Caches/go-build"),
            item("swiftpm", .dev, Line.proper("SwiftPM cache"), Line.proper("org.swift.swiftpm"), "Library/Caches/org.swift.swiftpm"),
            item("pnpm", .dev, Line.proper("pnpm cache"), Line.proper("Library/Caches/pnpm"), "Library/Caches/pnpm")
        ].compactMap { $0 }
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
        if let x = item("msg", .messengers, Line(ru: "Вложения Сообщений", en: "Messages attachments"), Line(ru: "Потолок имеет смысл с полным доступом к диску", en: "The cap matters with Full Disk Access"), "Library/Messages/Attachments", selected: false) {
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
