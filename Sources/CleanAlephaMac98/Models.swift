import Foundation

enum Module: String, CaseIterable, Identifiable, Sendable {
    case smart, junk, mail, trash, leftovers, large, duplicates, deepSearch, browsers, dev, messengers, privacy
    case pulse, protect, startup
    case space, tools, uninstaller
    var id: String { rawValue }

    var name: Line {
        switch self {
        case .smart: Copy.moduleSmart
        case .junk: Copy.moduleJunk
        case .mail: Copy.moduleMail
        case .trash: Copy.moduleTrash
        case .leftovers: Copy.moduleLeftovers
        case .large: Copy.moduleLarge
        case .duplicates: Copy.moduleDuplicates
        case .deepSearch: Copy.moduleDeepSearch
        case .browsers: Copy.moduleBrowsers
        case .dev: Copy.moduleDev
        case .messengers: Copy.moduleMessengers
        case .privacy: Copy.modulePrivacy
        case .pulse: Copy.modulePulse
        case .protect: Copy.moduleProtect
        case .startup: Copy.moduleStartup
        case .space: Copy.moduleSpace
        case .tools: Copy.moduleTools
        case .uninstaller: Copy.moduleUninstaller
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
        case .duplicates: Copy.subDuplicates
        case .deepSearch: Copy.subDeepSearch
        case .browsers: Copy.subBrowsers
        case .dev: Copy.subDev
        case .messengers: Copy.subMessengers
        case .privacy: Copy.subPrivacy
        case .pulse: Copy.subPulse
        case .protect: Copy.subProtect
        case .startup: Copy.subStartup
        case .uninstaller: Copy.subUninstaller
        case .space, .tools: Line(ru: "", en: "")
        }
    }

    var isCleanupModule: Bool {
        switch self {
        case .smart, .junk, .mail, .trash, .leftovers, .large, .duplicates, .deepSearch, .browsers, .dev, .messengers,
             .privacy, .pulse, .protect, .startup:
            true
        case .space, .tools, .uninstaller:
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
        case .smart, .junk, .mail, .browsers, .messengers, .protect, .privacy, .deepSearch: true
        default: false
        }
    }
}

enum CleanKind: Sendable, Equatable {
    case wipeChildren
    case safariNetworkCache
    case deleteItem
    case deleteCaptureRemnants
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

    /// Bytes that the app can honestly present as removable. Audit rows may describe
    /// large system stores, but they are not cleanup promises and must not inflate totals.
    var reclaimableBytes: Int64 {
        kind == .advice ? 0 : max(0, bytes)
    }

    /// Read-only findings remain visible even when macOS does not expose their size.
    var hasVisibleFinding: Bool {
        bytes > 0 || kind == .advice
    }

    /// Large files / Telegram history / rebuild caches / duplicates – quieter when unchecked.
    var isSecondaryRisk: Bool {
        if kind == .advice { return true }
        if kind == .deleteCaptureRemnants { return true }
        if module == .pulse { return kind == .closeTab || kind == .advice }
        if module == .duplicates { return true }
        if module == .startup { return kind != .advice }
        if module == .protect { return kind == .advice || id.hasPrefix("unsigned-") }
        if module == .large { return true }
        if id.contains("tg-d-") { return true }
        if [
            "state", "liborphan-savedstate-big", "cloudkit-cache",
            "dev-playwright", "dev-xcode-ios-device", "dev-sim-caches",
            "deep-ios-software", "deep-siri-tts"
        ].contains(id) { return true }
        if kind == .deleteItem { return true }
        if isRebuildCache { return true }
        return false
    }

    /// Large reproducible downloads that are expensive to rebuild.
    var isRebuildCache: Bool {
        id == "dotcache-huggingface"
            || id == "dotcache-codex-runtimes"
            || id == "dev-playwright"
            || id == "dev-xcode-ios-device"
            || id == "dev-sim-caches"
    }

    /// Preset for «Безопасное»: caches on, trash / leftovers / history / huge off.
    var isSafePreset: Bool {
        if kind == .advice { return false }
        if HiddenCaptureScanner.isSafePresetCard(self) { return true }
        if ArtifactScanner.isSafePresetCard(self) { return true }
        if module == .pulse { return kind == .closeTab }
        if module == .startup { return false }
        if module == .protect { return !isSecondaryRisk }
        if module == .privacy { return false }
        if isSecondaryRisk { return false }
        if kind == .emptyTrash { return false }
        if module == .leftovers { return false }
        if id.hasPrefix("msg") { return false }
        return true
    }

