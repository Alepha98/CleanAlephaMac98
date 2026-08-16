import AppKit
import SwiftUI

struct ShellView: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var intro = false

    private var pane: String {
        switch state.module {
        case .space: "space"
        case .tools: "tools"
        default: "scan"
        }
    }

    var body: some View {
        ZStack {
            // One wash under sidebar + content (CMM-like continuous chrome).
            ShellAtmosphere(
                richCare: state.module == .smart,
                family: CareFamily.of(state.module == .smart
                    ? (state.scanningStage ?? .smart)
                    : state.module)
            )

            HStack(spacing: 0) {
                SidebarView()
                Group {
                    switch state.module {
                    case .space: SpaceView()
                    case .tools: ToolsView()
                    default: ScanView()
                    }
                }
                .id(pane)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            }
            .animation(Motion.easeModule, value: pane)
        }
        .overlay {
            ThemeWashOverlay(amount: state.themeWash, night: state.themeWashNight)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(intro ? 1 : 0)
        .preferredColorScheme(state.appearance.colorScheme)
        .animation(Motion.themeCross, value: state.appearance)
        .background(WindowBackgroundDrag(appearance: state.appearance))
        .onAppear {
            state.refreshFDA()
            if reduceMotion {
                intro = true
            } else {
                withAnimation(Motion.easeIntro) { intro = true }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            state.refreshFDA()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Scan)) { _ in
            if state.hasScannedCurrent() && state.scanFinished && !state.isBusy {
                state.prepareRescan()
            } else {
                state.requestScan()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Clean)) { _ in
            state.requestClean()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Safe)) { _ in
            state.selectSafeVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Clear)) { _ in
            state.deselectVisible()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Cancel)) { _ in
            state.cancelWork()
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Keys)) { _ in
            state.showShortcuts = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .cam98Go)) { note in
            guard let raw = note.object as? String, let module = Module(rawValue: raw) else { return }
            state.selectModule(module)
        }
        .environment(\.shellIntro, intro)
        .environment(\.copyLang, state.copyLang)
        .environment(\.careChrome, state.module == .smart)
        .sheet(isPresented: Binding(
            get: { state.showShortcuts },
            set: { state.showShortcuts = $0 }
        )) {
            ShortcutsSheet()
                .environment(state)
                .environment(\.copyLang, state.copyLang)
        }
    }
}

private struct ShortcutsSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @Environment(\.dismiss) private var dismiss

    private var rows: [(String, String)] {
        [
            ("⌘R", Copy.scan.t(lang)),
            ("⌘↩", Copy.clean.t(lang)),
            ("⌘⇧A", Copy.safe.t(lang)),
            ("⌘⇧D", Copy.deselect.t(lang)),
            ("⌘. / Esc", Copy.stop.t(lang)),
            ("⌘1–9", Copy.cleanGroup.t(lang)),
            ("⌘B", Copy.modulePulse.t(lang)),
            ("⌘K", Copy.moduleProtect.t(lang)),
            ("⌘L", Copy.moduleStartup.t(lang)),
            ("⌘0", Copy.moduleSpace.t(lang)),
            ("⌘-", Copy.moduleTools.t(lang))
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S.lg) {
            Text(Copy.shortcuts.t(lang))
                .font(F.largeTitle(compact: true))
                .foregroundStyle(C.ink)
            VStack(spacing: 0) {
                ForEach(rows, id: \.0) { key, title in
                    HStack {
                        Text(title)
                            .font(F.body())
                            .foregroundStyle(C.ink)
                        Spacer(minLength: S.md)
                        Text(key)
                            .font(F.size())
                            .foregroundStyle(C.secondary)
                    }
                    .padding(.vertical, 8)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(C.hairline.opacity(0.7)).frame(height: 1)
                    }
                }
            }
            Button(Copy.close.t(lang)) { dismiss() }
                .buttonStyle(QuietButton())
        }
        .padding(S.xxl)
        .frame(width: 420)
        .background(C.bgTop)
        .preferredColorScheme(state.appearance.colorScheme)
    }
}

private struct ShellIntroKey: EnvironmentKey {
    static let defaultValue = true
}

