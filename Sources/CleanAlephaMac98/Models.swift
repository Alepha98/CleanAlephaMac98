import Foundation

enum Module: String, CaseIterable, Identifiable, Sendable {
    case smart, junk, mail, trash, leftovers, large, browsers, dev, messengers
    case pulse, protect, startup
    case space, tools
    var id: String { rawValue }

    var name: Line {
        switch self {
        case .smart: Copy.moduleSmart
        case .junk: Copy.moduleJunk
        case .mail: Copy.moduleMail
        case .trash: Copy.moduleTrash
        case .leftovers: Copy.moduleLeftovers
        case .large: Copy.moduleLarge
        case .browsers: Copy.moduleBrowsers
        case .dev: Copy.moduleDev
        case .messengers: Copy.moduleMessengers
        case .pulse: Copy.modulePulse
        case .protect: Copy.moduleProtect
        case .startup: Copy.moduleStartup
        case .space: Copy.moduleSpace
        case .tools: Copy.moduleTools
        }
    }

    var blurb: Line {
        switch self {
        case .smart: Copy.subSmart
        case .junk: Copy.subJunk
        case .mail: Copy.subMail
        case .trash: Copy.subTrash
        case .leftovers: Copy.subLeftovers
        case .large: Copy.subLarge
        case .browsers: Copy.subBrowsers
        case .dev: Copy.subDev
        case .messengers: Copy.subMessengers
        case .pulse: Copy.subPulse
        case .protect: Copy.subProtect
        case .startup: Copy.subStartup
        case .space, .tools: Line(ru: "", en: "")
        }
    }

    var isCleanupModule: Bool {
        switch self {
        case .smart, .junk, .mail, .trash, .leftovers, .large, .browsers, .dev, .messengers,
             .pulse, .protect, .startup:
            true
        case .space, .tools:
            false
        }
    }

    var isLiveModule: Bool {
        switch self {
        case .pulse, .protect, .startup: true
        default: false
        }
    }

    var suggestsFDA: Bool {
        switch self {
        case .smart, .mail, .browsers, .messengers, .protect: true
        default: false
        }
    }
}

enum CleanKind: Sendable, Equatable {
    case wipeChildren
    case safariNetworkCache
    case deleteItem
    case emptyTrash
    case advice
    case removeAgent
    case removeLoginItem
    /// Close one browser tab via AppleScript – never quits the browser.
    case closeTab
}

struct JunkItem: Identifiable, Equatable, Sendable {
    let id: String
    let module: Module
    let title: Line
    let subtitle: Line
    let url: URL
    var bytes: Int64
    var selected: Bool
    let kind: CleanKind
    let keepsLogins: Bool

    /// Large files / Telegram history / rebuild caches – quieter when unchecked.
    var isSecondaryRisk: Bool {
        if module == .pulse { return kind == .closeTab || kind == .advice }
        if module == .startup { return kind != .advice }
        if module == .protect { return kind == .advice || id.hasPrefix("unsigned-") }
        if module == .large { return true }
        if id.contains("tg-d-") { return true }
        if kind == .deleteItem { return true }
        if isRebuildCache { return true }
        return false
    }

    /// huggingface / codex-runtimes — expensive to wipe by default.
    var isRebuildCache: Bool {
        id == "dotcache-huggingface" || id == "dotcache-codex-runtimes"
    }

    /// Preset for «Безопасное»: caches on, trash / leftovers / history / huge off.
    var isSafePreset: Bool {
        if module == .pulse { return kind == .closeTab }
        if module == .startup { return false }
        if module == .protect { return !isSecondaryRisk }
        if isSecondaryRisk { return false }
        if kind == .emptyTrash { return false }
        if module == .leftovers { return false }
        if id.hasPrefix("msg") { return false }
        return true
    }

