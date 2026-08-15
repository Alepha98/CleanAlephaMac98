import AppKit
import SwiftUI

struct ScanView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.shellIntro) private var shellIntro
    @Environment(\.copyLang) private var lang
    @Namespace private var orbSpace
    @State private var headerReady = false
    @State private var cardsReady = false
    @State private var flyLift: CGFloat = 0
    @State private var flyGen = 0

    private var showingResults: Bool { state.scanFinished && !state.scanning && state.hasScannedCurrent() }
    private var visible: [JunkItem] { state.visibleItems() }
    private var isEmptyResults: Bool { showingResults && visible.isEmpty && !state.cleaning }

    private var justCleanedEmpty: Bool {
        isEmptyResults && state.didCleanThisScan && state.lastFreed > 0 && state.cleanedInModule == state.module
    }

    private var layerUnscanned: Bool {
        state.scanFinished && !state.scanning && !state.hasScannedCurrent() && state.module.isCleanupModule
    }

    private var layoutAnimation: Animation {
        Motion.layout(reduce: reduceMotion)
    }

    private var selectionLine: String? {
        let live = visible.filter { $0.bytes > 0 }
        guard !live.isEmpty else { return nil }
        let n = live.filter(\.selected).count
        return Copy.selected(n, of: live.count).t(lang)
    }

    private var homeTitle: String {
        if state.scanning {
            return state.module == .smart ? Copy.scanningMac.t(lang) : Copy.scanning(state.module.name).t(lang)
        }
        if state.module == .smart { return Copy.ready.t(lang) }
        return state.module.name.t(lang)
    }

    private var homeSubtitle: String {
        if state.scanning { return state.status.t(lang) }
        if state.statusStopped {
            return state.status.t(lang)
        }
        if layerUnscanned { return Copy.layerUnscanned.t(lang) }
        return state.module.blurb.t(lang)
    }

    private var orbLabel: String {
        if state.scanning {
            return Copy.orbScan(Int(state.progress * 100)).t(lang)
        }
        if state.cleaning {
            return Copy.orbCleaning(Int(state.progress * 100)).t(lang)
        }
        if showingResults {
            if justCleanedEmpty {
                return Copy.orbFreed(state.lastFreed).t(lang)
            }
            return Copy.orbCanClean(state.selectedBytes).t(lang)
        }
        return Copy.orbIdle.t(lang)
    }

    private var shownBytes: Int64 {
        state.cleaning ? state.displayedBytes : state.selectedBytes
    }

    var body: some View {
        GeometryReader { geo in
            let big = min(300, min(geo.size.width, geo.size.height) * 0.46)
            let small = min(148, max(120, geo.size.height * 0.24))
            let compact = geo.size.height < 600
            let hPad = geo.size.width < 920 ? S.md : S.xl
            Group {
                if showingResults {
                    if isEmptyResults {
                        emptyResults(orb: min(big * 0.72, 220), compact: compact, hPad: hPad)
                    } else {
                        results(orb: small, hPad: hPad, contentWidth: geo.size.width)
                    }
                } else {
                    home(orb: big, compact: compact)
                }
            }
            .animation(layoutAnimation, value: showingResults)
            .animation(layoutAnimation, value: isEmptyResults)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .onAppear { syncReveal(showingResults) }
        .onChange(of: showingResults) { _, on in
            syncReveal(on)
            arcFly(toResults: on)
        }
    }

    private func arcFly(toResults: Bool) {
        flyGen += 1
        let gen = flyGen
        if reduceMotion || !toResults {
            flyLift = 0
            return
        }
        flyLift = 0
        withAnimation(.easeOut(duration: Motion.flyUp)) {
            flyLift = Motion.flyLift
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.flyUp) {
            guard gen == flyGen else { return }
            withAnimation(.easeIn(duration: Motion.flyDown)) {
                flyLift = 0
            }
        }
    }

    private func syncReveal(_ on: Bool) {
        if on {
            let headerDelay = reduceMotion ? 0.0 : Motion.headerDelay
            let cardDelay = reduceMotion ? 0.0 : Motion.cardGateDelay
            withAnimation(Motion.easeMicro.delay(headerDelay)) {
                headerReady = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + cardDelay) {
                withAnimation(Motion.easeMicro) { cardsReady = true }
            }
        } else {
            headerReady = false
            cardsReady = false
        }
    }

    private func home(orb: CGFloat, compact: Bool) -> some View {
        VStack(spacing: S.orbTitleGap) {
            Spacer(minLength: S.xs)
            HeroOrb(fill: state.orbFill, scanning: state.scanning, cleaning: false, size: orb)
                .frame(width: orb, height: orb)
                .aspectRatio(1, contentMode: .fit)
                .matchedGeometryEffect(id: "crystal-orb", in: orbSpace)
                .offset(y: -flyLift)
                .scaleEffect(shellIntro ? 1 : 0.96)
                .animation(reduceMotion ? Motion.easeReduced : Motion.springUI, value: shellIntro)
                .transition(reduceMotion ? .opacity : .identity)
                .accessibilityElement()
                .accessibilityLabel(orbLabel)

            VStack(spacing: 6) {
                Text(homeTitle)
                    .font(F.largeTitle(compact: compact))
                    .foregroundStyle(C.ink)
                    .multilineTextAlignment(.center)
                    .id("title-\(state.module.id)-\(state.scanning)")
                    .transition(.opacity)
                Text(homeSubtitle)
                    .font(F.body())
                    .foregroundStyle(C.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, S.xxl)
                    .id("sub-\(state.module.id)-\(state.scanning)-\(state.status.ru)")
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            .animation(Motion.easeMicro, value: state.scanning)
            .animation(Motion.easeMicro, value: state.module)
            .animation(Motion.easeMicro, value: state.status)
            .onChange(of: state.status) { _, new in
                guard state.scanning || state.cleaning else { return }
                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: new.t(lang),
                        .priority: NSAccessibilityPriorityLevel.medium
                    ]
                )
            }

            if state.scanning {
                ProgressCapsule(progress: state.progress)
                    .padding(.top, S.xs)
                    .transition(.opacity)
                    .accessibilityLabel(Copy.progressScan.t(lang))
                Button(Copy.stop.t(lang)) { state.cancelWork() }
                    .buttonStyle(GhostButton())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel(Copy.stopScan.t(lang))
                    .padding(.top, 2)
                    .transition(.opacity)
            } else {
                VStack(spacing: S.sm) {
                    Button(Copy.scan.t(lang)) { state.requestScan() }
                        .buttonStyle(PrimaryButton(enabled: !state.isBusy))
                        .disabled(state.isBusy)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityLabel(Copy.scan.t(lang))
                        .help(Copy.scanHelp.t(lang))
                    if state.showFirstRunQuiet {
                        VStack(spacing: S.xxs) {
                            Button(action: state.openFDA) {
                                Text(Copy.needFDAQuiet.t(lang))
                                    .font(F.callout())
                                    .foregroundStyle(C.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            .buttonStyle(.plain)
                            .help(Copy.fdaCardHelp.t(lang))
                            Button(Copy.later.t(lang)) { state.dismissFirstRun() }
                                .buttonStyle(GhostButton())
                                .help(Copy.laterHelp.t(lang))
                        }
                        .padding(.horizontal, S.xl)
                    }
                }
                .padding(.top, 10)
                .transition(.opacity)
            }
            Spacer(minLength: compact ? S.xs : S.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultColumns(contentWidth: CGFloat) -> [GridItem] {
        let count: Int
        if contentWidth >= 1000 { count = 3 }
        else if contentWidth >= 700 { count = 2 }
        else { count = 1 }
        return Array(repeating: GridItem(.flexible(), spacing: 14), count: count)
    }

    @ViewBuilder
    private func resultsActions(narrow: Bool) -> some View {
        if narrow {
            VStack(alignment: .leading, spacing: 8) {
                cleanAction()
                HStack(spacing: 10) {
                    if state.cleaning { stopAction() }
                    rescanAction()
                    safeAction()
                    if state.canDeselect { clearAction() }
                }
            }
        } else {
            HStack(spacing: 10) {
                cleanAction()
                if state.cleaning { stopAction() }
                rescanAction()
                safeAction()
                if state.canDeselect { clearAction() }
            }
        }
    }

    @ViewBuilder
    private func cleanAction() -> some View {
        let title = state.cleaning ? Copy.cleaning.t(lang) : (state.module == .trash ? Copy.cleanTrash.t(lang) : Copy.clean.t(lang))
        let enabled = state.canClean
        if state.module == .trash {
            Button(title) { state.requestClean() }
                .buttonStyle(DestructiveQuiet(enabled: enabled))
                .disabled(!enabled)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(state.cleaning ? Copy.cleaning.t(lang) : title)
                .help(Copy.cleanHelp.t(lang))
        } else {
            Button(title) { state.requestClean() }
                .buttonStyle(PrimaryButton(enabled: enabled))
                .disabled(!enabled)
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel(state.cleaning ? Copy.cleaning.t(lang) : title)
                .help(Copy.cleanHelp.t(lang))
        }
    }

    private func rescanAction() -> some View {
        Button(Copy.scanAgain.t(lang)) { state.requestScan() }
            .buttonStyle(QuietButton(enabled: !state.isBusy))
            .disabled(state.isBusy)
            .help(Copy.scanHelp.t(lang))
    }

    private func stopAction() -> some View {
        Button(Copy.stop.t(lang)) { state.cancelWork() }
            .buttonStyle(GhostButton())
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel(Copy.stopClean.t(lang))
    }

    private func safeAction() -> some View {
        Button(Copy.safe.t(lang)) { state.selectSafeVisible() }
            .buttonStyle(GhostButton())
            .disabled(!state.canSelectSafe)
            .help("⌘⇧A — \(Copy.fdaHint.t(lang))")
    }

    private func clearAction() -> some View {
        Button(Copy.deselect.t(lang)) { state.deselectVisible() }
            .buttonStyle(GhostButton())
            .disabled(!state.canDeselect)
            .help("⌘⇧D — \(Copy.deselectHint.t(lang))")
    }

    private func results(orb: CGFloat, hPad: CGFloat, contentWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 18) {
                HeroOrb(fill: state.orbFill, scanning: false, cleaning: state.cleaning, size: orb)
                    .frame(width: orb, height: orb)
                    .aspectRatio(1, contentMode: .fit)
                    .layoutPriority(1)
                    .matchedGeometryEffect(id: "crystal-orb", in: orbSpace)
                    .offset(y: -flyLift)
                    .transition(reduceMotion ? .opacity.combined(with: .scale(scale: 0.92)) : .identity)
                    .accessibilityElement()
                    .accessibilityLabel(orbLabel)
                VStack(alignment: .leading, spacing: 6) {
                    Text(state.cleaning ? Copy.cleaning.t(lang) : (state.module == .smart ? Copy.canClean.t(lang) : state.module.name.t(lang)))
                        .font(F.callout())
                        .foregroundStyle(C.secondary)
                        .contentTransition(.opacity)
                    ZStack(alignment: .leading) {
                        Text(ByteFormat.widthReserve)
                            .font(F.heroSize())
                            .hidden()
                            .accessibilityHidden(true)
                        Text(ByteFormat.string(shownBytes, lang))
                            .font(F.heroSize())
                            .foregroundStyle(C.ink)
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .accessibilityLabel(Copy.orbCanClean(shownBytes).t(lang))
                    if !state.cleaning, state.foundBytes > state.selectedBytes {
                        Text(Copy.foundLine(state.foundBytes).t(lang))
                            .font(F.callout())
                            .foregroundStyle(C.secondary)
                            .contentTransition(.numericText())
                    }
                    Text(Copy.loginsStay.t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.accentText)
                    if state.cleaning {
                        ProgressCapsule(progress: state.progress)
                            .accessibilityLabel(Copy.progressClean.t(lang))
                            .transition(.opacity)
                    }
                    if let selectionLine {
                        Text(selectionLine)
                            .font(F.callout())
                            .foregroundStyle(C.secondary)
                            .contentTransition(.numericText())
                            .accessibilityLabel(selectionLine)
                    }
                    if let note = state.lastFailureNote {
                        let offerFDA = Copy.offersFDA(note)
                        BannerWarn(
                            text: note.t(lang),
                            actionTitle: offerFDA ? Copy.settings.t(lang) : nil,
                            action: offerFDA ? { state.openFDA() } : nil
                        )
                    } else if state.statusStopped {
                        BannerInfo(text: state.status.t(lang))
                    } else if !state.cleaning && state.didCleanThisScan && state.lastFreed > 0 && state.cleanedInModule == state.module {
                        BannerInfo(text: Copy.doneFreed(state.lastFreed).t(lang))
                    }
                    resultsActions(narrow: contentWidth < 760)
                    .padding(.top, 6)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .background(CardBackground())
            .padding(.horizontal, hPad)
            .padding(.top, 18)
            .padding(.bottom, 14)
            .opacity(headerReady ? 1 : 0)
            .animation(Motion.easeMicro, value: state.cleaning)

            ScrollView {
                LazyVGrid(columns: resultColumns(contentWidth: contentWidth), spacing: 14) {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                        let stagger = Motion.stagger(index: index, reduce: reduceMotion)
                        ResultCard(item: item, enabled: !state.isBusy) { state.toggle(item.id) }
                            .opacity(cardsReady ? 1 : 0)
                            .transition(
                                reduceMotion
                                    ? .opacity
                                    : .opacity.combined(with: .scale(scale: 0.97))
                            )
                            .animation(
                                .spring(response: 0.5, dampingFraction: 0.86).delay(stagger),
                                value: cardsReady
                            )
                    }
                }
                .padding(.horizontal, hPad)
                .padding(.bottom, S.xl)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyResults(orb: CGFloat, compact: Bool, hPad: CGFloat) -> some View {
        VStack(spacing: S.orbTitleGap) {
            Spacer(minLength: S.xs)
            HeroOrb(fill: state.orbFill, scanning: false, cleaning: false, size: orb)
                .frame(width: orb, height: orb)
                .aspectRatio(1, contentMode: .fit)
                .matchedGeometryEffect(id: "crystal-orb", in: orbSpace)
                .offset(y: -flyLift)
                .accessibilityElement()
                .accessibilityLabel(orbLabel)
            Text(emptyTitle)
                .font(F.largeTitle(compact: compact))
                .foregroundStyle(C.ink)
                .multilineTextAlignment(.center)
            Text(emptyDetail)
                .font(F.body())
                .foregroundStyle(C.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, hPad)
            if let note = state.lastFailureNote {
                BannerWarn(text: note.t(lang))
                    .padding(.horizontal, hPad)
            } else if justCleanedEmpty {
                BannerInfo(text: Copy.doneFreed(state.lastFreed).t(lang))
                    .padding(.horizontal, hPad)
            }
            if !state.hasFDA && state.module.suggestsFDA && !justCleanedEmpty {
                Button(action: state.openFDA) {
                    Text(Copy.needFDA.t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.warn)
                }
                .buttonStyle(.plain)
                .padding(.top, S.xs)
            }
            HStack(spacing: 10) {
                Button(Copy.scanAgain.t(lang)) { state.requestScan() }
                    .buttonStyle(PrimaryButton(enabled: !state.isBusy))
                    .disabled(state.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, S.sm)
            Spacer(minLength: S.xl)
        }
        .opacity(headerReady ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if justCleanedEmpty { return Copy.done.t(lang) }
        if state.module == .smart { return Copy.foldersClean.t(lang) }
        return Copy.layerClean.t(lang)
    }

    private var emptyDetail: String {
        if justCleanedEmpty {
            return Copy.emptyDetailFreed(state.lastFreed).t(lang)
        }
        if !state.hasFDA && state.module.suggestsFDA {
            return Copy.emptyFDA.t(lang)
        }
        if state.module == .smart {
            return Copy.emptySmart.t(lang)
        }
        return state.module.blurb.t(lang)
    }
}

struct ResultCard: View {
    let item: JunkItem
    var enabled: Bool = true
    var toggle: () -> Void
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @State private var hover = false

    private var emptied: Bool { item.bytes <= 0 }
    private var muted: Bool { !emptied && item.isSecondaryRisk && !item.selected }
    private var canToggle: Bool { enabled && !emptied }

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(item.selected && !emptied ? C.action.opacity(0.18) : C.iconWell)
                        CamIcon(glyph: emptied ? .check : Glyph(item: item), size: 16)
                            .foregroundStyle(emptied ? C.secondary : (item.selected ? C.accentText : C.secondary.opacity(muted ? 0.7 : 1)))
                    }
                    .frame(width: 28, height: 28)
                    Spacer()
                    Text(emptied ? Copy.emptied.t(lang) : ByteFormat.string(item.bytes, lang))
                        .font(F.size())
                        .foregroundStyle(C.secondary)
                }
                Text(item.title.t(lang))
                    .font(F.title())
                    .foregroundStyle(emptied || muted ? C.secondary : C.ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.subtitle.t(lang))
                    .font(F.callout())
                    .foregroundStyle(C.secondary.opacity(muted || emptied ? 0.75 : 1))
                    .lineLimit(emptied ? 1 : 2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    if emptied {
                        MicroBadge(text: Copy.emptied.t(lang), tone: .quiet)
                    } else {
                        CamIcon(glyph: item.selected ? .selectOn : .selectOff, size: 16)
                            .foregroundStyle(item.selected ? C.action : C.secondary.opacity(0.35))
                        if item.keepsLogins {
                            MicroBadge(text: Copy.loginsBadge.t(lang), tone: .safe)
                        }
                        if let caution = item.cautionBadge {
                            MicroBadge(text: caution.t(lang), tone: .caution)
                        }
                        if muted {
                            MicroBadge(text: Copy.offBadge.t(lang), tone: .quiet)
                        }
                    }
                    Spacer()
                }
            }
            .padding(S.md)
            .frame(maxWidth: .infinity, minHeight: emptied ? 96 : (item.module == .large ? 108 : 132), alignment: .topLeading)
            .opacity(emptied ? 0.62 : (muted ? 0.88 : 1))
            .background(CardBackground(selected: item.selected && !emptied, hover: hover && canToggle))
            .focusStroke(radius: S.cardRadius)
        }
        .buttonStyle(CardPressStyle())
        .disabled(!canToggle)
        .contextMenu {
            if FinderReveal.canShow(item.url) {
                Button(Copy.revealFinder.t(lang)) {
                    FinderReveal.show(item.url)
                }
            }
            if !emptied {
                Button(Copy.excludeThis.t(lang)) {
                    state.exclude(item)
                }
            }
        }
        .accessibilityLabel("\(item.title.t(lang)), \(emptied ? Copy.emptied.t(lang) : ByteFormat.string(item.bytes, lang))")
        .accessibilityValue(emptied ? Copy.emptied.t(lang) : (item.selected ? Copy.selectedOn.t(lang) : Copy.selectedOff.t(lang)))
        .accessibilityAddTraits(emptied ? [] : .isToggle)
        .accessibilityHint(emptied ? "" : (item.keepsLogins ? Copy.loginsBadge.t(lang) : (muted ? Copy.defaultOff.t(lang) : "")))
        .onHover { hover = canToggle && $0 }
        .scaleEffect(hover && canToggle ? Motion.hoverLift : 1)
        .animation(Motion.easeHover, value: hover)
        .animation(Motion.easeMicro, value: emptied)
    }
}

enum FinderReveal {
    static func canShow(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        return fm.fileExists(atPath: url.deletingLastPathComponent().path)
    }

    static func show(_ url: URL) {
        let fm = FileManager.default
        var target = url.standardizedFileURL
        if !fm.fileExists(atPath: target.path) {
            target = target.deletingLastPathComponent()
        }
        guard fm.fileExists(atPath: target.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

struct SpaceView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @State private var refreshTick = 0
    @State private var usedFrac: CGFloat = 0
    @State private var reservedFrac: CGFloat = 0

    private var vol: (total: Int64, used: Int64, free: Int64) {
        let _ = refreshTick
        return Scanner.volume()
    }

    private var reservedBytes: Int64 {
        min(state.protectedBytes, max(0, vol.used))
    }

    private var ordinaryUsed: Int64 {
        max(0, vol.used - reservedBytes)
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 600
            let hPad = geo.size.width < 920 ? S.md : S.xxl
            let ring = min(compact ? 112 : 132, geo.size.width * 0.28)
            ScrollView {
            VStack(alignment: .leading, spacing: compact ? S.md : S.lg) {
            Text(Copy.diskTitle.t(lang))
                .font(F.largeTitle(compact: compact))
            if vol.total <= 0 {
                VStack(alignment: .leading, spacing: S.sm) {
                    Text(Copy.diskFail.t(lang))
                        .font(F.body())
                        .foregroundStyle(C.secondary)
                    Button(Copy.retry.t(lang)) {
                        refreshTick += 1
                        state.requestProtectedMeasure(force: true)
                    }
                    .buttonStyle(QuietButton())
                }
                .padding(S.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(CardBackground())
            } else {
                Group {
                    if geo.size.width < 700 {
                        VStack(spacing: S.sm) {
                            DiskStatCard(title: Copy.used.t(lang), value: ByteFormat.string(vol.used, lang))
                            DiskStatCard(title: Copy.free.t(lang), value: ByteFormat.string(vol.free, lang))
                            DiskStatCard(title: Copy.total.t(lang), value: ByteFormat.string(vol.total, lang))
                        }
                    } else {
                        HStack(spacing: S.sm) {
                            DiskStatCard(title: Copy.used.t(lang), value: ByteFormat.string(vol.used, lang))
                            DiskStatCard(title: Copy.free.t(lang), value: ByteFormat.string(vol.free, lang))
                            DiskStatCard(title: Copy.total.t(lang), value: ByteFormat.string(vol.total, lang))
                        }
                    }
                }
                Group {
                    if geo.size.width < 640 {
                        VStack(alignment: .leading, spacing: S.md) {
                            diskRing(size: ring)
                            diskLegend()
                        }
                    } else {
                        HStack(alignment: .center, spacing: S.lg) {
                            diskRing(size: ring)
                            diskLegend()
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(S.lg)
                .background(CardBackground())
                .onAppear { revealRing() }
                .onChange(of: vol.used) { _, _ in syncRing(animated: state.didRevealDiskBar) }
                .onChange(of: state.protectedBytes) { _, _ in syncRing(animated: true) }
            }

            ProtectedList()
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, compact ? S.lg : S.xxl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear { state.requestProtectedMeasure() }
    }

    private func diskRing(size: CGFloat) -> some View {
        DiskRing(used: usedFrac, reserved: reservedFrac, size: size)
            .accessibilityElement()
            .accessibilityLabel(Copy.diskA11y(used: ordinaryUsed, reserved: reservedBytes, free: vol.free).t(lang))
            .help(Copy.ringNote.t(lang))
    }

    private func diskLegend() -> some View {
        VStack(alignment: .leading, spacing: S.xs) {
            DiskLegendRow(color: C.liquidMid, title: Copy.used.t(lang), value: ByteFormat.string(ordinaryUsed, lang))
            DiskLegendRow(
                color: C.reserved,
                title: Copy.dontTouch.t(lang),
                value: state.protectedMeasured ? ByteFormat.string(reservedBytes, lang) : Copy.counting.t(lang)
            )
            DiskLegendRow(color: C.glass, title: Copy.free.t(lang), value: ByteFormat.string(vol.free, lang))
            Text(Copy.ringNote.t(lang))
                .font(F.micro())
                .tracking(0.6)
                .foregroundStyle(C.secondary.opacity(0.85))
                .padding(.top, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func revealRing() {
        if state.didRevealDiskBar {
            syncRing(animated: false)
            return
        }
        usedFrac = 0
        reservedFrac = 0
        syncRing(animated: true)
        state.didRevealDiskBar = true
    }

    private func syncRing(animated: Bool) {
        let total = Double(max(vol.total, 1))
        let reserved = Double(reservedBytes) / total
        let used = Double(ordinaryUsed) / total
        let apply = {
            usedFrac = CGFloat(used)
            reservedFrac = CGFloat(reserved)
        }
        if animated {
            withAnimation(Motion.easeDisk) { apply() }
        } else {
            apply()
        }
    }
}

/// Occupancy ring: used (rose) + protected (mauve) + free (glass). Not an Excel pie, not a hole.
private struct DiskRing: View {
    var used: CGFloat
    var reserved: CGFloat
    var size: CGFloat
    var line: CGFloat = 12

    var body: some View {
        let u = max(0, min(1, used))
        let r = max(0, min(1 - u, reserved))
        ZStack {
            Circle()
                .stroke(C.glass, lineWidth: line)
            Circle()
                .trim(from: 0, to: u)
                .stroke(
                    LinearGradient(colors: [C.liquidMid, C.liquidLo], startPoint: .top, endPoint: .bottom),
                    style: StrokeStyle(lineWidth: line, lineCap: .butt)
                )
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: u, to: u + r)
                .stroke(C.reserved, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                .rotationEffect(.degrees(-90))
            Circle()
                .stroke(C.cardStroke.opacity(0.7), lineWidth: 1)
                .padding(line * 0.42)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct DiskLegendRow: View {
    var color: Color
    var title: String
    var value: String

    var body: some View {
        HStack(spacing: S.xs) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(F.callout())
                .foregroundStyle(C.secondary)
            Spacer(minLength: S.xs)
            Text(value)
                .font(F.size())
                .foregroundStyle(C.ink)
        }
    }
}

private struct DiskStatCard: View {
    let title: String
    let value: String
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(F.callout()).foregroundStyle(C.secondary)
            Text(value)
                .font(F.stat())
                .foregroundStyle(C.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(S.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CardBackground(hover: hover))
        .onHover { hover = $0 }
        .scaleEffect(hover ? Motion.hoverLift : 1)
        .animation(Motion.easeHover, value: hover)
    }
}

struct ToolsView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @State private var logNote: Line?
    @State private var lastWhen: Date?
    @State private var lastFreed: Int64?
    @State private var agentInstalled = false

    private var scheduleLine: String {
        if let lastWhen {
            let when = Copy.relative(lastWhen, lang: lang)
            if let lastFreed {
                return Copy.scheduleLast(when: when, freed: ByteFormat.string(lastFreed, lang)).t(lang)
            }
            return Copy.scheduleLast(when: when, freed: nil).t(lang)
        }
        if agentInstalled || state.scheduleEnabled {
            return Copy.agentWaiting.t(lang)
        }
        return Copy.agentOff.t(lang)
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 600
            let hPad = geo.size.width < 920 ? S.md : S.xxl
            ScrollView {
            VStack(alignment: .leading, spacing: compact ? S.md : S.lg) {
            Text(Copy.toolsTitle.t(lang))
                .font(F.largeTitle(compact: compact))
            Text(Copy.toolsLead.t(lang))
                .font(F.body())
                .foregroundStyle(C.secondary)

            VStack(alignment: .leading, spacing: S.md) {
                HStack {
                    Text(Copy.schedule.t(lang))
                        .font(F.title())
                    Spacer(minLength: 0)
                    Toggle(isOn: Binding(
                        get: { state.scheduleEnabled },
                        set: { state.setScheduleEnabled($0) }
                    )) {
                        Text(Copy.autoClean.t(lang))
                            .font(F.callout())
                            .foregroundStyle(C.secondary)
                    }
                    .toggleStyle(.switch)
                }
                DayScheduleArc(slots: state.scheduleSlots, active: state.scheduleEnabled)
                    .frame(height: 96)
                ForEach(state.scheduleSlots) { slot in
                    ScheduleSlotRow(slot: slot)
                }
                if state.scheduleSlots.count < ScheduleStore.maxSlots {
                    Button(Copy.addTime.t(lang)) {
                        state.addScheduleSlot()
                    }
                    .buttonStyle(QuietButton())
                }
                Text(scheduleLine)
                    .font(F.callout())
                    .foregroundStyle(C.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = state.scheduleNote {
                    Text(note.t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(S.lg)
            .background(CardBackground())

            ProtectedList()

            VStack(alignment: .leading, spacing: S.md) {
                Text(Copy.actions.t(lang))
                    .font(F.title())
                Group {
                    if geo.size.width < 760 {
                        VStack(alignment: .leading, spacing: S.sm) {
                            Button(Copy.openLog.t(lang)) { openLog() }
                                .buttonStyle(QuietButton())
                            Button(Copy.fullDisk.t(lang)) {
                                state.openFDA()
                            }
                            .buttonStyle(PrimaryButton())
                            .help(Copy.fdaCardHelp.t(lang))
                        }
                    } else {
                        HStack(spacing: S.sm) {
                            Button(Copy.openLog.t(lang)) { openLog() }
                                .buttonStyle(QuietButton())
                            Button(Copy.fullDisk.t(lang)) {
                                state.openFDA()
                            }
                            .buttonStyle(PrimaryButton())
                            .help(Copy.fdaCardHelp.t(lang))
                        }
                    }
                }
                if let logNote {
                    Text(logNote.t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.warn)
                }
            }
            .padding(S.lg)
            .background(CardBackground())
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, compact ? S.lg : S.xxl)
        .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear {
            refreshCap()
            state.refreshAgentIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshCap()
        }
    }

    private func refreshCap() {
        let snap = Maintenance.snapshot()
        lastWhen = snap.when
        lastFreed = snap.freed
        agentInstalled = snap.installed
    }

    private func openLog() {
        let log = AutoAgent.logURL
        let fm = FileManager.default
        if fm.fileExists(atPath: log.path) {
            logNote = NSWorkspace.shared.open(log) ? nil : Copy.logOpenFail
            return
        }
        let dir = log.deletingLastPathComponent()
        if fm.fileExists(atPath: dir.path), NSWorkspace.shared.open(dir) {
            logNote = Copy.logOpenedFolder
        } else {
            logNote = Copy.logMissing
        }
    }
}

private struct ScheduleSlotRow: View {
    let slot: ScheduleSlot
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang

    var body: some View {
        HStack(spacing: S.sm) {
            Menu {
                ForEach(0..<24, id: \.self) { hour in
                    Button(String(format: "%02d", hour)) {
                        state.updateScheduleSlot(slot.id, hour: hour, minute: slot.minute)
                    }
                }
            } label: {
                Text(String(format: "%02d", slot.hour))
                    .font(F.size())
                    .foregroundStyle(C.ink)
                    .frame(minWidth: 36, minHeight: S.hitMin)
            }
            Text(":")
                .foregroundStyle(C.secondary)
            Menu {
                ForEach([0, 15, 30, 45], id: \.self) { minute in
                    Button(String(format: "%02d", minute)) {
                        state.updateScheduleSlot(slot.id, hour: slot.hour, minute: minute)
                    }
                }
            } label: {
                Text(String(format: "%02d", slot.minute))
                    .font(F.size())
                    .foregroundStyle(C.ink)
                    .frame(minWidth: 36, minHeight: S.hitMin)
            }
            Spacer(minLength: 0)
            if state.scheduleSlots.count > 1 {
                Button(Copy.removeTime.t(lang)) {
                    state.removeScheduleSlot(slot.id)
                }
                .buttonStyle(GhostButton())
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(slot.label)
    }
}

/// Quiet day arc: 00:00 left → 12:00 top → 24:00 right. Marks at the user's times, plus now.
private struct DayScheduleArc: View {
    var slots: [ScheduleSlot]
    var active: Bool
    @Environment(\.copyLang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.periodic(from: .now, by: reduceMotion ? 60 : 30)) { timeline in
            let now = timeline.date
            GeometryReader { g in
                let w = g.size.width
                let h = g.size.height
                let cy = h * 0.78
                let r = min(w * 0.46, h * 0.92)
                let here = Self.angle(hour: Self.fraction(date: now))
                let marks = slots.map(\.label).joined(separator: ", ")
                ZStack {
                    Path { p in
                        p.addArc(
                            center: CGPoint(x: w / 2, y: cy),
                            radius: r,
                            startAngle: .degrees(180),
                            endAngle: .degrees(360),
                            clockwise: false
                        )
                    }
                    .stroke(C.hairline, style: StrokeStyle(lineWidth: 3, lineCap: .round))

                    ForEach(slots) { slot in
                        mark(
                            at: Self.angle(hour: slot.fraction),
                            in: w,
                            cy: cy,
                            r: r,
                            glyph: slot.hour < 17 ? .sun : .moon,
                            label: slot.label,
                            active: active
                        )
                    }
                    nowDot(at: here, in: w, cy: cy, r: r)
                }
                .accessibilityElement()
                .accessibilityLabel(Copy.scheduleA11y(now: Self.clock(now, lang: lang), marks: marks).t(lang))
            }
        }
    }

    /// 00:00 = 180° (left), 12:00 = 270° (top), 24:00 = 360° (right). iOS y-down: 270° is up.
    private static func angle(hour: Double) -> Double {
        180 + (hour / 24) * 180
    }

    private static func fraction(date: Date) -> Double {
        let cal = Calendar.current
        let h = Double(cal.component(.hour, from: date))
        let m = Double(cal.component(.minute, from: date))
        return h + m / 60
    }

    private static func clock(_ date: Date, lang: CopyLang) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: lang == .en ? "en_US_POSIX" : "ru_RU")
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func point(angle: Double, w: CGFloat, cy: CGFloat, r: CGFloat) -> CGPoint {
        let rad = angle * .pi / 180
        return CGPoint(x: w / 2 + CGFloat(cos(rad)) * r, y: cy + CGFloat(sin(rad)) * r)
    }

    private func mark(at degrees: Double, in w: CGFloat, cy: CGFloat, r: CGFloat, glyph: Glyph, label: String, active: Bool) -> some View {
        let p = point(angle: degrees, w: w, cy: cy, r: r)
        return ZStack {
            Circle()
                .fill(active ? C.action : C.secondary.opacity(0.45))
                .frame(width: 10, height: 10)
            HStack(spacing: 3) {
                CamIcon(glyph: glyph, size: 9)
                Text(label)
                    .font(F.micro())
                    .tracking(0.6)
            }
            .foregroundStyle(active ? C.accentText : C.secondary)
            .offset(y: -16)
        }
        .position(x: p.x, y: p.y)
    }

    private func nowDot(at degrees: Double, in w: CGFloat, cy: CGFloat, r: CGFloat) -> some View {
        let p = point(angle: degrees, w: w, cy: cy, r: r)
        return Circle()
            .fill(C.ink)
            .frame(width: 6, height: 6)
            .overlay(
                Circle()
                    .stroke(C.glassHi.opacity(0.9), lineWidth: 1)
            )
            .position(x: p.x, y: p.y)
            .accessibilityHidden(true)
    }
}