private struct CareChromeKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var shellIntro: Bool {
        get { self[ShellIntroKey.self] }
        set { self[ShellIntroKey.self] = newValue }
    }
    /// Smart Care rich purple wash — use light text/icons on top.
    var careChrome: Bool {
        get { self[CareChromeKey.self] }
        set { self[CareChromeKey.self] = newValue }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @Environment(\.careChrome) private var careChrome

    private var brandInk: Color { careChrome ? C.careInk : C.ink }
    private var brandSecondary: Color { careChrome ? C.careSecondary : C.secondary }
    private var sectionInk: Color { careChrome ? C.careMuted : C.secondary.opacity(0.85) }

    private var groups: [(String, [Module])] {
        [
            (Copy.scanGroup.t(lang), [.smart]),
            (Copy.cleanGroup.t(lang), [.junk, .mail, .trash, .leftovers, .large, .duplicates, .browsers, .dev, .messengers]),
            (Copy.liveGroup.t(lang), [.pulse, .startup]),
            (Copy.guardGroup.t(lang), [.protect]),
            (Copy.systemGroup.t(lang), [.space, .tools])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if let url = URL(string: "https://github.com/Alepha98/CleanAlephaMac98") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 12) {
                    Image(nsImage: Art.image("AppIcon"))
                        .resizable()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: S.iconSquircle + 3, style: .continuous))
                        .shadow(color: C.action.opacity(0.28), radius: 8, y: 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CleanAlephaMac98")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(brandInk)
                        Text(Copy.personalMac.t(lang))
                            .font(F.micro())
                            .tracking(0.6)
                            .foregroundStyle(brandSecondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, S.trafficClearance)
            .padding(.horizontal, S.md)
            .padding(.bottom, S.lg)
            .help(Copy.openGitHubHelp.t(lang))
            .accessibilityLabel("CleanAlephaMac98, \(Copy.personalMac.t(lang))")
            .accessibilityHint(Copy.openGitHub.t(lang))
            .focusStroke(radius: 12)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: S.md) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.0.uppercased())
                                .font(F.micro())
                                .tracking(0.6)
                                .foregroundStyle(sectionInk)
                                .padding(.horizontal, S.sm)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.1) { m in
                                SidebarRow(
                                    module: m,
                                    selected: state.module == m,
                                    enabled: true
                                ) {
                                    state.selectModule(m)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, S.xs)
            }

            Spacer(minLength: 0)

            if !state.hasFDA {
                FdaSidebarCard()
            }

            SidebarThemeBar()
                .padding(.horizontal, S.sm)
                .padding(.bottom, S.md)
                .padding(.top, S.xs)
        }
        .animation(Motion.easeMicro, value: state.hasFDA)
        .animation(Motion.easeMicro, value: careChrome)
        .frame(width: S.sidebar)
        .frame(maxHeight: .infinity)
        .background {
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(careChrome ? 0.42 : 0.55)
                .overlay(C.rail.opacity(careChrome ? 0.12 : 0.22))
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(C.hairline.opacity(careChrome ? 0.35 : 0.55)).frame(width: 1)
        }
    }
}

/// Day / night / system — sliding rose pill at the foot of the rail.
private struct SidebarThemeBar: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.careChrome) private var careChrome
    @Environment(\.colorScheme) private var scheme

    private var choices: [(AppearanceChoice, String, Line)] {
        [
            (.light, "sun.max.fill", Copy.northernDay),
            (.system, "circle.lefthalf.filled", Copy.followSystem),
            (.dark, "moon.fill", Copy.northernNight)
        ]
    }

    private var chipInk: Color {
        careChrome ? C.careInk.opacity(0.78) : C.ink.opacity(0.75)
    }

    private var barFill: Color {
        if scheme == .dark {
            return Color.white.opacity(0.10)
        }
        return Color.white.opacity(0.94)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(Copy.themeBar.t(lang).uppercased())
                .font(F.micro())
                .tracking(0.6)
                .foregroundStyle(careChrome ? C.careMuted : C.secondary)
                .padding(.horizontal, 4)
                .accessibilityAddTraits(.isHeader)

            GlassActions {
                HStack(spacing: 6) {
                    ForEach(choices, id: \.0) { choice, symbol, title in
                        let on = state.appearance == choice
                        Button {
                            state.chooseAppearance(choice)
                        } label: {
                            Image(systemName: symbol)
                                .font(.system(size: 14, weight: .semibold))
                                .symbolRenderingMode(.monochrome)
                                .foregroundStyle(on ? C.accentText : chipInk)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: S.hitMin)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 2)
                                .camGlass(
                                    tint: on ? C.action.opacity(0.32) : C.action.opacity(0.06),
                                    interactive: true,
                                    shape: .rounded
                                )
                        }
                        .buttonStyle(.plain)
                        .help(title.t(lang))
                        .accessibilityLabel(title.t(lang))
                        .accessibilityIdentifier("theme.\(choice.rawValue)")
                        .accessibilityAddTraits(on ? [.isSelected] : [])
                    }
                }
                .padding(3)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(barFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(C.hairline.opacity(scheme == .dark ? 0.45 : 0.75), lineWidth: 1)
                        )
                )
            }
            .animation(reduceMotion ? Motion.easeReduced : Motion.themeCross, value: state.appearance)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Copy.themeBar.t(lang))
    }
}

private struct ThemeWashOverlay: View {
    var amount: Double
    var night: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: night
                    ? [C.glow.opacity(0.55), C.bgBot.opacity(0.35)]
                    : [C.glow.opacity(0.42), Color.white.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [C.action.opacity(night ? 0.28 : 0.22), Color.clear],
                center: .top,
                startRadius: 40,
                endRadius: 480
            )
            .blendMode(.plusLighter)
        }
        .opacity(amount)
        .ignoresSafeArea()
    }
}