    var cautionBadge: Line? {
        if module == .pulse, id == "pulse-ram" || id == "pulse-cpu" { return nil }
        if module == .pulse, kind == .closeTab { return Copy.tabCloseBadge }
        if module == .pulse, id.hasPrefix("pulse-app-") { return Copy.drillBadge }
        if module == .pulse, id.hasPrefix("pulse-child:") { return Copy.recommendBadge }
        if module == .pulse { return Copy.recommendBadge }
        if id.contains("tg-d-") { return Copy.historyBadge }
        if module == .leftovers { return Copy.leftoverBadge }
        if isRebuildCache { return Copy.rebuildBadge }
        return nil
    }
}

enum Keep {
    static let names: Set<String> = [
        "Cookies", "Cookies-journal",
        "Login Data", "Login Data-journal", "Login Data For Account",
        "Web Data", "Web Data-journal",
        "Local Storage", "LocalStorage", "IndexedDB",
        "Preferences", "Secure Preferences",
        "MediaKeys", "MediaKeysHashSalts", "HSTS",
        "AlternativeServices", "Origins",
        "Network Persistent State", "TransportSecurity",
        "Trust Tokens", "Trust Tokens-journal",
        "Extension Cookies", "Extension Cookies-journal"
    ]

    static let extrasKey = "cam98.extraProtected"

    /// Machine-agnostic: VMs, simulators, Photos. Named iCloud libraries only under CloudDocs.
    static let pathFragments: [String] = [
        "/.colima", "/Parallels/", "/.gradle",
        "/CoreSimulator", "/iOS DeviceSupport",
        "/Claude/vm_bundles", "Photos Library",
        "/Mobile Documents/com~apple~CloudDocs/Personal",
        "/Mobile Documents/com~apple~CloudDocs/Education",
        "/Mobile Documents/com~apple~CloudDocs/Work",
        "/Mobile Documents/com~apple~CloudDocs/STEM"
    ]

