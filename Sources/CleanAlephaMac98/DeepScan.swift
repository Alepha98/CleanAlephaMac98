import Foundation

/// Extra deep finds under ~/Library and other hidden roots — fills gaps vs hand-digging.
enum DeepScan {
    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    /// Lower than the classic 8 MB floor so hidden piles actually show up.
    private static let minBytes: Int64 = 2_097_152

    // MARK: - Junk extras

    static func junkExtras() -> [JunkItem] {
        var rows: [JunkItem] = []
        rows.append(contentsOf: fixedHiddenCaches())
        rows.append(contentsOf: enumeratedGroupContainerCaches())
        rows.append(contentsOf: enumeratedAppSupportLogs())
        rows.append(contentsOf: enumeratedHTTPStorages())
        rows.append(contentsOf: enumeratedWebKit())
        rows.append(contentsOf: enumeratedLibraryOrphans())
        return rows
    }

    static func privacyItems() -> [JunkItem] {
        var rows: [JunkItem] = []
        let fixed: [(String, Line, String, Line)] = [
            (
                "priv-safari-history",
                Line(ru: "История Safari", en: "Safari history"),
                "Library/Safari/History.db",
                Line(ru: "По умолчанию выкл. Логины не трогаем.", en: "Off by default. Logins stay.")
            ),
            (
                "priv-recent",
                Line(ru: "Недавние документы", en: "Recent documents"),
                "Library/Application Support/com.apple.sharedfilelist",
                Line(ru: "Списки «Недавние». По умолчанию выкл.", en: "Recents lists. Off by default.")
            ),
            (
                "priv-chrome-hist",
                Line(ru: "История Chrome (Default)", en: "Chrome history (Default)"),
                "Library/Application Support/Google/Chrome/Default/History",
                Line(ru: "Только History. Куки и пароли целы. Выкл.", en: "History only. Cookies/passwords stay. Off.")
            )
        ]
        for entry in fixed {
            let url = home.appendingPathComponent(entry.2)
            let b = DiskSizer.bytes(at: url)
            guard b > 16_384 else { continue }
            rows.append(JunkItem(
                id: entry.0,
                module: .privacy,
                title: entry.1,
                subtitle: entry.3,
                url: url,
                bytes: b,
                selected: false,
                kind: .deleteItem,
                keepsLogins: true
            ))
        }
        return rows
    }

    static func devExtras() -> [JunkItem] {
        let fixed: [(String, Line, String, Line, Bool)] = [
            ("pip", Line.proper("pip cache"), "Library/Caches/pip", Line(ru: "Перекачается", en: "Re-downloads"), true),
            ("cocoapods", Line.proper("CocoaPods cache"), "Library/Caches/CocoaPods", Line(ru: "Pods скачаются снова", en: "Pods re-download"), true),
            ("playwright", Line.proper("Playwright browsers"), "Library/Caches/ms-playwright", Line(ru: "Тяжёлый кэш. По умолчанию выкл.", en: "Heavy. Off by default."), false),
            ("yarn", Line.proper("Yarn cache"), ".yarn/cache", Line(ru: "Пакеты yarn", en: "Yarn packages"), true),
            ("yarn-lib", Line.proper("Yarn Library cache"), "Library/Caches/Yarn", Line(ru: "Пакеты yarn", en: "Yarn packages"), true),
            ("bun", Line.proper("Bun install cache"), ".bun/install/cache", Line(ru: "Пакеты bun", en: "Bun packages"), true),
            ("modulecache", Line.proper("Xcode ModuleCache"), "Library/Developer/Xcode/DerivedData/ModuleCache.noindex", Line(ru: "Пересоберётся", en: "Rebuilds"), true),
            ("xcode-ios-device", Line(ru: "iOS DeviceSupport (Xcode)", en: "iOS DeviceSupport (Xcode)"), "Library/Developer/Xcode/iOS DeviceSupport", Line(ru: "Тяжёлое. По умолчанию выкл.", en: "Heavy. Off by default."), false),
            ("sim-caches", Line(ru: "Кэши симулятора", en: "Simulator caches"), "Library/Developer/CoreSimulator/Caches", Line(ru: "Не устройства. По умолчанию выкл.", en: "Not device data. Off by default."), false),
            ("carthage", Line.proper("Carthage cache"), "Library/Caches/org.carthage.CarthageKit", Line(ru: "Сборки Carthage", en: "Carthage builds"), true),
            ("composer", Line.proper("Composer cache"), "Library/Caches/composer", Line(ru: "PHP Composer", en: "PHP Composer"), true),
            ("rubygems", Line.proper("RubyGems cache"), ".gem/cache", Line(ru: "Гемами можно поставить снова", en: "Gems reinstall"), true)
        ]
        return fixed.compactMap { id, title, rel, sub, on in
            let url = home.appendingPathComponent(rel)
            if Keep.isProtected(url), id != "xcode-ios-device", id != "sim-caches" { return nil }
            // DeviceSupport / CoreSimulator are Keep-protected — allow explicit opt-in cards.
            let b: Int64
            if id == "xcode-ios-device" || id == "sim-caches" {
                b = DiskSizer.duSK(url, timeout: 20) ?? 0
            } else {
                b = DiskSizer.bytes(at: url)
            }
            guard b >= minBytes else { return nil }
            return JunkItem(
                id: "dev-\(id)",
                module: .dev,
                title: title,
                subtitle: sub,
                url: url,
                bytes: b,
                selected: on,
                kind: .wipeChildren,
                keepsLogins: false
            )
        }
    }