private struct FdaSidebarCard: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @State private var hover = false

    var body: some View {
        Button(action: state.openFDA) {
            VStack(alignment: .leading, spacing: S.xxs) {
                HStack(alignment: .top, spacing: 6) {
                    CamIcon(glyph: .lock, size: 12)
                        .foregroundStyle(C.warn)
                        .padding(.top, 1)
                    Text(Copy.needFDA.t(lang))
                        .font(F.callout())
                        .foregroundStyle(C.warn)
                        .multilineTextAlignment(.leading)
                }
                Text(Copy.openSettings.t(lang))
                    .font(F.micro())
                    .tracking(0.6)
                    .foregroundStyle(C.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: S.hitMin, alignment: .leading)
            .padding(S.sm)
            .background(
                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                    .fill(C.warn.opacity(hover ? 0.14 : 0.08))
            )
            .focusStroke(radius: S.buttonRadius)
        }
        .buttonStyle(.plain)
        .padding(S.sm)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.08), value: hover)
        .accessibilityLabel(Copy.needFDA.t(lang))
        .accessibilityHint(Copy.openSettings.t(lang))
        .help(Copy.fdaCardHelp.t(lang))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}

private struct SidebarRow: View {
    let module: Module
    let selected: Bool
    var enabled: Bool = true
    var action: () -> Void
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @Environment(\.careChrome) private var careChrome
    @Environment(\.colorScheme) private var scheme
    @State private var hover = false

    private var sizeHint: String? {
        guard module.isCleanupModule, state.hasScanned(module) else { return nil }
        let b = state.sidebarBytes(for: module)
        guard b > 0 else { return nil }
        return ByteFormat.string(b, lang)
    }

    private var labelInk: Color {
        if careChrome { return selected ? C.careInk : C.careSecondary }
        return selected ? C.ink : C.secondary
    }

    private var hintInk: Color { careChrome ? C.careMuted : C.secondary }
    private var iconInk: Color {
        if careChrome { return selected ? C.careInk : C.careSecondary }
        return selected ? C.accentText : C.secondary
    }

    /// Light Smart Care: dark translucent chips; night: white frost.
    private var chipFill: Color {
        if !careChrome {
            return selected ? C.action.opacity(0.18) : C.iconWell.opacity(hover ? 1.15 : 1)
        }
        if scheme == .light {
            return selected ? C.careInk.opacity(0.12) : C.careInk.opacity(hover ? 0.08 : 0.05)
        }
        return selected ? Color.white.opacity(0.22) : Color.white.opacity(hover ? 0.14 : 0.08)
    }

    private var rowFill: Color {
        if !careChrome {
            return selected ? C.pill : (hover ? C.pillHover : Color.clear)
        }
        if scheme == .light {
            return selected ? C.careInk.opacity(0.10) : (hover ? C.careInk.opacity(0.06) : Color.clear)
        }
        return selected ? Color.white.opacity(0.20) : (hover ? Color.white.opacity(0.10) : Color.clear)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: S.iconSquircle, style: .continuous)
                        .fill(chipFill)
                    CamIcon(glyph: Glyph(module: module), size: 15)
                        .foregroundStyle(iconInk)
                }
                .frame(width: 26, height: 26)
                Text(module.name.t(lang))
                    .font(F.body())
                    .foregroundStyle(labelInk)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let sizeHint {
                    Text(sizeHint)
                        .font(F.size())
                        .foregroundStyle(hintInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: S.hitMin)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(rowFill)
            )
            .shadow(color: selected && !careChrome ? C.pillShadow : .clear, radius: 8, y: 2)
            .focusStroke(radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : (selected ? 0.72 : 0.45))
        .help(module.shortcutHint.isEmpty ? module.name.t(lang) : "\(module.name.t(lang)) · \(module.shortcutHint)")
        .accessibilityLabel(sizeHint.map { "\(module.name.t(lang)), \($0)" } ?? module.name.t(lang))
        .accessibilityHint(module.shortcutHint)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .onHover { hover = enabled && $0 }
        .animation(.easeOut(duration: 0.08), value: hover)
        .animation(Motion.easeMicro, value: enabled)
    }
}

extension Module {
    var keyEquivalent: KeyEquivalent? {
        switch self {
        case .smart: "1"
        case .junk: "2"
        case .mail: "3"
        case .trash: "4"
        case .leftovers: "5"
        case .large: "6"
        case .duplicates: "d"
        case .browsers: "7"
        case .dev: "8"
        case .messengers: "9"
        case .space: "0"
        case .tools: "-"
        case .pulse: "b"
        case .protect: "k"
        case .startup: "l"
        }
    }

    var shortcutHint: String {
        switch self {
        case .smart: "⌘1"
        case .junk: "⌘2"
        case .mail: "⌘3"
        case .trash: "⌘4"
        case .leftovers: "⌘5"
        case .large: "⌘6"
        case .duplicates: "⌘D"
        case .browsers: "⌘7"
        case .dev: "⌘8"
        case .messengers: "⌘9"
        case .space: "⌘0"
        case .tools: "⌘-"
        case .pulse: "⌘B"
        case .protect: "⌘K"
        case .startup: "⌘L"
        }
    }
}

private struct CommandShortcut: ViewModifier {
    var module: Module
    func body(content: Content) -> some View {
        if let key = module.keyEquivalent {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}