    var cautionBadge: Line? {
        if id == "dup-folder-partial-coverage" { return Copy.auditBadge }
        if id.hasPrefix("dup-folder-shared-") { return Copy.auditBadge }
        if id.hasPrefix("dup-folder-") { return Copy.recommendBadge }
        if id == "ai-cursor-state-db" { return Copy.auditBadge }
        if id.hasPrefix("similar-capture-audit-") || id == "similar-capture-partial-coverage" {
            return Copy.auditBadge
        }
        if id.hasPrefix("similar-capture-file-") { return Copy.recommendBadge }
        if id.hasPrefix("forensic-") { return Copy.auditBadge }
        if id.contains("-orphan-") { return Copy.auditBadge }
        if id.hasPrefix("intel-") { return Copy.deepBadge }
        if id.hasPrefix("hidden-tree-") { return Copy.deepBadge }
        if kind == .deleteCaptureRemnants { return Copy.hiddenCopyBadge }
        if id.hasPrefix("system-audit-") { return Copy.auditBadge }
        if id.hasPrefix("dup-hardlink-") || id.hasPrefix("dup-clone-")
            || id.hasPrefix("large-shared-") { return Copy.auditBadge }
        if id.hasPrefix("darwin-cache-") || id.hasPrefix("darwin-temp-") { return Copy.deepBadge }
        if module == .pulse, id == "pulse-ram" || id == "pulse-cpu" { return Copy.drillBadge }
        if module == .pulse, id.hasPrefix("pulse-part:") { return nil }
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
        "Local State", "Session Storage", "Sessions", "WebStorage",
        "Service Worker",
        "accounts", "Accounts", "Auth", "Authentication",
        "key_data", "key_datas", "settingss", "postbox", "tdata", "user_data",
        "Preferences", "Secure Preferences",
        "MediaKeys", "MediaKeysHashSalts", "HSTS",
        "AlternativeServices", "Origins",
        "Network Persistent State", "TransportSecurity",
        "Trust Tokens", "Trust Tokens-journal",
        "Extension Cookies", "Extension Cookies-journal"
    ]

    static let extrasKey = "cam98.extraProtected"
    static let dismissedKey = "cam98.dismissedIds"

    /// Machine-agnostic: VMs, simulators, Photos. Named iCloud libraries only under CloudDocs.
    static let pathFragments: [String] = [
        "/.colima", "/Parallels/", "/.gradle",
        "/CoreSimulator", "/iOS DeviceSupport",
        "/Library/Application Support/MobileSync/Backup",
        "/Library/Group Containers/group.com.apple.screencapture",
        "/Library/ScreenRecordings",
        "/Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information",
        "/Library/Application Support/CloudDocs/session",
        "/Library/HTTPStorages",
        "/Claude/vm_bundles", "Photos Library",
        "/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
        "/Library/Application Support/Cursor/CachedExtensionVSIXs/.trash",
        "/.cursor/extensions",
        "/.claude/projects", "/.claude/sessions",
        "/.codex/sessions", "/.codex/archived_sessions", "/.codex/sqlite",
        "/Library/Application Support/com.openai.chat",
        "/Library/Application Support/Codex",
        "/Library/Preferences/com.openai.",
        "/Library/Preferences/com.anthropic.",
        "/Library/Application Support/Claude/local-agent-mode-sessions",
        "/Library/Application Support/Claude/claude-code-sessions",
        "/Library/Application Support/Claude/Session Storage",
        "/Library/Application Support/Claude/Local Storage",
        "/Library/Application Support/Claude/IndexedDB",
        "/Library/Application Support/Claude/WebStorage",
        "/Library/Application Support/Claude/Partitions",
        "/Library/Application Support/Telegram Desktop/tdata",
        "/Library/Application Support/zoom.us/data",
        "/Mobile Documents/com~apple~CloudDocs/Personal",
        "/Mobile Documents/com~apple~CloudDocs/Education",
        "/Mobile Documents/com~apple~CloudDocs/Work",
        "/Mobile Documents/com~apple~CloudDocs/STEM"
    ]

    /// System-owned roots are visible to the deep audit, but never writable through
    /// the normal home-folder cleaner. Only SystemDeepScanner's narrow opt-in cards
    /// can cross this boundary.
    private static let systemRoots: [URL] = [
        URL(fileURLWithPath: "/private/tmp"),
        URL(fileURLWithPath: "/private/var/folders"),
        URL(fileURLWithPath: "/private/var/log"),
        URL(fileURLWithPath: "/private/var/vm"),
        URL(fileURLWithPath: "/private/var/db/diagnostics"),
        URL(fileURLWithPath: "/private/var/db/powerlog"),
        URL(fileURLWithPath: "/private/var/db/uuidtext"),
        URL(fileURLWithPath: "/private/var/root/.Trash"),
        URL(fileURLWithPath: "/System/Volumes/Data/.DocumentRevisions-V100"),
        URL(fileURLWithPath: "/System/Volumes/VM"),
        URL(fileURLWithPath: "/Library/Caches"),
        URL(fileURLWithPath: "/Library/Logs")
    ]

    static var extraPaths: [String] {
        get { UserDefaults.standard.stringArray(forKey: extrasKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: extrasKey) }
    }

