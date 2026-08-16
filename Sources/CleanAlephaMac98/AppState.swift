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
    /// 0…1 rose wash over the shell when the theme flips.
    var themeWash: Double = 0
    var themeWashNight = false
    @ObservationIgnored
    private var themeWashToken = 0
    var language: LanguageChoice = AppState.storedLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: AppState.languageKey) }
    }
    var extraProtected: [String] = Keep.extraPaths
    var scheduleEnabled: Bool = ScheduleStore.loadEnabled()
    var scheduleSlots: [ScheduleSlot] = ScheduleStore.loadSlots()
    var scheduleNote: Line?
    var pulse: PulseSnapshot?
    /// Drill-down into one app inside Performance (nil = overview).
    var pulseFocus: String?
    /// Nested drill: RAM → app → back to RAM, not straight to overview.
    var pulseFocusStack: [String] = []
    /// When opened from Smart overview tiles – Back returns to Smart.
    var returnToModule: Module?
    /// Modules where the user pressed «Scan again» and is back on the home orb.
    var resultsDismissed: Set<Module> = []

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

    @MainActor
    func chooseAppearance(_ next: AppearanceChoice) {
        guard next != appearance else { return }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        themeWashToken += 1
        let token = themeWashToken
        if !reduce {
            switch next {
            case .dark: themeWashNight = true
            case .light: themeWashNight = false
            case .system:
                themeWashNight = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            }
            withAnimation(Motion.themeWashIn) {
                themeWash = 1
            }
        }
        withAnimation(reduce ? Motion.easeReduced : Motion.themeCross) {
            appearance = next
        }
        guard !reduce else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 320_000_000)
            guard token == themeWashToken else { return }
            withAnimation(Motion.themeWashOut) {
                themeWash = 0
            }
        }
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
    @ObservationIgnored
    private var workGeneration = 0
    /// Module currently being scanned/cleaned – sidebar stays open for the rest.
    @ObservationIgnored
    private(set) var busyModule: Module?
    /// Which cleanup layer the Smart scan is on right now (for accent tiles).
    var scanningStage: Module?

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
        if m == .space || m == .tools { return false }
        if resultsDismissed.contains(m) { return false }
        // Smart only after an actual smart scan – never borrow a single layer scan.
        if m == .smart { return scannedModules.contains(.smart) }
        // After smart scan, every cleanup layer (not live) has those results ready.
        if scannedModules.contains(.smart) && m.isCleanupModule && !m.isLiveModule { return true }
        return scannedModules.contains(m)
    }

    /// Smart Care family tile → best layer, with Back to Smart.
    func openCareKind(_ kind: SmartCareKind) {
        let scored: [(Module, Int64)] = kind.modules.map { mod in
            let sum = items.filter { $0.module == mod && $0.bytes > 0 }.reduce(Int64(0)) { $0 + $1.bytes }
            return (mod, sum)
        }
        let pick = scored.max(by: { $0.1 < $1.1 })?.0 ?? kind.modules[0]
        openModuleFromSmart(pick)
    }

    /// CleanMyMac-style overview rows after Smart Scan.
    func smartOverviewModules() -> [Module] {
        [.junk, .mail, .trash, .leftovers, .large, .duplicates, .browsers, .dev, .messengers]
    }

    func selectModule(_ m: Module) {
        if isBusy, busyModule != m {
            cancelWork()
        }
        withAnimation(Motion.springUI) {
            if m != .pulse {
                pulseFocus = nil
                pulseFocusStack.removeAll()
            }
            // Sidebar / shortcuts leave Smart breadcrumb; tiles use openModuleFromSmart.
            returnToModule = nil
            module = m
        }
    }

    /// Smart overview tile → layer, with Back to Smart.
    func openModuleFromSmart(_ m: Module) {
        guard m != .smart else { return }
        withAnimation(Motion.springUI) {
            returnToModule = .smart
            pulseFocus = nil
            pulseFocusStack.removeAll()
            module = m
        }
    }

    var canNavigateBack: Bool {
        pulseFocus != nil || returnToModule != nil
    }

    var navigateBackLabel: String {
        if pulseFocus != nil { return pulseBackLabel }
        if returnToModule == .smart { return Copy.backToSmart.t(copyLang) }
        return Copy.pulseBack.t(copyLang)
    }

    func navigateBack() {
        if pulseFocus != nil {
            closePulseFocus()
            return
        }
        if let back = returnToModule {
            withAnimation(Motion.springUI) {
                returnToModule = nil
                module = back
            }
        }
    }

    func openPulseApp(_ name: String) {
        guard module == .pulse, !isBusy else { return }
        withAnimation(Motion.springUI) {
            if let cur = pulseFocus, cur != name {
                pulseFocusStack.append(cur)
            }
            pulseFocus = name
        }
    }

    func openPulseRam() {
        openPulseApp(LiveProbe.pulseFocusRAM)
    }

    func openPulseCpu() {
        openPulseApp(LiveProbe.pulseFocusCPU)
    }

    func closePulseFocus() {
        withAnimation(Motion.springUI) {
            if let prev = pulseFocusStack.popLast() {
                pulseFocus = prev
            } else {
                pulseFocus = nil
            }
        }
    }

    func exitPulseFocus() {
        withAnimation(Motion.springUI) {
            pulseFocusStack.removeAll()
            pulseFocus = nil
        }
    }

    var pulseFocusTitle: String {
        guard let focus = pulseFocus else { return "" }
        if focus == LiveProbe.pulseFocusRAM { return Copy.pulseRamFocus.t(copyLang) }
        if focus == LiveProbe.pulseFocusCPU { return Copy.pulseCpuFocus.t(copyLang) }
        return Copy.humanAppTitle(focus).t(copyLang)
    }

    var pulseFocusSubtitle: String {
        ""
    }

    var pulseBackLabel: String {
        pulseFocusStack.isEmpty ? Copy.pulseBackOverview.t(copyLang) : Copy.pulseBack.t(copyLang)
    }

    private func pulseCpuScore(_ item: JunkItem) -> Double {
        guard let snap = pulse else { return 0 }
        if item.id.hasPrefix("pulse-app-") {
            let name = String(item.id.dropFirst("pulse-app-".count))
            return snap.apps.first { $0.name == name }?.cpu ?? 0
        }
        if item.id.hasPrefix("pulse-child:") {
            let parts = item.id.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
            // pulse-child:app:pid:label
            if parts.count >= 3, let pid = Int32(parts[2]),
               let app = snap.apps.first(where: { $0.name == String(parts[1]) }) {
                return app.children.first { $0.pid == pid }?.cpu ?? 0
            }
        }
        return 0
    }

    private func pulseVisible(from pool: [JunkItem]) -> [JunkItem] {
        let pulse = pool.filter { $0.module == .pulse }
        guard let focus = pulseFocus else {
            return pulse.filter {
                $0.id == "pulse-ram" || $0.id == "pulse-cpu" || $0.id.hasPrefix("pulse-app-")
            }
        }
        if focus == LiveProbe.pulseFocusRAM {
            let parts = pulse.filter { $0.id.hasPrefix("pulse-part:") }
            let apps = pulse.filter { $0.id.hasPrefix("pulse-app-") }
                .sorted { $0.bytes > $1.bytes }
            return parts.sorted { $0.bytes > $1.bytes } + apps
        }
        if focus == LiveProbe.pulseFocusCPU {
            // Hot apps + helpers by CPU% – even when RAM is tiny.
            let apps = pulse.filter {
                $0.id.hasPrefix("pulse-app-") && pulseCpuScore($0) >= 0.5
            }
            let kids = pulse.filter {
                $0.id.hasPrefix("pulse-child:") && pulseCpuScore($0) >= 1.0
            }
            return Array((apps + kids).sorted { pulseCpuScore($0) > pulseCpuScore($1) }.prefix(40))
        }
        return pulse.filter { item in
            if item.id.hasPrefix("pulse-child:\(focus):") { return true }
            if item.id.hasPrefix("pulse-tab:"), item.id.hasSuffix(":\(focus)") { return true }
            return false
        }
    }

    /// «Scan again» – back to the centered orb; user presses Scan themselves.
    func prepareRescan() {
        guard !isBusy else { return }
        resultsDismissed.insert(module)
        pulseFocus = nil
        pulseFocusStack.removeAll()
        // Keep returnToModule so Back still works after rescan home.
        scanFinished = false
        statusStopped = false
        lastFailureNote = nil
        didCleanThisScan = false
        status = module == .smart ? Copy.idleHint : module.blurb
        withAnimation(Motion.springOrb) {
            orbFill = 0.42
            progress = 0
            displayedBytes = 0
        }
    }

    func bytes(in module: Module) -> Int64 {
        items.filter { $0.module == module && $0.bytes > 0 }.reduce(0) { $0 + $1.bytes }
    }

    func sidebarBytes(for module: Module) -> Int64 {
        if module == .space || module == .tools { return 0 }
        if module == .pulse, let p = pulse, hasScanned(.pulse) { return p.used }
        if module == .smart {
            return items.filter { $0.bytes > 0 && !$0.module.isLiveModule }.reduce(0) { $0 + $1.bytes }
        }
        return bytes(in: module)
    }

    func visibleItems() -> [JunkItem] {
        let pool = cleaning ? items : items.filter { $0.bytes > 0 }
        let scoped: [JunkItem]
        if module == .smart {
            scoped = pool.filter { !$0.module.isLiveModule }
        } else if module == .pulse {
            scoped = pulseVisible(from: pool)
        } else {
            scoped = pool.filter { $0.module == module }
        }
        // CPU drill already sorted by CPU; don't re-sort by bytes.
        if module == .pulse, pulseFocus == LiveProbe.pulseFocusCPU {
            return scoped
        }
        if module == .pulse, pulseFocus == LiveProbe.pulseFocusRAM {
            return scoped
        }
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

    func markClosed(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].bytes = 0
        items[i].selected = false
        withAnimation(Motion.easeMicro) {
            displayedBytes = selectedBytes
            items.removeAll { $0.bytes <= 0 && $0.id.hasPrefix("pulse-tab:") }
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
        if !module.isCleanupModule {
            module = .smart
        }
        resultsDismissed.remove(module)
        if module == .smart {
            resultsDismissed.removeAll()
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
        if canNavigateBack, !scanning, !cleaning {
            navigateBack()
            return
        }
        workGeneration += 1
        workTask?.cancel()
        workTask = nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if scanning {
            let scope = busyModule ?? module
            scanning = false
            busyModule = nil
            let hasFinds = items.contains { $0.bytes > 0 && (scope == .smart ? !$0.module.isLiveModule : $0.module == scope) }
            scanFinished = hasFinds
            statusStopped = true
            status = hasFinds ? Copy.scanStoppedPartial : Copy.scanStoppedEmpty
            if hasFinds {
                scannedModules.insert(scope)
                if scope == .smart {
                    for m in Module.allCases where m.isCleanupModule && !m.isLiveModule {
                        scannedModules.insert(m)
                    }
                }
            }
            withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
                orbFill = hasFinds ? 0.88 : 0.42
                progress = hasFinds ? 1 : 0
            }
            CamLog.line("cancel scan \(scope.rawValue) finds=\(hasFinds)")
        }
        if cleaning {
            cleaning = false
            busyModule = nil
            statusStopped = true
            if lastFreed > 0 {
                status = Copy.stoppedFreed(lastFreed)
            } else {
                status = Copy.cleanStoppedEmpty
            }
            CamLog.line("cancel clean")
        }
    }

    private func isCurrentWork(_ gen: Int) -> Bool {
        gen == workGeneration && !Task.isCancelled
    }

    @MainActor
    func scan() async {
        guard !scanning, !cleaning else { return }
        let scope = module
        if scope.isLiveModule {
            await scanLive(scope)
            return
        }
        let stages = Scanner.ScanStage.stages(for: scope)
        guard !stages.isEmpty else { return }

        let gen = workGeneration
        busyModule = scope
        scanning = true
        scanningStage = nil
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
            resultsDismissed.removeAll()
        } else {
            items.removeAll { $0.module == scope }
            scannedModules.remove(scope)
            // Layer scan must not make Smart look scanned.
            scannedModules.remove(.smart)
        }

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var completed = false
        defer {
            if busyModule == scope { busyModule = nil }
            if isCurrentWork(gen) { scanningStage = nil }
            if !completed, isCurrentWork(gen) {
                scanning = false
                lastFailureNote = nil
                let hasFinds = items.contains {
                    $0.bytes > 0 && (scope == .smart ? !$0.module.isLiveModule : $0.module == scope)
                }
                scanFinished = hasFinds
                statusStopped = true
                status = hasFinds ? Copy.scanStoppedPartial : Copy.scanStoppedEmpty
                withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
                    orbFill = hasFinds ? 0.88 : 0.42
                }
            }
        }

        withAnimation(reduce ? .easeInOut(duration: 0.20) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
            orbFill = 0.14
        }
        try? await Task.sleep(nanoseconds: reduce ? 80_000_000 : 180_000_000)
        guard isCurrentWork(gen) else { return }

        var stageErrors = 0
        let n = max(stages.count, 1)
        CamLog.line("scan start \(scope.rawValue) stages=\(n)")
        for (i, stage) in stages.enumerated() {
            guard isCurrentWork(gen) else { return }
            scanningStage = stage.module
            if module == scope {
                status = Copy.scanning(stage.module.name)
                let targetProgress = Double(i + 1) / Double(n)
                let targetFill = 0.14 + 0.78 * targetProgress
                withAnimation(Motion.level(reduce: reduce)) {
                    progress = targetProgress
                    orbFill = targetFill
                }
            }
            let chunk = await Background.run {
                Scanner.safeItems(for: stage)
            }
            guard isCurrentWork(gen) else { return }
            if chunk.failed { stageErrors += 1 }
            items.append(contentsOf: chunk.items)
            scannedModules.insert(stage.module)
            if module == scope {
                displayedBytes = selectedBytes
            }
            // Soft CPU budget between stages.
            await ScanThrottle.pace(heavy: stage == .large || stage == .duplicates || stage == .leftovers)
        }

        guard isCurrentWork(gen) else { return }
        scanningStage = nil

        if scope == .smart {
            scannedModules.insert(.smart)
            for m in Module.allCases where m.isCleanupModule && !m.isLiveModule { scannedModules.insert(m) }
        } else {
            scannedModules.insert(scope)
        }

        let empty = items.filter {
            $0.bytes > 0 && (scope == .smart ? !$0.module.isLiveModule : $0.module == scope)
        }.isEmpty
        withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
            scanning = false
            if module == scope {
                scanFinished = true
                orbFill = empty ? 0.12 : 0.88
                progress = 1
            }
        }
        if module == scope {
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
            displayedBytes = selectedBytes
        }
        completed = true
        CamLog.line("scan done \(scope.rawValue) items=\(items.filter { $0.module == scope || scope == .smart }.count) empty=\(empty) errors=\(stageErrors)")
        if module == scope { GlassTick.play() }
    }

    @MainActor
    func scanLive(_ scope: Module) async {
        let gen = workGeneration
        busyModule = scope
        scanning = true
        scanFinished = false
        cleaning = false
        lastFailureNote = nil
        statusStopped = false
        displayedBytes = 0
        progress = 0
        refreshFDA()
        items.removeAll { $0.module == scope }
        scannedModules.remove(scope)

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        var completed = false
        defer {
            if busyModule == scope { busyModule = nil }
            if !completed, isCurrentWork(gen) {
                scanning = false
                lastFailureNote = nil
                let hasFinds = items.contains { $0.module == scope && $0.bytes > 0 }
                scanFinished = hasFinds
                statusStopped = true
                status = hasFinds ? Copy.scanStoppedPartial : Copy.scanStoppedEmpty
                withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
                    orbFill = hasFinds ? 0.88 : 0.42
                }
                if hasFinds { scannedModules.insert(scope) }
            }
        }

        withAnimation(reduce ? .easeInOut(duration: 0.20) : .timingCurve(0.22, 1, 0.36, 1, duration: 0.18)) {
            orbFill = 0.14
        }
        try? await Task.sleep(nanoseconds: reduce ? 80_000_000 : 180_000_000)
        guard isCurrentWork(gen) else { return }

        if module == scope {
            status = Copy.scanning(scope.name)
            withAnimation(Motion.level(reduce: reduce)) {
                progress = 0.2
                orbFill = 0.3
            }
        }

        CamLog.line("scanLive start \(scope.rawValue)")
        switch scope {
        case .pulse:
            // RAM + CPU first (fast). Tabs are separate and never block the Stop / results UI.
            pulseFocus = nil
            pulseFocusStack.removeAll()
            let mem = await Background.run { LiveProbe.pulseMemory() }
            guard isCurrentWork(gen) else { return }
            pulse = mem
            items.append(contentsOf: LiveProbe.junk(fromMemory: mem))
            scannedModules.insert(.pulse)
            withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
                scanning = false
                busyModule = nil
                if module == scope {
                    scanFinished = true
                    progress = 1
                    orbFill = 0.88
                    status = Copy.pulseReady
                    displayedBytes = selectedBytes
                }
            }
            completed = true
            CamLog.line("scanLive pulse ram items=\(items.filter { $0.module == .pulse }.count) used=\(mem.used)")
            if module == scope { GlassTick.play() }

            let running = LiveProbe.browsersWithWindows()
            guard isCurrentWork(gen) else { return }
            let withTabs = await Background.run { LiveProbe.pulseTabs(into: mem, only: running) }
            guard isCurrentWork(gen) else { return }
            pulse = withTabs
            items.removeAll { $0.module == .pulse && $0.id.hasPrefix("pulse-tab:") }
            items.append(contentsOf: LiveProbe.junk(fromTabs: withTabs))
            if module == scope, let note = withTabs.tabAccess, note == Copy.needAutomation {
                lastFailureNote = note
                status = Line(ru: "\(Copy.pulseReady.ru) \(note.ru)", en: "\(Copy.pulseReady.en) \(note.en)")
            }
            CamLog.line("scanLive pulse tabs extras=\(withTabs.tabs.count)")
            return
        case .protect:
            let rows = await Background.run { LiveProbe.junkProtect() }
            guard isCurrentWork(gen) else { return }
            items.append(contentsOf: rows)
        case .startup:
            let rows = await Background.run { LiveProbe.junkStartup() }
            guard isCurrentWork(gen) else { return }
            items.append(contentsOf: rows)
        default:
            break
        }

        guard isCurrentWork(gen) else { return }
        scannedModules.insert(scope)
        let empty = items.filter { $0.module == scope && $0.bytes > 0 }.isEmpty
        withAnimation(reduce ? Motion.easeReduced : Motion.springOrb) {
            scanning = false
            if module == scope {
                scanFinished = true
                orbFill = empty ? 0.12 : 0.88
                progress = 1
            }
        }
        if module == scope {
            if empty {
                status = scope == .protect ? Copy.protectClear : Copy.layerClean
            } else if scope == .pulse {
                status = Copy.pulseReady
            } else {
                status = Copy.canClear(selected: selectedBytes, found: foundBytes)
            }
            if let note = lastFailureNote {
                status = Line(ru: "\(status.ru) \(note.ru)", en: "\(status.en) \(note.en)")
            }
            displayedBytes = selectedBytes
            GlassTick.play()
        }
        CamLog.line("scanLive done \(scope.rawValue) items=\(items.filter { $0.module == scope }.count) empty=\(empty)")
        completed = true
    }

    @MainActor
    func clean() async {
        guard !cleaning, !scanning else { return }
        let jobs = visibleItems().filter { $0.selected && $0.bytes > 0 }
        guard !jobs.isEmpty else { return }

        let gen = workGeneration
        let scope = module
        busyModule = scope
        let startSelected = jobs.reduce(Int64(0)) { $0 + $1.bytes }
        var freed: Int64 = 0
        var remaining = startSelected
        var failed = 0
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(Motion.easeMicro) {
            cleaning = true
            lastFailureNote = nil
            statusStopped = false
            status = Copy.cleaningStatus
            progress = 0
            displayedBytes = startSelected
        }

        defer {
            if busyModule == scope { busyModule = nil }
            if isCurrentWork(gen) {
                cleaning = false
            }
        }

        for (offset, item) in jobs.enumerated() {
            guard isCurrentWork(gen) else { break }
            let outcome = await Background.run { Janitor.clean(item) }
            guard isCurrentWork(gen) else { break }
            freed += outcome.freed
            lastFreed = freed
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

        guard isCurrentWork(gen) else {
            withAnimation(Motion.easeMicro) {
                items.removeAll { $0.bytes <= 0 }
            }
            return
        }

        lastFreed = freed
        let allGone = items.filter { $0.bytes > 0 && (scope == .smart || $0.module == scope) }.isEmpty
        withAnimation(Motion.level(reduce: reduce)) {
            orbFill = allGone ? (freed > 0 ? 0.20 : 0.12) : max(0.20, orbFill)
            if remaining == 0 { displayedBytes = 0 }
        }
        if freed > 0 {
            try? await Task.sleep(nanoseconds: reduce ? 180_000_000 : 420_000_000)
        }
        guard isCurrentWork(gen) else { return }

        didCleanThisScan = true
        cleanedInModule = scope

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
