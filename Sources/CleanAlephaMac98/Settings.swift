import Darwin
import Foundation

struct ScheduleSlot: Codable, Equatable, Identifiable, Sendable {
    var hour: Int
    var minute: Int

    var id: String { "\(hour):\(minute)" }

    var fraction: Double { Double(hour) + Double(minute) / 60 }

    var label: String { String(format: "%02d:%02d", hour, minute) }

    static let defaults: [ScheduleSlot] = [
        ScheduleSlot(hour: 12, minute: 0),
        ScheduleSlot(hour: 20, minute: 0)
    ]

    static func clamped(hour: Int, minute: Int) -> ScheduleSlot {
        ScheduleSlot(
            hour: min(23, max(0, hour)),
            minute: min(59, max(0, minute))
        )
    }
}

enum ScheduleStore {
    static let enabledKey = "cam98.auto.enabled"
    static let slotsKey = "cam98.auto.slots"
    static let maxSlots = 4

    static func loadEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func loadSlots() -> [ScheduleSlot] {
        if let data = UserDefaults.standard.data(forKey: slotsKey),
           let slots = try? JSONDecoder().decode([ScheduleSlot].self, from: data) {
            let cleaned = uniqueSorted(slots)
            if !cleaned.isEmpty { return cleaned }
        }
        return ScheduleSlot.defaults
    }

    static func save(enabled: Bool, slots: [ScheduleSlot]) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        if let data = try? JSONEncoder().encode(uniqueSorted(slots)) {
            UserDefaults.standard.set(data, forKey: slotsKey)
        }
    }

    static func uniqueSorted(_ slots: [ScheduleSlot]) -> [ScheduleSlot] {
        var seen = Set<String>()
        var out: [ScheduleSlot] = []
        for raw in slots {
            let slot = ScheduleSlot.clamped(hour: raw.hour, minute: raw.minute)
            if seen.contains(slot.id) { continue }
            seen.insert(slot.id)
            out.append(slot)
        }
        return out.sorted { ($0.hour, $0.minute) < ($1.hour, $1.minute) }
    }
}

enum AutoAgent {
    static let label = "com.alepha98.CleanAlephaMac98.auto"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/CleanAlephaMac98.log")
    }

    @discardableResult
    static func apply(enabled: Bool, slots: [ScheduleSlot]) -> Bool {
        let fm = FileManager.default
        let agents = plistURL.deletingLastPathComponent()
        try? fm.createDirectory(at: agents, withIntermediateDirectories: true)
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        bootout()

        guard enabled else {
            try? fm.removeItem(at: plistURL)
            return true
        }

        let times = ScheduleStore.uniqueSorted(slots)
        guard !times.isEmpty, let exe = executablePath() else { return false }

        let intervals: [[String: Int]] = times.map { ["Hour": $0.hour, "Minute": $0.minute] }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe, "--auto"],
            "StartCalendarInterval": intervals,
            "StandardOutPath": logURL.path,
            "StandardErrorPath": logURL.path,
            "RunAtLoad": false,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 15
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0) else {
            return false
        }
        do {
            try data.write(to: plistURL, options: .atomic)
        } catch {
            return false
        }
        return bootstrap()
    }

    static func executablePath() -> String? {
        let path = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    private static func domain() -> String { "gui/\(getuid())" }

    private static func bootout() {
        _ = launchctl(["bootout", "\(domain())/\(label)"])
        _ = launchctl(["bootout", domain(), plistURL.path])
    }

    private static func bootstrap() -> Bool {
        launchctl(["bootstrap", domain(), plistURL.path]) == 0
    }

    private static func launchctl(_ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus
        } catch {
            return 1
        }
    }
}

enum AutoClean {
    static func runAndExit() -> Never {
        var freed: Int64 = 0
        var failed = 0
        var causes: [String: Int] = [:]
        // Only Smart's light stages: unattended cleanup can only ever take safe Junk / Browsers /
        // Developer cards, so walking Large, Duplicates or the forensic hunts here was minutes of
        // background work whose results were always thrown away.
        for stage in Scanner.ScanStage.stages(for: .smart) {
            let chunk = Scanner.safeItems(for: stage)
            for item in chunk.items where isUnattended(item) {
                let outcome = Janitor.clean(item)
                freed += outcome.freed
                if outcome.failed {
                    failed += 1
                    CamLog.line(Janitor.logLine("auto skip", item, outcome))
                    let cause = (outcome.reason ?? "failed").split(separator: ":").first.map(String.init) ?? "failed"
                    causes[cause, default: 0] += 1
                }
            }
        }
        appendLog(freed: freed, failed: failed, causes: causes)
        Foundation.exit(0)
    }

    /// Unattended: caches only. Media, Trash, leftovers, history stay for a person to confirm.
    static func isUnattended(_ item: JunkItem) -> Bool {
        guard item.isSafePreset, item.selected else { return false }
        // Heuristically discovered caches are safe only after live revalidation, but a
        // first-time unknown app store should still require an interactive cleanup.
        if item.id.hasPrefix("intel-") { return false }
        switch item.module {
        case .junk, .browsers, .dev: return true
        default: return false
        }
    }

    /// `Maintenance.snapshot()` parses "auto done freed <n>" — keep that prefix; causes go after it.
    static func appendLog(freed: Int64, failed: Int, causes: [String: Int] = [:]) {
        let tally = causes.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        CamLog.line("auto done freed \(freed) failed \(failed)" + (tally.isEmpty ? "" : " (\(tally))"))
    }
}
