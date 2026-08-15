import AppKit
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    var module: Module = AppState.storedModule {
        didSet { UserDefaults.standard.set(module.rawValue, forKey: AppState.moduleKey) }
    }
    var items: [JunkItem] = []
    var scanning = false
    var cleaning = false
    var progress: Double = 0
    /// Liquid height in the orb (0…1). Idle 0.42, scan dip 0.14 → grow, results 0.88, empty 0.12.
    var orbFill: Double = 0.42
    var status = Copy.idleHint
    var lastFreed: Int64 = 0
    var didCleanThisScan = false
    var hasFDA = false
    var displayedBytes: Int64 = 0
    var scanFinished = false
    var lastFailureNote: Line?
    var statusStopped = false
    var scannedModules: Set<Module> = []
    var cleanedInModule: Module?
    /// Disk capsule/ring fill-once per session (TZ-02 §7.14).
    var didRevealDiskBar = false
    /// Protected-folder estimate for the disk ring.
    var protectedBytes: Int64 = 0
    var protectedMeasured = false
    /// First-run quiet FDA line dismissed with «Позже».
    var dismissedFirstRun: Bool = UserDefaults.standard.bool(forKey: "cam98.dismissedFirstRun")
    var showShortcuts = false
    var appearance: AppearanceChoice = AppState.storedAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: AppState.appearanceKey)
            applyAppearance()
        }
    }
    var language: LanguageChoice = AppState.storedLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppState.languageKey) }
    }
    var extraProtected: [String] = Keep.extraPaths
    var scheduleEnabled: Bool = ScheduleStore.loadEnabled()
    var scheduleSlots: [ScheduleSlot] = ScheduleStore.loadSlots()
    var scheduleNote: Line?
    var pulse: PulseSnapshot?
    var protectFindings: [ProtectFinding] = []
    var startupRows: [StartupRow] = []
    var liveBusy = false

    var copyLang: CopyLang { language.resolved() }

    private static let firstRunKey = "cam98.dismissedFirstRun"
    private static let moduleKey = "cam98.module"
    private static let appearanceKey = "cam98.appearance"
    private static let languageKey = "cam98.language"

    private static var storedModule: Module {
        Module(rawValue: UserDefaults.standard.string(forKey: moduleKey) ?? "") ?? .smart
    }

    private static var storedAppearance: AppearanceChoice {
        AppearanceChoice(rawValue: UserDefaults.standard.string(forKey: appearanceKey) ?? "") ?? .system
    }

    private static var storedLanguage: LanguageChoice {
        LanguageChoice(rawValue: UserDefaults.standard.string(forKey: languageKey) ?? "") ?? .system
    }

    @MainActor
    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    var selectedBytes: Int64 {
        visibleItems().reduce(0) { $0 + ($1.selected && $1.bytes > 0 ? $1.bytes : 0) }
    }

    /// All non-zero cards in the current layer — what we found, not only selection.
    var foundBytes: Int64 {
        visibleItems().filter { $0.bytes > 0 }.reduce(0) { $0 + $1.bytes }
    }

    @ObservationIgnored
    private var measuringProtected = false
    @ObservationIgnored
    private var workTask: Task<Void, Never>?

    func requestProtectedMeasure(force: Bool = false) {
        if measuringProtected { return }
        if protectedMeasured && !force { return }
        measuringProtected = true
        Task { @MainActor in
            let n = await Background.run { Scanner.protectedBytes() }
            withAnimation(Motion.easeDisk) {
                protectedBytes = n
                protectedMeasured = true
            }
            measuringProtected = false
        }
    }

    var isBusy: Bool { scanning || cleaning }

    var canScan: Bool { !isBusy }

    var canClean: Bool {
        !isBusy && module.isCleanupModule && hasScannedCurrent() && selectedBytes > 0
    }

    var canSelectSafe: Bool {
        !isBusy && module.isCleanupModule && hasScannedCurrent() && visibleItems().contains { $0.bytes > 0 }
    }

    var canDeselect: Bool {
        !isBusy && visibleItems().contains { $0.selected && $0.bytes > 0 }
    }

    var canCancel: Bool { isBusy }

    var showFirstRunQuiet: Bool { !hasFDA && !dismissedFirstRun }

    func dismissFirstRun() {
        dismissedFirstRun = true
        UserDefaults.standard.set(true, forKey: Self.firstRunKey)
    }

    func hasScannedCurrent() -> Bool {
        hasScanned(module)
    }

    func hasScanned(_ m: Module) -> Bool {
        if m == .space || m == .tools || m.isLiveModule { return false }
        if scannedModules.contains(.smart) { return true }
        if m == .smart { return !scannedModules.isEmpty }
        return scannedModules.contains(m)
    }

    func bytes(in module: Module) -> Int64 {
        items.filter { $0.module == module && $0.bytes > 0 }.reduce(0) { $0 + $1.bytes }
    }

    func sidebarBytes(for module: Module) -> Int64 {
        if module == .space || module == .tools || module.isLiveModule { return 0 }
        if module == .smart {
            return items.filter { $0.bytes > 0 }.reduce(0) { $0 + $1.bytes }
        }
        return bytes(in: module)
    }

    func visibleItems() -> [JunkItem] {
        let pool = cleaning ? items : items.filter { $0.bytes > 0 }
        let scoped = module == .smart ? pool : pool.filter { $0.module == module }
        return scoped.sorted {
            if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
            return $0.title.ru.localizedStandardCompare($1.title.ru) == .orderedAscending
        }
    }

    func refreshFDA() {
        let probe = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Messages/Attachments")
        hasFDA = (try? FileManager.default.contentsOfDirectory(atPath: probe.path)) != nil
        if hasFDA { dismissedFirstRun = true }
    }

    func openFDA() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles") else {
            lastFailureNote = Copy.fdaOpenFail
            return
        }
        if !NSWorkspace.shared.open(url) {
            lastFailureNote = Copy.fdaOpenFail
        }
    }

    func exclude(_ item: JunkItem) {
        guard !isBusy else { return }
        Keep.addExtra(item.url)
        extraProtected = Keep.extraPaths
        items.removeAll { Keep.isProtected($0.url) }
        withAnimation(Motion.easeMicro) {
            displayedBytes = selectedBytes
        }
        requestProtectedMeasure(force: true)
    }

    func removeExclusion(_ path: String) {
        Keep.removeExtra(path)
        extraProtected = Keep.extraPaths
        requestProtectedMeasure(force: true)
    }

    func pickExclusions() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = Copy.addFolder.t(copyLang)
        panel.message = Copy.addFolderHelp.t(copyLang)
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        let finish: (NSApplication.ModalResponse) -> Void = { [self] response in
            Task { @MainActor in
                guard response == .OK else { return }
                for url in panel.urls {
                    Keep.addExtra(url)
                }
                extraProtected = Keep.extraPaths
                items.removeAll { Keep.isProtected($0.url) }
                displayedBytes = selectedBytes
                requestProtectedMeasure(force: true)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    func setScheduleEnabled(_ on: Bool) {
        persistSchedule(enabled: on, slots: scheduleSlots)
    }

    func addScheduleSlot() {
        guard scheduleSlots.count < ScheduleStore.maxSlots else { return }
        let used = Set(scheduleSlots.map(\.hour))
        let candidates = [9, 12, 18, 21, 8, 15, 22, 7, 10, 14, 16, 19]
        let hour = candidates.first { !used.contains($0) } ?? ((scheduleSlots.last?.hour ?? 12) + 1) % 24
        var slots = scheduleSlots
        slots.append(ScheduleSlot(hour: hour, minute: 0))
        persistSchedule(enabled: scheduleEnabled, slots: slots)
    }

    func removeScheduleSlot(_ id: String) {
        guard scheduleSlots.count > 1 else { return }
        persistSchedule(enabled: scheduleEnabled, slots: scheduleSlots.filter { $0.id != id })
    }

    func updateScheduleSlot(_ id: String, hour: Int, minute: Int) {
        var slots = scheduleSlots
        guard let i = slots.firstIndex(where: { $0.id == id }) else { return }
        slots[i] = ScheduleSlot.clamped(hour: hour, minute: minute)
        persistSchedule(enabled: scheduleEnabled, slots: slots)
    }

    func refreshAgentIfNeeded() {
        if scheduleEnabled {
            _ = AutoAgent.apply(enabled: true, slots: scheduleSlots)
        }
    }

    private func persistSchedule(enabled: Bool, slots: [ScheduleSlot]) {
        let cleaned = ScheduleStore.uniqueSorted(slots)
        let nextSlots = cleaned.isEmpty ? ScheduleSlot.defaults : cleaned
        let ok = AutoAgent.apply(enabled: enabled, slots: nextSlots)
        if ok {
            scheduleEnabled = enabled
            scheduleSlots = nextSlots
            scheduleNote = nil
            ScheduleStore.save(enabled: enabled, slots: nextSlots)
        } else {
            scheduleNote = Copy.scheduleFail
        }
    }

    func toggle(_ id: String) {
        guard !isBusy else { return }
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].selected.toggle()
        withAnimation(Motion.easeMicro) {
            displayedBytes = selectedBytes
        }
    }

    func selectSafeVisible() {
        guard !isBusy else { return }
        let ids = Set(visibleItems().filter { $0.bytes > 0 }.map(\.id))
        for i in items.indices where ids.contains(items[i].id) {
            items[i].selected = items[i].isSafePreset
        }
        withAnimation(Motion.easeMicro) {
            displayedBytes = selectedBytes
        }
    }

    func deselectVisible() {
        guard !isBusy else { return }
        let ids = Set(visibleItems().map(\.id))
        for i in items.indices where ids.contains(items[i].id) {
            items[i].selected = false
        }
        withAnimation(Motion.easeMicro) {
            displayedBytes = selectedBytes
        }
    }

    @MainActor
    func requestScan() {
        guard canScan else { return }
        if module.isLiveModule {
            refreshLive(module)
            return
        }
        if !module.isCleanupModule {
            module = .smart
        }
        workTask = Task { @MainActor in
            await scan()
        }
    }

    @MainActor
    func requestClean() {
        guard module.isCleanupModule, !isBusy else { return }
        workTask = Task { @MainActor in
            await clean()
        }
    }

    @MainActor
    func cancelWork() {
        workTask?.cancel()
    }

    @MainActor
    func scan() async {
        guard !scanning, !cleaning else { return }
        let scope = module
        let stages = Scanner.ScanStage.stages(for: scope)
        guard !stages.isEmpty else { return }

        scanning = true
        scanFinished = false
        cleaning = false
        lastFailureNote = nil
        statusStopped = false
        displayedBytes = 0
        progress = 0
        refreshFDA()

        if scope == .smart {
            items = []
            scannedModules = []
            lastFreed = 0
            didCleanThisScan = false
            cleanedInModule = nil
        } else {
            items.removeAll { $0.module == scope }
            scannedModules.remove(scope)
        }

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var completed = false
        defer {
            if !completed {
                scanning = false
                if Task.isCancelled {
                    lastFailureNote = nil
                    let hasFinds = items.contains { $0.bytes > 0 }
                    scanFinished = hasFinds
                    statusStopped = true
                    status = hasFinds ? Copy.scanStoppedPartial : Copy.scanStoppedEmpty
                    withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
                        orbFill = hasFinds ? 0.88 : 0.42
                    }
                } else {
                    scanFinished = true
                    if lastFailureNote == nil {
                        lastFailureNote = Copy.scanBroke
                    }
                    status = lastFailureNote ?? status
                }
            }
        }

        withAnimation(reduce ? .easeInOut(duration: 0.20) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
            orbFill = 0.14
        }
        try? await Task.sleep(nanoseconds: reduce ? 80_000_000 : 180_000_000)
        if Task.isCancelled { return }

        var stageErrors = 0
        let n = max(stages.count, 1)
        for (i, stage) in stages.enumerated() {
            if Task.isCancelled { return }
            status = Copy.scanning(stage.module.name)
            let targetProgress = Double(i + 1) / Double(n)
            let targetFill = 0.14 + 0.78 * targetProgress
            withAnimation(Motion.level(reduce: reduce)) {
                progress = targetProgress
                orbFill = targetFill
            }
            let chunk = await Background.run {
                Scanner.safeItems(for: stage)
            }
            if Task.isCancelled { return }
            if chunk.failed { stageErrors += 1 }
            items.append(contentsOf: chunk.items)
            scannedModules.insert(stage.module)
            displayedBytes = selectedBytes
        }

        if scope == .smart {
            scannedModules.insert(.smart)
            for m in Module.allCases where m.isCleanupModule { scannedModules.insert(m) }
        }

        progress = 1
        let empty = visibleItems().isEmpty
        withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
            scanning = false
            scanFinished = true
            orbFill = empty ? 0.12 : 0.88
        }
        if stageErrors > 0 {
            lastFailureNote = Copy.partialRead(stageErrors)
        }
        if empty {
            status = hasFDA ? Copy.foldersClean : Copy.foldersCleanFDA
        } else {
            status = Copy.canClear(selected: selectedBytes, found: foundBytes)
        }
        if let note = lastFailureNote {
            status = Line(ru: "\(status.ru) \(note.ru)", en: "\(status.en) \(note.en)")
        }
        completed = true
        GlassTick.play()
    }

    @MainActor
    func clean() async {
        guard !cleaning, !scanning else { return }
        let jobs = visibleItems().filter { $0.selected && $0.bytes > 0 }
        guard !jobs.isEmpty else { return }

        let startSelected = jobs.reduce(Int64(0)) { $0 + $1.bytes }
        var freed: Int64 = 0
        var remaining = startSelected
        var failed = 0
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(Motion.easeMicro) {
            cleaning = true
            lastFailureNote = nil
            status = Copy.cleaningStatus
            progress = 0
            displayedBytes = startSelected
        }

        defer {
            cleaning = false
        }

        for (offset, item) in jobs.enumerated() {
            if Task.isCancelled { break }
            let outcome = await Background.run { Janitor.clean(item) }
            freed += outcome.freed
            if outcome.failed {
                failed += 1
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].selected = false
                    if outcome.leftover > 0 {
                        items[i].bytes = outcome.leftover
                    }
                }
            } else {
                remaining = max(0, remaining - item.bytes)
                if let i = items.firstIndex(where: { $0.id == item.id }) {
                    items[i].bytes = 0
                    items[i].selected = false
                }
            }
            let ratio = startSelected > 0 ? Double(remaining) / Double(startSelected) : 0
            let targetFill = 0.20 + 0.68 * ratio
            withAnimation(Motion.level(reduce: reduce)) {
                progress = Double(offset + 1) / Double(max(jobs.count, 1))
                displayedBytes = remaining
                orbFill = targetFill
            }
        }

        lastFreed = freed
        let allGone = items.filter { $0.bytes > 0 && (module == .smart || $0.module == module) }.isEmpty
        withAnimation(Motion.level(reduce: reduce)) {
            orbFill = allGone ? (freed > 0 ? 0.20 : 0.12) : max(0.20, orbFill)
            if remaining == 0 { displayedBytes = 0 }
        }
        // TZ-02 §3.6: hold the low waterline before the done state.
        if freed > 0 {
            try? await Task.sleep(nanoseconds: reduce ? 180_000_000 : 420_000_000)
        }

        if Task.isCancelled {
            lastFailureNote = nil
            if freed > 0 {
                didCleanThisScan = true
                cleanedInModule = module
                status = Copy.stoppedFreed(freed)
            } else {
                status = Copy.cleanStoppedEmpty
            }
            withAnimation(Motion.easeMicro) {
                items.removeAll { $0.bytes <= 0 }
            }
            return
        }

        didCleanThisScan = true
        cleanedInModule = module

        if failed == 0 {
            status = freed > 0 ? Copy.doneFreed(freed) : Copy.alreadyGone
        } else if freed > 0 {
            status = Copy.someFailed(freed: freed, failed: failed)
            lastFailureNote = status
        } else {
            status = Copy.nothingDeleted
            lastFailureNote = status
        }
        GlassTick.play()
        withAnimation(Motion.easeMicro) {
            items.removeAll { $0.bytes <= 0 }
        }
    }

    func refreshLive(_ module: Module) {
        guard module.isLiveModule, !liveBusy else { return }
        liveBusy = true
        Task { @MainActor in
            switch module {
            case .pulse:
                let mem = await Background.run { LiveProbe.pulseMemory() }
                pulse = mem
                let withTabs = await Background.run { LiveProbe.pulseTabs(into: mem) }
                if self.module == .pulse {
                    pulse = withTabs
                }
            case .protect:
                protectFindings = await Background.run { LiveProbe.protect() }
            case .startup:
                startupRows = await Background.run { LiveProbe.startup() }
            default:
                break
            }
            liveBusy = false
        }
    }

    func toggleProtect(_ id: String) {
        guard let i = protectFindings.firstIndex(where: { $0.id == id }) else { return }
        guard protectFindings[i].kind != .advice else { return }
        protectFindings[i].selected.toggle()
    }

    func toggleStartup(_ id: String) {
        guard let i = startupRows.firstIndex(where: { $0.id == id }) else { return }
        let row = startupRows[i]
        guard !row.ours, !row.apple else { return }
        startupRows[i].selected.toggle()
    }

    func cleanProtect() {
        guard !liveBusy else { return }
        liveBusy = true
        let jobs = protectFindings.filter { $0.selected && $0.kind != .advice }
        Task { @MainActor in
            for finding in jobs {
                let item = JunkItem(
                    id: finding.id,
                    module: .protect,
                    title: finding.title,
                    subtitle: finding.subtitle,
                    url: finding.url ?? FileManager.default.homeDirectoryForCurrentUser,
                    bytes: finding.bytes,
                    selected: true,
                    kind: finding.kind,
                    keepsLogins: false
                )
                _ = await Background.run { Janitor.clean(item) }
            }
            protectFindings = await Background.run { LiveProbe.protect() }
            liveBusy = false
        }
    }

    func cleanStartup() {
        guard !liveBusy else { return }
        liveBusy = true
        let jobs = startupRows.filter { $0.selected && !$0.ours && !$0.apple }
        Task { @MainActor in
            for row in jobs {
                let item = JunkItem(
                    id: row.id,
                    module: .startup,
                    title: Line.proper(row.name),
                    subtitle: row.detail,
                    url: row.url,
                    bytes: 0,
                    selected: true,
                    kind: row.kind,
                    keepsLogins: false
                )
                _ = await Background.run { Janitor.clean(item) }
            }
            startupRows = await Background.run { LiveProbe.startup() }
            liveBusy = false
        }
    }
}

enum Background {
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: work())
            }
        }
    }
}