    static func leftoverExtras() -> [JunkItem] {
        var out: [JunkItem] = []
        let apps = installedAppNames()
        out.append(contentsOf: orphanCaches(apps: apps))
        out.append(contentsOf: orphanContainers(apps: apps))
        out.append(contentsOf: orphanPreferences(apps: apps))
        out.append(contentsOf: orphanLaunchAgents(apps: apps))
        return out
    }

    /// Library top-level folder sizes for Space Lens.
    static func spaceLensRows(limit: Int = 14) -> [(name: String, bytes: Int64, url: URL)] {
        let lib = home.appendingPathComponent("Library")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: lib,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var rows: [(String, Int64, URL)] = []
        var n = 0
        for url in kids {
            ScanThrottle.tickSync(every: 8, counter: &n)
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            if Keep.isProtected(url) { continue }
            let b = DiskSizer.duSK(url, timeout: 8) ?? DiskSizer.bytes(at: url)
            guard b >= 20_000_000 else { continue }
            rows.append((name, b, url))
        }
        return rows.sorted { $0.1 > $1.1 }.prefix(limit).map { ($0.0, $0.1, $0.2) }
    }

    // MARK: - Fixed hidden / popular app caches

    private static func fixedHiddenCaches() -> [JunkItem] {
        let fixed: [(String, Line, String, Line, Bool)] = [
            ("spotify", Line(ru: "Кэш Spotify", en: "Spotify cache"), "Library/Caches/com.spotify.client", Line(ru: "Стримы скачаются снова", en: "Streams re-cache"), true),
            ("spotify-as", Line(ru: "Spotify Data cache", en: "Spotify Data cache"), "Library/Application Support/Spotify/PersistentCache", Line(ru: "Не плейлисты", en: "Not playlists"), true),
            ("discord", Line(ru: "Кэш Discord", en: "Discord cache"), "Library/Application Support/discord/Cache", Line(ru: "Не чаты", en: "Not chats"), true),
            ("discord-code", Line(ru: "Discord Code Cache", en: "Discord Code Cache"), "Library/Application Support/discord/Code Cache", Line(ru: "Не чаты", en: "Not chats"), true),
            ("slack", Line(ru: "Кэш Slack", en: "Slack cache"), "Library/Application Support/Slack/Cache", Line(ru: "Не переписка", en: "Not messages"), true),
            ("slack-gpu", Line(ru: "Slack GPUCache", en: "Slack GPUCache"), "Library/Application Support/Slack/GPUCache", Line(ru: "Шейдеры", en: "Shaders"), true),
            ("zoom", Line(ru: "Кэш Zoom", en: "Zoom cache"), "Library/Application Support/zoom.us/data", Line(ru: "Временные данные Zoom", en: "Zoom temp data"), true),
            ("steam", Line(ru: "Кэш Steam", en: "Steam cache"), "Library/Application Support/Steam/appcache", Line(ru: "Не игры", en: "Not game installs"), true),
            ("adobe-media", Line(ru: "Adobe Media Cache", en: "Adobe Media Cache"), "Library/Application Support/Adobe/Common/Media Cache Files", Line(ru: "Premiere/After Effects", en: "Premiere/After Effects"), true),
            ("adobe-peak", Line(ru: "Adobe Peak Files", en: "Adobe Peak Files"), "Library/Application Support/Adobe/Common/Peak Files", Line(ru: "Пики аудио", en: "Audio peaks"), true),
            ("figma", Line(ru: "Кэш Figma", en: "Figma cache"), "Library/Application Support/Figma/DesktopProfile/Cache", Line(ru: "Не файлы", en: "Not files"), true),
            ("notion", Line(ru: "Кэш Notion", en: "Notion cache"), "Library/Application Support/Notion/Cache", Line(ru: "Не заметки", en: "Not notes"), true),
            ("obsidian", Line(ru: "Кэш Obsidian", en: "Obsidian cache"), "Library/Application Support/obsidian/Cache", Line(ru: "Не vault", en: "Not vault"), true),
            ("linear", Line(ru: "Кэш Linear", en: "Linear cache"), "Library/Application Support/Linear/Cache", Line(ru: "Не задачи", en: "Not issues"), true),
            ("dropbox-cache", Line(ru: "Кэш Dropbox", en: "Dropbox cache"), "Library/Caches/com.getdropbox.Dropbox", Line(ru: "Не облачные файлы", en: "Not cloud files"), true),
            ("onedrive", Line(ru: "Кэш OneDrive", en: "OneDrive cache"), "Library/Caches/com.microsoft.OneDrive", Line(ru: "Не облако", en: "Not cloud files"), true),
            ("diagnostic", Line(ru: "DiagnosticReports", en: "DiagnosticReports"), "Library/Logs/DiagnosticReports", Line(ru: "Отчёты о падениях", en: "Crash diagnostics"), true),
            ("ios-software", Line(ru: "Обновления iOS (кэш)", en: "iOS software updates"), "Library/iTunes/iPhone Software Updates", Line(ru: "Старые IPSW. Выкл.", en: "Old IPSW. Off."), false),
            ("mobile-docs-tmp", Line(ru: "Временные iCloud Drive", en: "iCloud Drive temp"), "Library/Application Support/CloudDocs/session/temp", Line(ru: "Временные сессии", en: "Session temp"), true),
            ("helpd", Line.proper("Helpd cache"), "Library/Caches/com.apple.helpd", Line(ru: "Индексы справки", en: "Help indexes"), true),
            ("geo", Line.proper("GeoServices cache"), "Library/Caches/GeoServices", Line(ru: "Карты/гео", en: "Maps/geo"), true),
            ("fontreg", Line(ru: "Кэш шрифтов", en: "Font registry cache"), "Library/Caches/com.apple.FontRegistry", Line(ru: "Пересоберётся", en: "Rebuilds"), true),
            ("quicklook", Line(ru: "Кэш Quick Look", en: "Quick Look cache"), "Library/Caches/com.apple.QuickLook.thumbnailcache", Line(ru: "Превью", en: "Thumbnails"), true)
        ]
        return fixed.compactMap { id, title, rel, sub, on -> JunkItem? in
            let url = home.appendingPathComponent(rel)
            if Keep.isProtected(url) { return nil }
            let b = DiskSizer.bytes(at: url)
            guard b >= minBytes || (b > 16_384 && id.hasPrefix("priv")) else { return nil }
            guard b >= minBytes else { return nil }
            return JunkItem(
                id: "deep-\(id)",
                module: .junk,
                title: title,
                subtitle: sub,
                url: url,
                bytes: b,
                selected: on,
                kind: .wipeChildren,
                keepsLogins: false
            )
        }
    }

