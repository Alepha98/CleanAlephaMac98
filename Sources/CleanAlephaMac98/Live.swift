import AppKit
import CoreGraphics
import Darwin
import Foundation

enum PulsePressure: String, Sendable {
    case normal, warn, critical

    var title: Line {
        switch self {
        case .normal: Copy.pressureNormal
        case .warn: Copy.pressureWarn
        case .critical: Copy.pressureCritical
        }
    }

    var cpuTitle: Line {
        switch self {
        case .normal: Copy.cpuNormal
        case .warn: Copy.cpuWarn
        case .critical: Copy.cpuCritical
        }
    }
}

struct LiveProc: Identifiable, Sendable, Equatable {
    var id: String { "\(pid)" }
    var label: String
    var bytes: Int64
    var cpu: Double
    var pid: Int32
}

struct LiveApp: Identifiable, Sendable, Equatable {
    var id: String { name }
    var name: String
    var bytes: Int64
    var cpu: Double
    var pids: [Int32]
    var children: [LiveProc]
}

struct LiveTab: Identifiable, Sendable, Equatable {
    var id: String { "\(browser)-\(window)-\(tabIndex)-\(url)" }
    var browser: String
    var title: String
    var url: String
    var estimate: Int64
    var window: Int
    var tabIndex: Int
}

struct PulseSnapshot: Sendable {
    var total: Int64
    var used: Int64
    var wired: Int64
    var compressed: Int64
    var swap: Int64
    var pressure: PulsePressure
    var cpuBusy: Double
    var loadAvg: Double
    var cpuPressure: PulsePressure
    var apps: [LiveApp]
    var tabs: [LiveTab]
    var tabAccess: Line?
}

enum FindingSeverity: String, Sendable {
    case high, medium, info
}

struct ProtectFinding: Identifiable, Sendable, Equatable {
    var id: String
    var title: Line
    var subtitle: Line
    var severity: FindingSeverity
    var url: URL?
    var bytes: Int64
    var selected: Bool
    var kind: CleanKind
}

struct StartupRow: Identifiable, Sendable, Equatable {
    var id: String
    var name: String
    var detail: Line
    var url: URL
    var ours: Bool
    var apple: Bool
    var runAtLoad: Bool
    var selected: Bool
    var kind: CleanKind
}

enum LiveProbe {
    static func pulseMemory() -> PulseSnapshot {
        CamLog.line("pulse memory begin")
        let mem = memory()
        CamLog.line("pulse memory stats used=\(mem.used) total=\(mem.total) swap=\(mem.swap)")
        let cpu = cpuLoad()
        CamLog.line("pulse cpu busy=\(Int(cpu.busy)) load=\(String(format: "%.2f", cpu.load))")
        let apps = topApps()
        CamLog.line("pulse memory apps=\(apps.count)")
        return PulseSnapshot(
            total: mem.total,
            used: mem.used,
            wired: mem.wired,
            compressed: mem.compressed,
            swap: mem.swap,
            pressure: mem.pressure,
            cpuBusy: cpu.busy,
            loadAvg: cpu.load,
            cpuPressure: cpu.pressure,
            apps: apps,
            tabs: [],
            tabAccess: nil
        )
    }

    static func pulseTabs(into snap: PulseSnapshot) -> PulseSnapshot {
        pulseTabs(into: snap, only: nil)
    }

    /// `only` – browser display names already checked on the main actor (window on screen).
    static func pulseTabs(into snap: PulseSnapshot, only allowed: Set<String>?) -> PulseSnapshot {
        let (tabs, note) = browserTabs(apps: snap.apps, only: allowed)
        var next = snap
        next.tabs = tabs
        next.tabAccess = note
        return next
    }

    /// Call on the main actor – NSWorkspace / window list are not safe off-main.
    @MainActor
    static func browsersWithWindows() -> Set<String> {
        let browsers: [(app: String, bundles: [String])] = [
            ("Safari", ["com.apple.Safari"]),
            ("Google Chrome", ["com.google.Chrome"]),
            ("Microsoft Edge", ["com.microsoft.edgemac"]),
            ("Brave Browser", ["com.brave.Browser"]),
            ("Chromium", ["org.chromium.Chromium"]),
            ("Yandex", ["ru.yandex.desktop.yandex-browser", "ru.yandex.YandexBrowser"]),
            ("Arc", ["company.thebrowser.Browser"])
        ]
        var out = Set<String>()
        for spec in browsers {
            if browserRunning(name: spec.app, bundles: spec.bundles) {
                out.insert(spec.app)
            }
        }
        CamLog.line("pulse windows \(out.sorted().joined(separator: ","))")
        return out
    }

