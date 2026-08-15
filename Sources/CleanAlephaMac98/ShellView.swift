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
        HStack(spacing: 0) {
            SidebarView()
            ZStack {
                LinearGradient(colors: [C.bgTop, C.bgBot], startPoint: .top, endPoint: .bottom)
                RadialGradient(
                    colors: [C.glow.opacity(0.5), Color.clear],
                    center: .top,
                    startRadius: 20,
                    endRadius: 520
                )
                .blendMode(.plusLighter)
                Group {
                    switch state.module {
                    case .space: SpaceView()
                    case .tools: ToolsView()
                    default: ScanView()
                    }
                }
                .id(pane)
                .transition(.opacity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(Motion.easeModule, value: pane)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(intro ? 1 : 0)
        .preferredColorScheme(state.appearance.colorScheme)
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
            state.requestScan()
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
        .environment(\.shellIntro, intro)
        .environment(\.copyLang, state.copyLang)
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

extension EnvironmentValues {
    var shellIntro: Bool {
        get { self[ShellIntroKey.self] }
        set { self[ShellIntroKey.self] = newValue }
    }
}

struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang

    private var groups: [(String, [Module])] {
        [
            (Copy.scanGroup.t(lang), [.smart]),
            (Copy.cleanGroup.t(lang), [.junk, .mail, .trash, .leftovers, .large, .browsers, .dev, .messengers]),
            (Copy.liveGroup.t(lang), [.pulse, .startup]),
            (Copy.guardGroup.t(lang), [.protect]),
            (Copy.systemGroup.t(lang), [.space, .tools])
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: Art.image("AppIcon"))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: S.iconSquircle, style: .continuous))
                    .shadow(color: C.action.opacity(0.25), radius: 6, y: 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("CleanAlephaMac98")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(C.ink)
                    Text(Copy.personalMac.t(lang))
                        .font(F.micro())
                        .tracking(0.6)
                        .foregroundStyle(C.secondary)
                }
                .lineLimit(1)
            }
            .padding(.top, S.trafficClearance)
            .padding(.horizontal, S.md)
            .padding(.bottom, S.lg)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("CleanAlephaMac98, \(Copy.personalMac.t(lang))")

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: S.md) {
                    ForEach(groups, id: \.0) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.0.uppercased())
                                .font(F.micro())
                                .tracking(0.6)
                                .foregroundStyle(C.secondary.opacity(0.8))
                                .padding(.horizontal, S.sm)
                                .padding(.bottom, 2)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(group.1) { m in
                                SidebarRow(
                                    module: m,
                                    selected: state.module == m,
                                    enabled: !state.isBusy
                                ) {
                                    withAnimation(Motion.springUI) {
                                        state.module = m
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, S.xs)
            }

            if !state.hasFDA {
                FdaSidebarCard()
            }
        }
        .animation(Motion.easeMicro, value: state.hasFDA)
        .frame(width: S.sidebar)
        .frame(maxHeight: .infinity)
        .background(C.rail.opacity(0.96))
        .overlay(alignment: .trailing) {
            Rectangle().fill(C.hairline.opacity(0.7)).frame(width: 1)
        }
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
    @State private var hover = false

    private var sizeHint: String? {
        guard module.isCleanupModule, state.hasScanned(module) else { return nil }
        let b = state.sidebarBytes(for: module)
        guard b > 0 else { return nil }
        return ByteFormat.string(b, lang)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: S.iconSquircle, style: .continuous)
                        .fill(selected ? C.action.opacity(0.20) : C.iconWell.opacity(hover ? 1.2 : 1))
                    CamIcon(glyph: Glyph(module: module), size: 15)
                        .foregroundStyle(selected ? C.accentText : C.secondary)
                }
                .frame(width: 26, height: 26)
                Text(module.name.t(lang))
                    .font(F.body())
                    .foregroundStyle(selected ? C.ink : C.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 0)
                if let sizeHint {
                    Text(sizeHint)
                        .font(F.size())
                        .foregroundStyle(C.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: S.hitMin)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(
                        selected
                            ? C.pill
                            : (hover ? C.pillHover : Color.clear)
                    )
            )
            .shadow(color: selected ? C.pillShadow : .clear, radius: 8, y: 2)
            .focusStroke(radius: 10)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : (selected ? 0.72 : 0.45))
        .help(module.shortcutHint.isEmpty ? module.name.t(lang) : "\(module.name.t(lang)) · \(module.shortcutHint)")
        .modifier(CommandShortcut(module: module))
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
        case .browsers: "7"
        case .dev: "8"
        case .messengers: "9"
        case .space: "0"
        case .tools: "-"
        case .pulse, .protect, .startup: nil
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
        case .browsers: "⌘7"
        case .dev: "⌘8"
        case .messengers: "⌘9"
        case .space: "⌘0"
        case .tools: "⌘-"
        case .pulse, .protect, .startup: ""
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