    static var extraPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: extrasKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: extrasKey) }
    }

    static func isProtected(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        if pathFragments.contains(where: { p.contains($0) }) { return true }
        for extra in extraPaths {
            if p == extra || p.hasPrefix(extra + "/") { return true }
        }
        return false
    }

    static func canExclude(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if p == "/" || p == home { return false }
        if p == "/System" || p.hasPrefix("/System/") { return false }
        if p == "/Library" { return false }
        return true
    }

    static func addExtra(_ url: URL) {
        guard canExclude(url) else { return }
        let p = url.standardizedFileURL.path
        var xs = extraPaths
        if xs.contains(p) { return }
        xs.append(p)
        extraPaths = xs
    }

    static func removeExtra(_ path: String) {
        extraPaths = extraPaths.filter { $0 != path }
    }

    /// Folders the disk ring counts as «не трогаем» — not a hole in the ring.
    static func protectedRoots() -> [URL] {
        let fm = FileManager.default
        var urls = builtinCatalog().map(\.url).filter { fm.fileExists(atPath: $0.path) }
        for path in extraPaths {
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: url.path) { urls.append(url) }
        }
        var seen = Set<String>()
        return urls.filter {
            let key = $0.standardizedFileURL.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    static func builtinCatalog() -> [(name: String, reason: Line, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let icloud = home.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        return [
            ("Colima", Line(ru: "Виртуальные машины Linux", en: "Linux virtual machines"), home.appendingPathComponent(".colima")),
            ("Parallels", Line(ru: "Виртуальная машина Windows", en: "Windows virtual machine"), home.appendingPathComponent("Parallels")),
            ("Parallels", Line(ru: "Виртуальная машина Windows", en: "Windows virtual machine"), home.appendingPathComponent("Documents/Parallels")),
            ("Gradle", Line(ru: "Кэш сборки Android", en: "Android build cache"), home.appendingPathComponent(".gradle")),
            ("iOS Simulator", Line(ru: "Симуляторы Xcode", en: "Xcode simulators"), home.appendingPathComponent("Library/Developer/CoreSimulator")),
            ("iPhone symbols", Line(ru: "DeviceSupport – качается заново", en: "DeviceSupport – downloads again"), home.appendingPathComponent("Library/Developer/Xcode/iOS DeviceSupport")),
            ("Claude VM", Line(ru: "Локальные виртуальные машины Claude", en: "Local Claude VMs"), home.appendingPathComponent("Library/Application Support/Claude/vm_bundles")),
            ("Photos", Line(ru: "Медиатека", en: "Photo library"), home.appendingPathComponent("Pictures/Photos Library.photoslibrary")),
            ("iCloud Personal", Line(ru: "Облачная библиотека", en: "Cloud library"), icloud.appendingPathComponent("Personal")),
            ("iCloud Education", Line(ru: "Облачная библиотека", en: "Cloud library"), icloud.appendingPathComponent("Education")),
            ("iCloud Work", Line(ru: "Облачная библиотека", en: "Cloud library"), icloud.appendingPathComponent("Work")),
            ("iCloud STEM", Line(ru: "Облачная библиотека", en: "Cloud library"), icloud.appendingPathComponent("STEM"))
        ]
    }

    static func visibleShields() -> [ShieldRow] {
        let fm = FileManager.default
        var rows: [ShieldRow] = []
        var seen = Set<String>()
        for item in builtinCatalog() {
            let path = item.url.standardizedFileURL.path
            guard fm.fileExists(atPath: item.url.path) else { continue }
            if seen.contains(path) { continue }
            seen.insert(path)
            rows.append(ShieldRow(name: item.name, reason: item.reason, path: path, removable: false))
        }
        for path in extraPaths {
            if seen.contains(path) { continue }
            seen.insert(path)
            let url = URL(fileURLWithPath: path)
            let name = url.lastPathComponent.isEmpty ? path : url.lastPathComponent
            rows.append(ShieldRow(
                name: name,
                reason: Line.proper(PathFormat.tilde(url)),
                path: path,
                removable: true
            ))
        }
        return rows
    }
}

struct ShieldRow: Identifiable, Equatable {
    var name: String
    var reason: Line
    var path: String
    var removable: Bool
    var id: String { path }
}

enum ByteFormat {
    private static let nbsp = "\u{00A0}"

    static func string(_ bytes: Int64, _ lang: CopyLang = .ru) -> String {
        let v = Double(max(0, bytes))
        if lang == .en {
            if v >= 1_073_741_824 { return String(format: "%.2f\(nbsp)GB", v / 1_073_741_824) }
            if v >= 1_048_576 { return String(format: "%.0f\(nbsp)MB", v / 1_048_576) }
            if v >= 1024 { return String(format: "%.0f\(nbsp)KB", v / 1024) }
            return "\(Int(v))\(nbsp)B"
        }
        if v >= 1_073_741_824 { return String(format: "%.2f\(nbsp)ГБ", v / 1_073_741_824) }
        if v >= 1_048_576 { return String(format: "%.0f\(nbsp)МБ", v / 1_048_576) }
        if v >= 1024 { return String(format: "%.0f\(nbsp)КБ", v / 1024) }
        return "\(Int(v))\(nbsp)Б"
    }

    /// Invisible reserve so 54 МБ → 1.23 ГБ does not shift the header.
    static let widthReserve = "88.88\u{00A0}ГБ"
}

enum PathFormat {
    static func tilde(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.path
        if p.hasPrefix(home) {
            return "~" + p.dropFirst(home.count)
        }
        return p
    }
}

enum Maintenance {
    static var logURL: URL { AutoAgent.logURL }
    static var agentURL: URL { AutoAgent.plistURL }

    static func snapshot() -> (when: Date?, freed: Int64?, installed: Bool) {
        let installed = FileManager.default.fileExists(atPath: agentURL.path)
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else {
            return (nil, nil, installed)
        }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var when: Date?
        var freed: Int64?
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard s.contains("auto done"), s.count >= 19 else { continue }
            when = fmt.date(from: String(s.prefix(19))) ?? when
            if let range = s.range(of: "freed ") {
                let rest = s[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let num = rest.split(whereSeparator: \.isWhitespace).first
                if let num, let n = Int64(num) {
                    freed = n
                }
            }
        }
        return (when, freed, installed)
    }
}