    /// ~/Library/Group Containers/*/Data/Library/Caches
    private static func enumeratedGroupContainerCaches() -> [JunkItem] {
        let root = home.appendingPathComponent("Library/Group Containers")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var out: [JunkItem] = []
        var n = 0
        for container in kids {
            ScanThrottle.tickSync(every: 12, counter: &n)
            let id = container.lastPathComponent
            if id.lowercased().contains("photo") { continue }
            if Keep.isProtected(container) { continue }
            let cache = container.appendingPathComponent("Library/Caches")
            // Some put Caches under Data/Library/Caches
            let candidates = [
                cache,
                container.appendingPathComponent("Data/Library/Caches")
            ]
            for url in candidates {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let b = DiskSizer.bytes(at: url)
                guard b >= minBytes else { continue }
                out.append(JunkItem(
                    id: "gcache-\(id)-\(url.path.hashValue)",
                    module: .junk,
                    title: Line(ru: "Group · \(short(id))", en: "Group · \(short(id))"),
                    subtitle: Line(ru: "Group Containers / Caches", en: "Group Containers / Caches"),
                    url: url,
                    bytes: b,
                    selected: !id.hasPrefix("com.apple"),
                    kind: .wipeChildren,
                    keepsLogins: false
                ))
            }
        }
        return out
    }