    static func junk(fromMemory snap: PulseSnapshot) -> [JunkItem] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var ramSub = Copy.ramLine(used: snap.used, total: snap.total)
        if snap.swap > 0 {
            let swap = Copy.swapLine(snap.swap)
            ramSub = Line(ru: "\(ramSub.ru). \(swap.ru)", en: "\(ramSub.en). \(swap.en)")
        }
        let cpuSub = Copy.cpuLine(busy: snap.cpuBusy, load: snap.loadAvg)
        var rows: [JunkItem] = [
            JunkItem(
                id: "pulse-ram",
                module: .pulse,
                title: snap.pressure.title,
                subtitle: ramSub,
                url: home,
                bytes: max(snap.used, 1),
                selected: false,
                kind: .advice,
                keepsLogins: false
            ),
            JunkItem(
                id: "pulse-cpu",
                module: .pulse,
                title: snap.cpuPressure.cpuTitle,
                subtitle: cpuSub,
                url: home,
                bytes: max(Int64(snap.cpuBusy * 1_000_000), 1),
                selected: false,
                kind: .advice,
                keepsLogins: false
            ),
            // RAM composition – visible inside «Уже своп» / memory drill.
            JunkItem(
                id: "pulse-part:wired",
                module: .pulse,
                title: Copy.memWired,
                subtitle: Copy.memWiredHint,
                url: home,
                bytes: max(snap.wired, 1),
                selected: false,
                kind: .advice,
                keepsLogins: false
            ),
            JunkItem(
                id: "pulse-part:compressed",
                module: .pulse,
                title: Copy.memCompressed,
                subtitle: Copy.memCompressedHint,
                url: home,
                bytes: max(snap.compressed, 1),
                selected: false,
                kind: .advice,
                keepsLogins: false
            ),
            JunkItem(
                id: "pulse-part:swap",
                module: .pulse,
                title: Copy.memSwap,
                subtitle: Copy.memSwapHint,
                url: home,
                bytes: snap.swap,
                selected: false,
                kind: .advice,
                keepsLogins: false
            )
        ]
        // Overview: merge top RAM + top CPU so a hot CPU with little RAM still shows.
        let byRam = snap.apps.sorted { $0.bytes > $1.bytes }
        let byCpu = snap.apps.sorted { $0.cpu > $1.cpu }
        var overview: [LiveApp] = []
        var seen = Set<String>()
        for app in byRam.prefix(14) + byCpu.prefix(14) {
            if seen.insert(app.name).inserted { overview.append(app) }
        }
        for app in overview.prefix(20) {
            let tabHint = browserNames.contains(app.name)
            let base = Copy.appPerfHint(
                ram: app.bytes,
                cpu: app.cpu,
                parts: app.children.count,
                browser: tabHint
            )
            rows.append(JunkItem(
                id: "pulse-app-\(app.name)",
                module: .pulse,
                title: Copy.humanAppTitle(app.name),
                subtitle: base,
                url: home,
                bytes: max(app.bytes, 1),
                selected: false,
                kind: .advice,
                keepsLogins: false
            ))
            for child in app.children.prefix(24) {
                let childTitle = Copy.humanHelperTitle(label: child.label, app: app.name)
                let childSub = Copy.procPerfHint(ram: child.bytes, cpu: child.cpu, pid: child.pid)
                rows.append(JunkItem(
                    id: "pulse-child:\(app.name):\(child.pid):\(child.label)",
                    module: .pulse,
                    title: childTitle,
                    subtitle: childSub,
                    url: home,
                    bytes: max(child.bytes, 1),
                    selected: false,
                    kind: .advice,
                    keepsLogins: false
                ))
            }
        }
        CamLog.line("pulse junk overview=\(overview.prefix(20).count) used=\(snap.used) cpu=\(Int(snap.cpuBusy))")
        return rows
    }

    private static let browserNames: Set<String> = [
        "Safari", "Google Chrome", "Microsoft Edge", "Brave Browser", "Chromium", "Yandex", "Arc", "Firefox"
    ]

    /// Focus tokens for RAM / CPU drill-downs (not app names).
    static let pulseFocusRAM = "__ram__"
    static let pulseFocusCPU = "__cpu__"

    static func junk(fromTabs snap: PulseSnapshot) -> [JunkItem] {
        snap.tabs.map { tab in
            let host: String
            if let url = URL(string: tab.url), let h = url.host { host = h } else { host = tab.url }
            let page = tab.title.isEmpty ? host : tab.title
            return JunkItem(
                id: "pulse-tab:\(tab.window):\(tab.tabIndex):\(tab.browser)",
                module: .pulse,
                title: Copy.humanTabTitle(browser: tab.browser, page: page),
                subtitle: Copy.humanTabSubtitle(browser: tab.browser, host: host),
                url: URL(string: tab.url) ?? FileManager.default.homeDirectoryForCurrentUser,
                bytes: max(tab.estimate, 1),
                selected: false,
                kind: .closeTab,
                keepsLogins: true
            )
        }
    }

    static func junkProtect() -> [JunkItem] {
        protect().compactMap { finding in
            guard let url = finding.url else { return nil }
            return JunkItem(
                id: finding.id,
                module: .protect,
                title: finding.title,
                subtitle: finding.subtitle,
                url: url,
                bytes: max(finding.bytes, 4_096),
                selected: finding.severity == .high,
                kind: finding.kind,
                keepsLogins: false
            )
        }
    }

    static func junkStartup() -> [JunkItem] {
        junk(fromStartup: startup())
    }

    static func junk(fromStartup rows: [StartupRow]) -> [JunkItem] {
        rows.map { row in
            JunkItem(
                id: row.id,
                module: .startup,
                title: Line.proper(row.name),
                subtitle: row.detail,
                url: row.url,
                bytes: max(DiskSizer.bytes(at: row.url), 4_096),
                selected: false,
                kind: row.ours || row.apple ? .advice : row.kind,
                keepsLogins: false
            )
        }
    }

    static func startup() -> [StartupRow] {
        var rows = launchAgents() + loginItems()
        rows.sort {
            if $0.ours != $1.ours { return $0.ours && !$1.ours }
            if $0.apple != $1.apple { return !$0.apple && $1.apple }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        return rows
    }

    static func revealTab(item: JunkItem) {
        guard let tab = tab(from: item) else { return }
        revealTab(tab)
    }

    static func closeTab(item: JunkItem) -> Bool {
        guard let tab = tab(from: item) else { return false }
        return closeTab(tab)
    }

    @MainActor
    static func activateApp(item: JunkItem) {
        guard item.id.hasPrefix("pulse-app-") else { return }
        let name = String(item.id.dropFirst("pulse-app-".count))
        activateApp(named: name)
    }

    @MainActor
    static func activateApp(named name: String) {
        let apps = NSWorkspace.shared.runningApplications
        if let app = apps.first(where: { $0.localizedName == name && $0.activationPolicy == .regular }) {
            app.activate()
            return
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId(forAppName: name)) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return
        }
        let candidates = [
            "/Applications/\(name).app",
            NSHomeDirectory() + "/Applications/\(name).app"
        ]
        for path in candidates where FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
    }

    static func canQuitApp(named name: String) -> Bool {
        !Copy.isSystemProc(name)
    }

    @MainActor
    static func quitApp(named name: String) -> Bool {
        guard canQuitApp(named: name) else { return false }
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.localizedName == name && $0.activationPolicy == .regular
        }
        guard !apps.isEmpty else { return false }
        var any = false
        for app in apps {
            if app.terminate() { any = true }
        }
        return any
    }

    @MainActor
    static func appName(from item: JunkItem) -> String? {
        if item.id.hasPrefix("pulse-app-") {
            return String(item.id.dropFirst("pulse-app-".count))
        }
        if item.id.hasPrefix("pulse-child:") {
            let parts = item.id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            if parts.count >= 2 { return String(parts[1]) }
        }
        return nil
    }

    private static func bundleId(forAppName name: String) -> String {
        switch name {
        case "Safari": return "com.apple.Safari"
        case "Google Chrome": return "com.google.Chrome"
        case "Microsoft Edge": return "com.microsoft.edgemac"
        case "Brave Browser": return "com.brave.Browser"
        case "Arc": return "company.thebrowser.Browser"
        case "Telegram": return "ru.keepcoder.Telegram"
        case "Cursor": return "com.todesktop.230313mzl4w4u92"
        default: return ""
        }
    }

    private static func tab(from item: JunkItem) -> LiveTab? {
        let raw = item.id
        guard raw.hasPrefix("pulse-tab:") else { return nil }
        let rest = String(raw.dropFirst("pulse-tab:".count))
        let parts = rest.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let win = Int(parts[0]), let idx = Int(parts[1]) else { return nil }
        return LiveTab(
            browser: String(parts[2]),
            title: item.title.ru,
            url: item.url.absoluteString,
            estimate: item.bytes,
            window: win,
            tabIndex: idx
        )
    }

    static func revealTab(_ tab: LiveTab) {
        let script: String
        if tab.browser == "Safari" {
            script = """
            tell application "Safari"
              if (count of windows) ≥ \(tab.window) then
                set index of window \(tab.window) to 1
                tell window \(tab.window) to set current tab to tab \(tab.tabIndex)
              end if
              activate
            end tell
            """
        } else {
            script = """
            tell application "\(tab.browser)"
              if (count of windows) ≥ \(tab.window) then
                set index of window \(tab.window) to 1
                set active tab index of window \(tab.window) to \(tab.tabIndex)
              end if
              activate
            end tell
            """
        }
        _ = runAppleScript(script, seconds: 3)
    }

    static func closeTab(_ tab: LiveTab) -> Bool {
        let script: String
        if tab.browser == "Safari" {
            script = """
            tell application "Safari"
              if (count of windows) ≥ \(tab.window) then
                tell window \(tab.window)
                  if (count of tabs) ≥ \(tab.tabIndex) then close tab \(tab.tabIndex)
                end tell
              end if
            end tell
            """
        } else {
            script = """
            tell application "\(tab.browser)"
              if (count of windows) ≥ \(tab.window) then
                tell window \(tab.window)
                  if (count of tabs) ≥ \(tab.tabIndex) then close tab \(tab.tabIndex)
                end tell
              end if
            end tell
            """
        }
        let result = runAppleScript(script, seconds: 3)
        CamLog.line("close tab \(tab.browser) w=\(tab.window) i=\(tab.tabIndex) denied=\(result.denied) out=\(result.output.prefix(40))")
        return !result.denied
    }

    // MARK: Memory

    private static func memory() -> (total: Int64, used: Int64, wired: Int64, compressed: Int64, swap: Int64, pressure: PulsePressure) {
        var size = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        var stats = vm_statistics64()
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(size)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &size)
            }
        }
        var total: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &len, nil, 0)
        var pageSize: Int32 = 16384
        var pageLen = MemoryLayout<Int32>.size
        sysctlbyname("hw.pagesize", &pageSize, &pageLen, nil, 0)
        let page = UInt64(max(pageSize, 4096))
        guard kr == KERN_SUCCESS, total > 0 else {
            return (Int64(total), 0, 0, 0, 0, .normal)
        }
        let wired = UInt64(stats.wire_count) * page
        let active = UInt64(stats.active_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let used = min(total, wired + active + compressed)
        var swapUsage = xsw_usage()
        var swapLen = MemoryLayout<xsw_usage>.size
        sysctlbyname("vm.swapusage", &swapUsage, &swapLen, nil, 0)
        let swap = Int64(swapUsage.xsu_used)
        let frac = Double(used) / Double(total)
        let pressure: PulsePressure
        if frac >= 0.92 || swap > 1_073_741_824 { pressure = .critical }
        else if frac >= 0.78 || swap > 256_000_000 { pressure = .warn }
        else { pressure = .normal }
        return (Int64(total), Int64(used), Int64(wired), Int64(compressed), swap, pressure)
    }

    private static func cpuLoad() -> (busy: Double, load: Double, pressure: PulsePressure) {
        var samples = [Double](repeating: 0, count: 3)
        _ = samples.withUnsafeMutableBufferPointer { getloadavg($0.baseAddress, 3) }
        let load = samples[0]
        var ncpu: Int32 = 1
        var ncpuLen = MemoryLayout<Int32>.size
        sysctlbyname("hw.logicalcpu", &ncpu, &ncpuLen, nil, 0)
        let cores = max(Double(ncpu), 1)
        // Rough busy % from 1-minute load vs logical CPUs.
        let busy = min(100, max(0, (load / cores) * 100))
        let pressure: PulsePressure
        if busy >= 85 || load >= cores * 1.4 { pressure = .critical }
        else if busy >= 55 || load >= cores * 0.85 { pressure = .warn }
        else { pressure = .normal }
        return (busy, load, pressure)
    }

    private static func topApps() -> [LiveApp] {
        CamLog.line("pulse ps begin")
        let ran = CamProcess.run(
            path: "/bin/ps",
            arguments: ["-axo", "pid=,pcpu=,rss=,command="],
            timeout: 5
        )
        if ran.timedOut {
            CamLog.line("pulse ps timeout")
        } else {
            CamLog.line("pulse ps bytes=\(ran.out.utf8.count) status=\(ran.status)")
        }
        struct Acc {
            var bytes: Int64 = 0
            var cpu: Double = 0
            var pids: [Int32] = []
            var children: [LiveProc] = []
        }
        var grouped: [String: Acc] = [:]
        for line in ran.out.split(whereSeparator: \.isNewline) {
            let raw = line.trimmingCharacters(in: .whitespaces)
            let parts = raw.split(maxSplits: 3, whereSeparator: \.isWhitespace)
            guard parts.count >= 4,
                  let pid = Int32(parts[0]),
                  let cpu = Double(parts[1]),
                  let rssKB = Int64(parts[2]) else { continue }
            let command = String(parts[3])
            if shouldIgnore(command) { continue }
            let name = appName(from: command)
            let bytes = rssKB * 1024
            let label = helperLabel(from: command, app: name)
            var entry = grouped[name] ?? Acc()
            entry.bytes += bytes
            entry.cpu += cpu
            entry.pids.append(pid)
            entry.children.append(LiveProc(label: label, bytes: bytes, cpu: cpu, pid: pid))
            grouped[name] = entry
        }
        return grouped
            .map { key, acc in
                let kids = acc.children.sorted {
                    if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                    return $0.cpu > $1.cpu
                }
                return LiveApp(name: key, bytes: acc.bytes, cpu: acc.cpu, pids: acc.pids, children: kids)
            }
            .filter { $0.bytes >= 8_000_000 || $0.cpu >= 2.5 }
            .sorted {
                let sa = $0.bytes + Int64($0.cpu * 12_000_000)
                let sb = $1.bytes + Int64($1.cpu * 12_000_000)
                return sa > sb
            }
    }

    private static func helperLabel(from command: String, app: String) -> String {
        if let range = command.range(of: ".app/Contents/") {
            let after = String(command[range.upperBound...])
            let leaf = URL(fileURLWithPath: after).lastPathComponent
            if !leaf.isEmpty, leaf != app { return leaf }
        }
        if command.contains("com.apple.WebKit.WebContent") { return "WebContent" }
        if command.contains("com.apple.WebKit.GPU") { return "GPU" }
        if command.contains("com.apple.WebKit.Networking") { return "Networking" }
        let base = URL(fileURLWithPath: command.split(separator: " ").first.map(String.init) ?? command).lastPathComponent
        return base.isEmpty ? app : base
    }

    private static func shouldIgnore(_ command: String) -> Bool {
        // Keep kernel_task / WindowServer – user wants to see what they are.
        let skip = [
            "launchd", "loginwindow",
            "syspolicyd", "runningboardd", "logd", "cfprefsd",
            "CleanAlephaMac98", "chrome_crashpad", "SafariWidgetExt"
        ]
        return skip.contains { command.contains($0) }
    }

    private static func appName(from command: String) -> String {
        if command.contains("kernel_task") { return "kernel_task" }
        if command.contains("WindowServer") { return "WindowServer" }
        let map: [(String, String)] = [
            ("Google Chrome", "Google Chrome"),
            ("Microsoft Edge", "Microsoft Edge"),
            ("Brave Browser", "Brave Browser"),
            ("Yandex", "Yandex"),
            ("Firefox", "Firefox"),
            ("com.apple.WebKit", "Safari"),
            ("Safari", "Safari"),
            ("Arc.app", "Arc"),
            ("Cursor", "Cursor"),
            ("Code Helper", "Visual Studio Code"),
            ("Electron", "Electron")
        ]
        for (needle, name) in map where command.contains(needle) {
            return name
        }
        if let range = command.range(of: ".app/Contents/") {
            let prefix = String(command[..<range.lowerBound])
            return URL(fileURLWithPath: prefix).lastPathComponent
        }
        return URL(fileURLWithPath: command.split(separator: " ").first.map(String.init) ?? command).lastPathComponent
    }

    private static func browserTabs(apps: [LiveApp], only allowed: Set<String>?) -> ([LiveTab], Line?) {
        let browsers: [(app: String, scriptName: String, bundles: [String])] = [
            ("Safari", "Safari", ["com.apple.Safari"]),
            ("Google Chrome", "Google Chrome", ["com.google.Chrome"]),
            ("Microsoft Edge", "Microsoft Edge", ["com.microsoft.edgemac"]),
            ("Brave Browser", "Brave Browser", ["com.brave.Browser"]),
            ("Chromium", "Chromium", ["org.chromium.Chromium"]),
            ("Yandex", "Yandex", ["ru.yandex.desktop.yandex-browser", "ru.yandex.YandexBrowser"]),
            ("Arc", "Arc", ["company.thebrowser.Browser"])
        ]
        var tabs: [LiveTab] = []
        var denied = false
        for spec in browsers {
            let running: Bool
            if let allowed {
                running = allowed.contains(spec.app)
            } else {
                running = browserRunning(name: spec.app, bundles: spec.bundles)
            }
            guard running else {
                CamLog.line("pulse skip \(spec.app) – not running with a window")
                continue
            }
            let started = Date()
            let result = runAppleScript(tabScript(for: spec.scriptName), seconds: 2)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            if result.denied { denied = true }
            let parsed = parseTabs(result.output, browser: spec.scriptName)
            CamLog.line("pulse tabs \(spec.app) ms=\(ms) denied=\(result.denied) tabs=\(parsed.count)")
            let rss = apps.first(where: { $0.name == spec.app })?.bytes ?? 0
            let share = parsed.isEmpty ? 0 : rss / Int64(parsed.count)
            for var tab in parsed {
                tab.estimate = share
                tabs.append(tab)
            }
        }
        tabs.sort { $0.estimate > $1.estimate }
        let note: Line? = denied ? Copy.needAutomation : (tabs.isEmpty ? nil : Copy.weDontQuitBrowsers)
        return (Array(tabs.prefix(40)), note)
    }

    private static func browserRunning(name: String, bundles: [String]) -> Bool {
        NSWorkspace.shared.runningApplications.contains { app in
            guard app.activationPolicy == .regular, !app.isHidden else { return false }
            let matches: Bool
            if let id = app.bundleIdentifier, bundles.contains(id) {
                matches = true
            } else {
                matches = app.localizedName == name
            }
            guard matches else { return false }
            return hasOnscreenWindow(pid: app.processIdentifier)
        }
    }

    private static func hasOnscreenWindow(pid: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return true
        }
        return list.contains { info in
            let owner: pid_t?
            if let n = info[kCGWindowOwnerPID as String] as? NSNumber {
                owner = n.int32Value
            } else if let i = info[kCGWindowOwnerPID as String] as? Int {
                owner = pid_t(i)
            } else {
                owner = info[kCGWindowOwnerPID as String] as? pid_t
            }
            let layer: Int
            if let n = info[kCGWindowLayer as String] as? NSNumber {
                layer = n.intValue
            } else {
                layer = info[kCGWindowLayer as String] as? Int ?? 0
            }
            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let w: CGFloat
            if let n = bounds?["Width"] as? NSNumber { w = CGFloat(truncating: n) }
            else { w = bounds?["Width"] as? CGFloat ?? 0 }
            let h: CGFloat
            if let n = bounds?["Height"] as? NSNumber { h = CGFloat(truncating: n) }
            else { h = bounds?["Height"] as? CGFloat ?? 0 }
            return owner == pid && layer == 0 && w > 80 && h > 80
        }
    }

    private static func tabScript(for app: String) -> String {
        if app == "Safari" {
            return """
            if application "Safari" is running then
              tell application "Safari"
                set out to ""
                set winIndex to 1
                repeat with w in windows
                  set tabIndex to 1
                  repeat with t in tabs of w
                    set out to out & (name of t) & tab & (URL of t) & tab & winIndex & tab & tabIndex & linefeed
                    set tabIndex to tabIndex + 1
                  end repeat
                  set winIndex to winIndex + 1
                end repeat
                return out
              end tell
            end if
            return ""
            """
        }
        return """
        if application "\(app)" is running then
          tell application "\(app)"
            set out to ""
            set winIndex to 1
            repeat with w in windows
              set tabIndex to 1
              repeat with t in tabs of w
                set out to out & (title of t) & tab & (URL of t) & tab & winIndex & tab & tabIndex & linefeed
                set tabIndex to tabIndex + 1
              end repeat
              set winIndex to winIndex + 1
            end repeat
            return out
          end tell
        end if
        return ""
        """
    }

    private static func parseTabs(_ text: String, browser: String) -> [LiveTab] {
        var out: [LiveTab] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 4, let win = Int(cols[2]), let idx = Int(cols[3]) else { continue }
            let title = cols[0].isEmpty ? cols[1] : cols[0]
            out.append(LiveTab(browser: browser, title: title, url: cols[1], estimate: 0, window: win, tabIndex: idx))
        }
        return out
    }

    private static func runAppleScript(_ source: String, seconds: TimeInterval = 4) -> (output: String, denied: Bool) {
        let wrapped = """
        with timeout of \(max(1, Int(seconds))) seconds
        \(source)
        end timeout
        """
        let task = Process()
        let out = Pipe()
        let err = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", wrapped]
        task.standardOutput = out
        task.standardError = err
        do { try task.run() } catch { return ("", false) }

        let deadline = Date().addingTimeInterval(seconds + 1)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if task.isRunning {
            task.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
            CamLog.line("osascript timeout after \(Int(seconds))s")
            return ("", false)
        }

        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if !errText.isEmpty {
            CamLog.line("osascript err \(errText.replacingOccurrences(of: "\n", with: " ").prefix(180))")
        }
        if errText.contains("(-1743)") || errText.contains("not allowed to send") {
            return ("", true)
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), false)
    }

    // MARK: Protect

    /// Known Mac adware / PUP / scareware / bundlers – name fragments only.
    /// Never flag CleanMyMac / our app. Not a signature AV database.
    private static let adwareNeedles: [String] = [
        // classic adware / bundlers
        "mackeeper", "mac keeper", "zeobit", "clique", "genieo", "installmac", "installcore",
        "bundlore", "searchmarquis", "search marquis", "searchme", "websearch",
        "spigot", "conduit", "crossrider", "yontoo", "softonic",
        "shlayer", "pirrit", "vsearch", "maxoffer", "operator adware",
        "hiddad", "shedun", "osx.adware", "osx adware", "macos.adware",
        // fake cleaners / optimizers
        "advanced mac cleaner", "adware doctor", "macreviver", "mac reviver",
        "pckeeper", "pc keeper", "macprotector", "mac protector",
        "macoptimizerpro", "mac optimizer pro", "macoptimizer", "mac optimizer",
        "myosx", "imacros adware", "supermac cleaner", "super mac cleaner",
        "mac cleaner pro", "maccleaner", "disk doctor", "system mechanic",
        "cleangenius", "clean genius", "driver genius", "optimizer pro",
        "turbo cleaner", "total mac cleaner", "mac speedup", "mac speed up",
        "speedymac", "speedy mac", "mac booster", "macbooster",
        "cleanupmypro", "cleanup my pro", "cleanmymac alternatives junk",
        "macmemoryclean", "memory clean pro", "ram cleaner pro",
        "dr. cleaner", "dr cleaner", "go clean my mac", "gocleanmymac",
        "cleanmaster for mac", "clean master mac", "wisecleaner", "wise cleaner",
        "iomacsoft", "io bit", "iobit", "advanced systemcare",
        "asc mac", "malwarebytes adware", // only if named adware helper – careful
        // scareware / fake AV
        "macdefender", "mac defender", "macsecurity", "mac security alert",
        "macos virus", "apple security alert", "virus shield mac",
        "antivirus mac pro", "mac antivirus shield", "shield virus mac",
        "macguard", "mac guard", "safemac", "safe mac pro",
        // toolbars / redirects
        "couponserver", "coupon server", "dealply", "priceblink",
        "shopperpro", "shopper pro", "browser protector",
        "defaulttab", "default tab", "hoptopad", "hop to pad",
        "outobrowser", "outo browser", "webdiscover", "web discover",
        "search.conduit", "mysearchdial", "search dial",
        "ask toolbar", "babylon toolbar", "delta search",
        // crypto / miners disguised as utilities (name heuristics)
        "xmrig", "minerd", "cpuminer", "cgminer", "ethminer",
        "coinhive", "cryptonight helper",
        // RU / CIS market junk names often seen
        "амк клинер", "супер мак клинер", "оптимизатор мак",
        "ускоритель мак", "очиститель мак про",
        // installers / droppers
        "flashplayerinstaller", "flash player installer", "adobe flash installer fake",
        "java update helper adware", "quicktime installer adware",
        "downloadmanager adware", "download manager adware",
        "updatehelper adware", "update helper adware",
        "installer.app adware", "setupmac", "setup mac adware",
        "appstorehelper adware", "app store helper adware",
        // specific known families / variants
        "osx.shlayer", "osx.bundlore", "osx.genieo", "osx.pirrit",
        "osx.vsearch", "osx.mackeeper", "osx.installcore",
        "adware.macos", "pup.macos", "pup.optional",
        "macteal", "mac teal", "tealc", "premieropinion", "premier opinion",
        "opinionspinner", "opinion spinner", "crossrider",
        "luminati", "bright data sdk adware",
        "mypcbackup", "my pc backup", "reimage repair",
        "driverupdate", "driver update mac",
        "registry winmac", "winmac",
        "advancedmaccare", "advanced mac care",
        "maccare", "mac care pro", "maccarepro",
        "cleanapp", "clean app pro", // borderline – often PUP branding
        "privacy Desktop", "privacydesktop",
        "totalav", "total av mac", // often PUP bundling – keep
        "pc protect", "pcprotect",
        "restoro", "reimage",
        "stopzilla", "spysweeper",
        "errorcleaner", "error cleaner",
        "winzipper", "zipinstaller",
        // browser hijack helpers
        "searchassistant", "search assistant",
        "newtab hijack", "startpage hijack",
        "homepage hijacker", "redirectservice",
        "omnibar search", "searchomnibar"
    ]

    private static let adwareAllowExact: Set<String> = [
        "cleanmymac", "cleanmymac x", "cleanalephamac98", "cleanalephamac",
        "malwarebytes", "bitdefender", "norton", "avast", "avg", "kaspersky",
        "sophos", "intego", "clamxav", "little snitch", "lulu", "blockblock",
        "oversight", "knockknock", "reikey", "taskexplorer"
    ]

    private static func looksAdware(_ name: String) -> Bool {
        let n = name.lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        // Never flag us, CleanMyMac, or real security tools.
        for safe in adwareAllowExact where n.contains(safe) {
            return false
        }
        return adwareNeedles.contains { n.contains($0) }
    }

    static func protect() -> [ProtectFinding] {
        var out: [ProtectFinding] = []
        out.append(contentsOf: adwareApps())
        out.append(contentsOf: adwareSupport())
        out.append(contentsOf: adwareCaches())
        out.append(contentsOf: adwarePreferences())
        out.append(contentsOf: adwareInternetPlugins())
        out.append(contentsOf: shadyAgents())
        if let hosts = hostsFinding() { out.append(hosts) }
        return out.sorted { a, b in
            if a.severity.sort != b.severity.sort { return a.severity.sort < b.severity.sort }
            return a.bytes > b.bytes
        }
    }

    private static func adwareApps() -> [ProtectFinding] {
        var out: [ProtectFinding] = []
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") && looksAdware(name) {
                let url = URL(fileURLWithPath: root).appendingPathComponent(name)
                let b = DiskSizer.bytes(at: url)
                out.append(ProtectFinding(
                    id: "app-\(url.path)",
                    title: Line.proper(name.replacingOccurrences(of: ".app", with: "")),
                    subtitle: Copy.knownPUP,
                    severity: .high,
                    url: url,
                    bytes: b,
                    selected: false,
                    kind: .deleteItem
                ))
            }
        }
        return out
    }

    private static func adwareSupport() -> [ProtectFinding] {
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: support, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [ProtectFinding] = []
        for url in kids where looksAdware(url.lastPathComponent) {
            let b = DiskSizer.bytes(at: url)
            guard b > 16_384 else { continue }
            out.append(ProtectFinding(
                id: "sup-\(url.lastPathComponent)",
                title: Line.proper(url.lastPathComponent),
                subtitle: Copy.knownPUPSupport,
                severity: .high,
                url: url,
                bytes: b,
                selected: false,
                kind: .wipeChildren
            ))
        }
        return out
    }

    private static func adwareCaches() -> [ProtectFinding] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [ProtectFinding] = []
        for url in kids where looksAdware(url.lastPathComponent) {
            let b = DiskSizer.bytes(at: url)
            guard b > 16_384 else { continue }
            out.append(ProtectFinding(
                id: "cache-\(url.lastPathComponent)",
                title: Line.proper(url.lastPathComponent),
                subtitle: Copy.knownPUPCache,
                severity: .high,
                url: url,
                bytes: b,
                selected: false,
                kind: .wipeChildren
            ))
        }
        return out
    }

    private static func adwarePreferences() -> [ProtectFinding] {
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [ProtectFinding] = []
        for url in kids where url.pathExtension == "plist" && looksAdware(url.lastPathComponent) {
            out.append(ProtectFinding(
                id: "pref-\(url.lastPathComponent)",
                title: Line.proper(url.deletingPathExtension().lastPathComponent),
                subtitle: Copy.knownPUPPrefs,
                severity: .medium,
                url: url,
                bytes: max(DiskSizer.bytes(at: url), 4_096),
                selected: false,
                kind: .deleteItem
            ))
        }
        return out
    }

    private static func adwareInternetPlugins() -> [ProtectFinding] {
        let roots = [
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Internet Plug-Ins"),
            URL(fileURLWithPath: "/Library/Internet Plug-Ins")
        ]
        var out: [ProtectFinding] = []
        for root in roots {
            guard let kids = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
                continue
            }
            for url in kids where looksAdware(url.lastPathComponent) {
                let b = DiskSizer.bytes(at: url)
                out.append(ProtectFinding(
                    id: "plugin-\(url.path)",
                    title: Line.proper(url.lastPathComponent),
                    subtitle: Copy.knownPUPPlugin,
                    severity: .high,
                    url: url,
                    bytes: max(b, 4_096),
                    selected: false,
                    kind: .deleteItem
                ))
            }
        }
        return out
    }

    private static func shadyAgents() -> [ProtectFinding] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var out: [ProtectFinding] = []
        for url in kids where url.pathExtension == "plist" {
            if url.lastPathComponent.contains("CleanAlephaMac98") { continue }
            guard let dict = plist(url) else { continue }
            let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let program = programPath(dict)
            let hay = "\(url.lastPathComponent) \(label) \(program)"
            if looksAdware(hay) {
                out.append(ProtectFinding(
                    id: "ag-\(url.lastPathComponent)",
                    title: Line.proper(label),
                    subtitle: Copy.adwareAgent,
                    severity: .high,
                    url: url,
                    bytes: DiskSizer.bytes(at: url),
                    selected: false,
                    kind: .removeAgent
                ))
                continue
            }
            if program.isEmpty { continue }
            if program.contains("/Applications/") || program.hasPrefix("/usr/") || program.hasPrefix("/System/") {
                continue
            }
            if !FileManager.default.isExecutableFile(atPath: program) { continue }
            if isSigned(program) { continue }
            out.append(ProtectFinding(
                id: "unsigned-\(url.lastPathComponent)",
                title: Line.proper(label),
                subtitle: Copy.unsignedAgent,
                severity: .medium,
                url: url,
                bytes: 0,
                selected: false,
                kind: .removeAgent
            ))
        }
        return out
    }

    private static func hostsFinding() -> ProtectFinding? {
        let url = URL(fileURLWithPath: "/etc/hosts")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var extra = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if s.isEmpty || s.hasPrefix("#") { continue }
            if s.contains("127.0.0.1") || s.contains("::1") || s.contains("255.255.255.255") { continue }
            extra += 1
        }
        guard extra >= 3 else { return nil }
        return ProtectFinding(
            id: "hosts",
            title: Copy.hostsTouched,
            subtitle: Copy.hostsTouchedSub,
            severity: .medium,
            url: url,
            bytes: 0,
            selected: false,
            kind: .advice
        )
    }

    // MARK: Startup

    private static func launchAgents() -> [StartupRow] {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents")
        guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        var rows: [StartupRow] = []
        for url in kids where url.pathExtension == "plist" {
            let ours = url.lastPathComponent.contains("CleanAlephaMac98")
            let dict = plist(url) ?? [:]
            let label = (dict["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent
            let run = dict["RunAtLoad"] as? Bool ?? false
            let program = programPath(dict)
            let apple = program.hasPrefix("/System/") || program.contains("com.apple")
            rows.append(StartupRow(
                id: url.path,
                name: label,
                detail: ours ? Copy.ourAgent : (run ? Copy.runsAtLogin : Copy.agentLoaded),
                url: url,
                ours: ours,
                apple: apple,
                runAtLoad: run,
                selected: false,
                kind: .removeAgent
            ))
        }
        return rows
    }

    private static func loginItems() -> [StartupRow] {
        let result = runAppleScript("tell application \"System Events\" to get the name of every login item")
        let names = result.output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let pathsResult = runAppleScript("tell application \"System Events\" to get the path of every login item")
        let paths = pathsResult.output.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var rows: [StartupRow] = []
        for (i, name) in names.enumerated() {
            let path = i < paths.count ? paths[i] : ""
            let url = path.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser
                : URL(fileURLWithPath: path)
            let apple = path.hasPrefix("/System/") || path.hasPrefix("/Applications/") && name.contains("Photos")
            rows.append(StartupRow(
                id: "login-\(name)",
                name: name,
                detail: Copy.loginItem,
                url: url,
                ours: false,
                apple: apple,
                runAtLoad: true,
                selected: false,
                kind: .removeLoginItem
            ))
        }
        return rows
    }

    private static func plist(_ url: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
    }

    private static func programPath(_ dict: [String: Any]) -> String {
        if let args = dict["ProgramArguments"] as? [String], let first = args.first { return first }
        return dict["Program"] as? String ?? ""
    }

    private static func isSigned(_ path: String) -> Bool {
        let ran = CamProcess.run(path: "/usr/bin/codesign", arguments: ["-v", path], timeout: 3)
        return !ran.timedOut && ran.status == 0
    }
}

extension FindingSeverity {
    var sort: Int {
        switch self {
        case .high: 0
        case .medium: 1
        case .info: 2
        }
    }
}
