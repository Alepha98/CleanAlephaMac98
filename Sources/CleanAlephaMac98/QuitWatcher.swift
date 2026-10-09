import AppKit
import Foundation

/// Caches of apps that never get closed (Chrome, Claude, Codex, Cursor…) are refused by SessionGuard
/// while they run, so "quit it and press Clean again" was the only way. Instead, refused cache jobs
/// are queued here and a tiny background agent (`--watch`) cleans them the moment their app quits —
/// by the user, at shutdown, or for an auto-update relaunch. Every job is re-validated by Janitor
/// (Keep + SessionGuard), so a relaunched app keeps its cache until the next quit.
enum PendingCleanups {
    struct Entry: Codable, Equatable, Sendable {
        var id: String
        var module: String
        var title: String
        var path: String
        var kind: String
        var bytes: Int64
        var owner: String
        var queuedAt: Date
    }

    /// Only plain cache wipes are deferred; documents and explicit choices never are.
    static let deferrableKinds: [CleanKind: String] = [.wipeChildren: "wipeChildren", .safariNetworkCache: "safariNetworkCache"]
    static let maxAge: TimeInterval = 3 * 86_400

    static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CleanAlephaMac98/pending-cleanups.json")
    }

    static func load(from url: URL = defaultURL) -> [Entry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Entry].self, from: data)) ?? []
    }

    static func save(_ entries: [Entry], to url: URL = defaultURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = .prettyPrinted
        if entries.isEmpty { try? FileManager.default.removeItem(at: url); return }
        try? encoder.encode(entries).write(to: url, options: .atomic)
    }

    static func entry(for item: JunkItem, owner: String, now: Date = Date()) -> Entry? {
        guard let kind = deferrableKinds[item.kind] else { return nil }
        return Entry(id: item.id, module: item.module.rawValue, title: item.title.en, path: item.url.path,
                     kind: kind, bytes: item.bytes, owner: owner, queuedAt: now)
    }

    /// Upserts refused jobs (by id) and drops the ones that just succeeded or expired.
    static func merge(_ current: [Entry], refused: [Entry], finished: Set<String>, now: Date = Date()) -> [Entry] {
        var byId: [String: Entry] = [:]
        for e in current where now.timeIntervalSince(e.queuedAt) < maxAge { byId[e.id] = e }
        for e in refused { byId[e.id] = e }
        for id in finished { byId.removeValue(forKey: id) }
        return byId.values.sorted { $0.id < $1.id }
    }

    static func item(from e: Entry) -> JunkItem? {
        guard let module = Module(rawValue: e.module),
              let kind = deferrableKinds.first(where: { $0.value == e.kind })?.key else { return nil }
        return JunkItem(id: e.id, module: module, title: Line.proper(e.title), subtitle: Line.proper(e.owner),
                        url: URL(fileURLWithPath: e.path), bytes: e.bytes, selected: true, kind: kind, keepsLogins: false)
    }

    /// One pass over the queue: jobs whose app is still open stay queued, everything else is done.
    static func drain(_ entries: [Entry], clean: (JunkItem) -> CleanOutcome) -> (left: [Entry], freed: Int64, cleaned: Int, failures: [(JunkItem, CleanOutcome)]) {
        var left: [Entry] = []; var freed: Int64 = 0; var cleaned = 0; var failures: [(JunkItem, CleanOutcome)] = []
        for e in entries {
            guard let item = item(from: e) else { continue }
            let outcome = clean(item)
            if outcome.blockedApp != nil { left.append(e); continue }
            freed += outcome.freed
            if outcome.failed { failures.append((item, outcome)) } else { cleaned += 1 }
        }
        return (left, freed, cleaned, failures)
    }
}

/// `--watch`: the background agent that drains the queue when apps quit, after wake and at login.
@MainActor
enum QuitWatcher {
    private static var timer: Timer?
    private static var lastRun = Date.distantPast

    static func run() -> Never {
        CamLog.line("watch start pid=\(getpid())")
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let regular = app?.activationPolicy == .regular
            let name = app?.localizedName ?? app?.bundleIdentifier ?? "?"
            MainActor.assumeIsolated {
                guard regular else { return }           // helpers and agents come and go constantly
                schedule("quit \(name)", after: 12)     // let helpers exit and the app flush its files
            }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { schedule("wake", after: 90) }
        }
        schedule("start", after: 45)
        RunLoop.main.run()
        exit(0)
    }

    private static func schedule(_ trigger: String, after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { drainNow(trigger) }
        }
    }

    static func drainNow(_ trigger: String) {
        let queued = PendingCleanups.load()
        guard !queued.isEmpty, Date().timeIntervalSince(lastRun) > 20 else { return }
        lastRun = Date()
        let fresh = queued.filter { Date().timeIntervalSince($0.queuedAt) < PendingCleanups.maxAge }
        let result = PendingCleanups.drain(fresh, clean: Janitor.clean)
        // Re-read before writing: an auto run may have queued new jobs meanwhile.
        let finished = Set(fresh.map(\.id)).subtracting(result.left.map(\.id))
        PendingCleanups.save(PendingCleanups.merge(PendingCleanups.load(), refused: [], finished: finished))
        for (item, outcome) in result.failures { CamLog.line(Janitor.logLine("watch skip", item, outcome)) }
        if result.cleaned + result.failures.count > 0 {
            CamLog.line("watch \(trigger): cleaned \(result.cleaned) freed \(result.freed) failed \(result.failures.count) waiting \(result.left.count)")
        }
    }
}

/// The LaunchAgent that keeps `--watch` alive; installed and removed together with auto-clean.
enum WatchAgent {
    static let label = "com.alepha98.CleanAlephaMac98.watch"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    @discardableResult
    static func apply(enabled: Bool) -> Bool {
        let domain = "gui/\(getuid())"
        _ = launchctl(["bootout", "\(domain)/\(label)"])
        guard enabled else {
            try? FileManager.default.removeItem(at: plistURL)
            PendingCleanups.save([])
            return true
        }
        guard let exe = AutoAgent.executablePath() else { return false }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--watch"],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ThrottleInterval": 60,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 15,
            "StandardOutPath": AutoAgent.logURL.path,
            "StandardErrorPath": AutoAgent.logURL.path
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else { return false }
        try? FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? data.write(to: plistURL, options: .atomic)) != nil else { return false }
        return launchctl(["bootstrap", domain, plistURL.path]) == 0
    }

    private static func launchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