    private static func enumeratedAppSupportLogs() -> [JunkItem] {
        let root = home.appendingPathComponent("Library/Application Support")
        let fm = FileManager.default
        guard let apps = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let leaves = ["logs", "Logs", "log", "Crashpad", "crashpad", "tmp", "Temp", "temp"]
        var out: [JunkItem] = []
        var n = 0
        for app in apps {
            ScanThrottle.tickSync(every: 20, counter: &n)
            let name = app.lastPathComponent
            if name.hasPrefix("com.apple") { continue }
            if Keep.isProtected(app) { continue }
            for leaf in leaves {
                let url = app.appendingPathComponent(leaf)
                let b = DiskSizer.bytes(at: url)
                guard b >= minBytes else { continue }
                out.append(JunkItem(
                    id: "aslog-\(name)-\(leaf)",
                    module: .junk,
                    title: Line(ru: "\(name) · \(leaf)", en: "\(name) · \(leaf)"),
                    subtitle: Line(ru: "Логи / temp в Application Support", en: "Logs / temp in Application Support"),
                    url: url,
                    bytes: b,
                    selected: true,
                    kind: .wipeChildren,
                    keepsLogins: false
                ))
            }
        }
        return out
    }

    private static func enumeratedHTTPStorages() -> [JunkItem] {
        let root = home.appendingPathComponent("Library/HTTPStorages")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple.") { continue }
            if Keep.isProtected(url) { continue }
            let b = DiskSizer.bytes(at: url)
            guard b >= minBytes else { continue }
            out.append(JunkItem(
                id: "http-\(name)",
                module: .junk,
                title: Line(ru: "HTTP · \(short(name))", en: "HTTP · \(short(name))"),
                subtitle: Line(ru: "Library/HTTPStorages", en: "Library/HTTPStorages"),
                url: url,
                bytes: b,
                selected: true,
                kind: .wipeChildren,
                keepsLogins: false
            ))
        }
        return out
    }

    private static func enumeratedWebKit() -> [JunkItem] {
        let root = home.appendingPathComponent("Library/WebKit")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }
        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            if Keep.isProtected(url) { continue }
            // WebsiteData often holds more than cache — default off for non-obvious
            let cache = url.appendingPathComponent("WebsiteData/Cache")
            let b = DiskSizer.bytes(at: cache)
            if b >= minBytes {
                out.append(JunkItem(
                    id: "webkit-\(name)",
                    module: .junk,
                    title: Line(ru: "WebKit · \(short(name))", en: "WebKit · \(short(name))"),
                    subtitle: Line(ru: "WebsiteData/Cache", en: "WebsiteData/Cache"),
                    url: cache,
                    bytes: b,
                    selected: true,
                    kind: .wipeChildren,
                    keepsLogins: true
                ))
            }
        }
        return out
    }

    /// Orphan-ish piles under Library that aren't full leftovers.
    private static func enumeratedLibraryOrphans() -> [JunkItem] {
        let fixed: [(String, Line, String, Line, Bool)] = [
            ("savedstate-big", Line(ru: "Saved Application State", en: "Saved Application State"), "Library/Saved Application State", Line(ru: "Снимки окон", en: "Window snapshots"), true),
            ("maps", Line(ru: "Кэш Карт", en: "Maps cache"), "Library/Caches/com.apple.geod", Line(ru: "Офлайн-тайлы", en: "Offline tiles"), true),
            ("siri-tts", Line(ru: "Голоса Siri (кэш)", en: "Siri voices cache"), "Library/Caches/com.apple.SiriTTSService", Line(ru: "Голоса скачаются снова", en: "Voices re-download"), false),
            ("mail-cache", Line(ru: "Кэш Mail", en: "Mail cache"), "Library/Containers/com.apple.mail/Data/Library/Caches", Line(ru: "Не письма", en: "Not mailboxes"), true)
        ]
        return fixed.compactMap { id, title, rel, sub, on in
            let url = home.appendingPathComponent(rel)
            if Keep.isProtected(url) { return nil }
            let b = DiskSizer.bytes(at: url)
            guard b >= minBytes else { return nil }
            return JunkItem(
                id: "liborphan-\(id)",
                module: .junk,
                title: title,
                subtitle: sub,
                url: url,
                bytes: b,
                selected: on,
                kind: .wipeChildren,
                keepsLogins: false
            )
        }
    }

    // MARK: - Leftover extras

    private static func orphanCaches(apps: [String]) -> [JunkItem] {
        let root = home.appendingPathComponent("Library/Caches")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }
        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple") { continue }
            if Keep.isProtected(url) { continue }
            if leftoverHasOwner(name, apps: apps) { continue }
            let b = DiskSizer.bytes(at: url)
            guard b >= 8_388_608 else { continue }
            out.append(JunkItem(
                id: "left-cache-\(name)",
                module: .leftovers,
                title: Line(ru: "Кэш без приложения · \(short(name))", en: "Orphan cache · \(short(name))"),
                subtitle: Copy.leftoverGone,
                url: url,
                bytes: b,
                selected: false,
                kind: .wipeChildren,
                keepsLogins: false
            ))
        }
        return out
    }

    private static func orphanContainers(apps: [String]) -> [JunkItem] {
        let root = home.appendingPathComponent("Library/Containers")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: []) else {
            return []
        }
        var out: [JunkItem] = []
        var n = 0
        for url in kids {
            ScanThrottle.tickSync(every: 25, counter: &n)
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple") { continue }
            if Keep.isProtected(url) { continue }
            if leftoverHasOwner(name, apps: apps) { continue }
            let b = DiskSizer.duSK(url, timeout: 6) ?? 0
            guard b >= 12_000_000 else { continue }
            out.append(JunkItem(
                id: "left-ctr-\(name)",
                module: .leftovers,
                title: Line(ru: "Контейнер · \(short(name))", en: "Container · \(short(name))"),
                subtitle: Line(ru: "Sandbox без приложения. Выкл.", en: "Sandbox without app. Off."),
                url: url,
                bytes: b,
                selected: false,
                kind: .wipeChildren,
                keepsLogins: false
            ))
        }
        return out
    }

    private static func orphanPreferences(apps: [String]) -> [JunkItem] {
        let root = home.appendingPathComponent("Library/Preferences")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return []
        }
        // Bundle prefs as groups by vendor prefix — only large singles
        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            guard name.hasSuffix(".plist") else { continue }
            if name.hasPrefix("com.apple") || name.hasPrefix(".") { continue }
            let stem = String(name.dropLast(6))
            if leftoverHasOwner(stem, apps: apps) { continue }
            guard let rv = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let size = rv.fileSize,
                  size >= 512_000 else { continue }
            out.append(JunkItem(
                id: "left-pref-\(name)",
                module: .leftovers,
                title: Line(ru: "Pref · \(short(stem))", en: "Pref · \(short(stem))"),
                subtitle: Line(ru: "Одинокий .plist. Выкл.", en: "Orphan plist. Off."),
                url: url,
                bytes: Int64(size),
                selected: false,
                kind: .deleteItem,
                keepsLogins: false
            ))
        }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(40))
    }

    private static func orphanLaunchAgents(apps: [String]) -> [JunkItem] {
        let root = home.appendingPathComponent("Library/LaunchAgents")
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return []
        }
        var out: [JunkItem] = []
        for url in kids {
            let name = url.lastPathComponent
            if name.hasPrefix("com.apple") { continue }
            let stem = name.replacingOccurrences(of: ".plist", with: "")
            if leftoverHasOwner(stem, apps: apps) { continue }
            let b = max(Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 4096), 4096)
            out.append(JunkItem(
                id: "left-agent-\(name)",
                module: .leftovers,
                title: Line(ru: "LaunchAgent · \(short(stem))", en: "LaunchAgent · \(short(stem))"),
                subtitle: Line(ru: "Агент без приложения. Выкл.", en: "Agent without app. Off."),
                url: url,
                bytes: b,
                selected: false,
                kind: .deleteItem,
                keepsLogins: false
            ))
        }
        return out
    }

    // MARK: - Helpers (mirror Scanner leftover ownership)

    private static func installedAppNames() -> [String] {
        var names: [String] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            if let xs = try? FileManager.default.contentsOfDirectory(atPath: root) {
                names += xs.map { $0.replacingOccurrences(of: ".app", with: "") }
            }
        }
        return names
    }

    private static func leftoverHasOwner(_ folder: String, apps: [String]) -> Bool {
        let always = Set(["Apple", "com.apple", "CleanAlephaMac98"])
        if always.contains(folder) { return true }
        let lower = folder.lowercased()
        if apps.contains(where: {
            let a = $0.lowercased()
            return a.contains(lower) || lower.contains(a)
        }) { return true }
        // Bundle-id style: com.vendor.app → try vendor/app tokens
        let parts = folder.split(separator: ".").map(String.init)
        if parts.count >= 2 {
            let vendor = parts[parts.count - 2]
            let app = parts[parts.count - 1]
            if apps.contains(where: { $0.localizedCaseInsensitiveContains(app) || $0.localizedCaseInsensitiveContains(vendor) }) {
                return true
            }
        }
        return false
    }

    private static func short(_ id: String) -> String {
        if id.count <= 32 { return id }
        return "…" + String(id.suffix(28))
    }
}