    static var dismissedIds: [String] {
        get { UserDefaults.standard.stringArray(forKey: dismissedKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: dismissedKey) }
    }

    static func isDismissed(_ id: String) -> Bool {
        dismissedIds.contains(id)
    }

    static func dismiss(_ id: String) {
        var xs = dismissedIds
        if xs.contains(id) { return }
        xs.append(id)
        dismissedIds = xs
    }

    static func isProtected(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        if pathFragments.contains(where: { p.contains($0) }) { return true }
        if isSystemPath(p) || isSystemPath(url.standardizedFileURL.resolvingSymlinksInPath().path) {
            return true
        }
        return isExtraProtected(url)
    }

    /// Hot-loop form for the fts directory walkers: `p` must be an absolute, standardized, physical
    /// path (fts never follows symlinks), and `extras` is one snapshot of `extraPaths` — the property
    /// re-reads UserDefaults on every call. Same rules as `isProtected(_:)` without the per-call
    /// symlink resolution.
    static func isProtected(path p: String, extras: [String]) -> Bool {
        if pathFragments.contains(where: { p.contains($0) }) { return true }
        if isSystemPath(p) { return true }
        for extra in extras where p == extra || p.hasPrefix(extra + "/") {
            return true
        }
        return false
    }

    /// `systemRoots` in every spelling a path can arrive in, computed once (resolving every root on
    /// every check cost a dozen realpath syscalls per call). Foundation silently drops a leading
    /// `/private` when the short form exists (`/private/var/folders` → `/var/folders`), so both the
    /// `/private/…` and the `/var|/tmp|/etc/…` spellings are listed explicitly.
    private static let systemRootPaths: [String] = Array(Set(systemRoots.flatMap { url -> [String] in
        let raw = url.path
        var forms = [raw, url.standardizedFileURL.path, url.standardizedFileURL.resolvingSymlinksInPath().path]
        if raw.hasPrefix("/private/") {
            forms.append(String(raw.dropFirst("/private".count)))
        } else if ["/var/", "/tmp/", "/etc/"].contains(where: { raw.hasPrefix($0) }) || raw == "/tmp" {
            forms.append("/private" + raw)
        }
        return forms
    }))

    private static func isSystemPath(_ p: String) -> Bool {
        systemRootPaths.contains { p == $0 || p.hasPrefix($0 + "/") }
    }

    /// User exclusions always win, including over narrow built-in opt-in cards.
    static func isExtraProtected(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        for extra in extraPaths {
            if p == extra || p.hasPrefix(extra + "/") { return true }
        }
        return false
    }

    /// Opt-in heavy paths that live under Keep fragments but may appear as explicit cards.
    static func allowsExplicitCard(_ item: JunkItem) -> Bool {
        if DuplicateFolderScanner.isExplicitCard(item) { return true }
        if StorageIntelligenceScanner.isExplicitCard(item) { return true }
        if AIStorageScanner.isExplicitCard(item) { return true }
        if ForensicRemnantScanner.isExplicitCard(item) { return true }
        if ScreenshotProvenanceScanner.isExplicitCard(item) { return true }
        if SimilarCaptureScanner.isExplicitCard(item) { return true }
        if DeepMediaForensicsScanner.isExplicitCard(item) { return true }
        if HiddenCaptureScanner.isExplicitCard(item) { return true }
        if HiddenTreeScanner.isExplicitCard(item) { return true }
        if SystemDeepScanner.isExplicitRuntimeCard(item) { return true }
        if SystemDeepScanner.isSystemAuditCard(item) { return true }
        if item.id.hasPrefix("dev-xcode-ios") || item.id.hasPrefix("dev-sim-caches") { return true }
        if item.id.hasPrefix("ios-backup-") {
            let root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/MobileSync/Backup")
                .standardizedFileURL.path
            let path = item.url.standardizedFileURL.path
            return path.hasPrefix(root + "/") && path != root
        }
        if item.id.hasPrefix("artifact-local-") {
            return ArtifactScanner.isAllowedProtectedArtifact(item.url)
        }
        if item.id.hasPrefix("tgdesk-cache-") || item.id.hasPrefix("tgdesk-media_cache-") {
            return isTelegramDesktopCache(item.url)
        }
        return false
    }

    static func isTelegramDesktopCache(_ url: URL) -> Bool {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Telegram Desktop/tdata")
            .standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(base + "/") else { return false }
        let relative = String(path.dropFirst(base.count + 1))
        let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.count == 2,
              components[1] == "cache" || components[1] == "media_cache" else { return false }
        let userData = components[0]
        if userData == "user_data" { return true }
        guard userData.hasPrefix("user_data#") else { return false }
        let suffix = userData.dropFirst("user_data#".count)
        return !suffix.isEmpty && suffix.allSatisfy(\.isNumber)
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
