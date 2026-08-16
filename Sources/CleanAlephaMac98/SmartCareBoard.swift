import SwiftUI

/// Smart Care mosaic – active cell ~60% of its row; neighbors keep the rest.
/// Marks: original PNGs (CMM ScanProgress used only as visual reference).
enum SmartCareKind: String, CaseIterable, Identifiable {
    case cleanup, protection, performance, applications, clutter
    var id: String { rawValue }

    var title: Line {
        switch self {
        case .cleanup: Copy.careCleanup
        case .protection: Copy.careProtection
        case .performance: Copy.carePerformance
        case .applications: Copy.careApps
        case .clutter: Copy.careClutter
        }
    }

    var looking: Line {
        switch self {
        case .cleanup: Copy.careLookingCleanup
        case .protection: Copy.careLookingProtect
        case .performance: Copy.careLookingPerf
        case .applications: Copy.careLookingApps
        case .clutter: Copy.careLookingClutter
        }
    }

    var family: CareFamily {
        switch self {
        case .cleanup: .cleanup
        case .protection: .protection
        case .performance: .performance
        case .applications: .applications
        case .clutter: .clutter
        }
    }

    var modules: [Module] {
        switch self {
        case .cleanup: [.junk, .mail, .trash, .browsers, .messengers, .privacy]
        case .protection: [.protect]
        case .performance: [.pulse, .startup]
        case .applications: [.leftovers, .dev]
        case .clutter: [.large, .duplicates]
        }
    }

    func matches(stage: Module?) -> Bool {
        guard let stage else { return false }
        return modules.contains(stage)
    }

    static func kind(for stage: Module?) -> SmartCareKind? {
        allCases.first { $0.matches(stage: stage) }
    }
}

enum SmartCareBoardMode {
    case scanning
    case results
}

struct SmartCareBoard: View {
    var mode: SmartCareBoardMode = .scanning
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var active: SmartCareKind {
        if mode == .results {
            return SmartCareKind.allCases.max(by: { bytes(for: $0) < bytes(for: $1) }) ?? .cleanup
        }
        return SmartCareKind.kind(for: state.scanningStage) ?? .cleanup
    }

    private func bytes(for kind: SmartCareKind) -> Int64 {
        state.items
            .filter { $0.bytes > 0 && kind.modules.contains($0.module) }
            .reduce(0) { $0 + $1.bytes }
    }

    /// Active ~60%, others share remaining 40%.
    private var topShares: (CGFloat, CGFloat, CGFloat) {
        switch active {
        case .cleanup: return (0.60, 0.20, 0.20)
        case .protection: return (0.20, 0.60, 0.20)
        case .performance: return (0.20, 0.20, 0.60)
        case .applications, .clutter: return (1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0)
        }
    }

    private var bottomShares: (CGFloat, CGFloat) {
        switch active {
        case .applications: return (0.60, 0.40)
        case .clutter: return (0.40, 0.60)
        default: return (0.50, 0.50)
        }
    }

    private var rowShares: (CGFloat, CGFloat) {
        switch active {
        case .cleanup, .protection, .performance: return (0.60, 0.40)
        case .applications, .clutter: return (0.40, 0.60)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 640 || geo.size.width < 820
            let gap: CGFloat = compact ? 10 : 14
            let hPad = compact ? S.sm : S.md
            let boardW = geo.size.width - hPad * 2
            let chromeH: CGFloat = mode == .scanning ? (compact ? 158 : 186) : (compact ? 168 : 196)
            let boardH = max(280, geo.size.height - chromeH)
            let (topR, botR) = rowShares
            let topH = (boardH - gap) * topR
            let botH = (boardH - gap) * botR
            let (c, p, f) = topShares
            let (a, m) = bottomShares
            let topInner = boardW - gap * 2
            let botInner = boardW - gap

            ZStack {
                Color.clear

                VStack(spacing: compact ? 12 : 16) {
                    header(compact: compact)
                        .padding(.horizontal, hPad)
                        .padding(.top, 2)

                    VStack(spacing: gap) {
                        HStack(spacing: gap) {
                            tile(.cleanup, compact: compact)
                                .frame(width: topInner * c, height: topH)
                            tile(.protection, compact: compact)
                                .frame(width: topInner * p, height: topH)
                            tile(.performance, compact: compact)
                                .frame(width: topInner * f, height: topH)
                        }

                        HStack(spacing: gap) {
                            tile(.applications, compact: compact)
                                .frame(width: botInner * a, height: botH)
                            tile(.clutter, compact: compact)
                                .frame(width: botInner * m, height: botH)
                        }
                    }
                    .padding(.horizontal, hPad)
                    .frame(height: boardH)
                    .animation(
                        reduceMotion ? Motion.easeReduced : Motion.springUI,
                        value: mode == .scanning ? state.scanningStage?.rawValue : active.rawValue
                    )

                    Spacer(minLength: 8)

                    footer
                        .padding(.horizontal, hPad)
                        .padding(.bottom, 10)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @Environment(\.colorScheme) private var scheme

    private var onWash: Color {
        // Light Smart Care is pale lilac — use plum ink; night stays chalk white.
        scheme == .dark ? Color.white.opacity(0.96) : C.careInk
    }
    private var onWashSecondary: Color {
        scheme == .dark ? Color.white.opacity(0.74) : C.careSecondary
    }

    @ViewBuilder
    private func header(compact: Bool) -> some View {
        if mode == .scanning {
            Text(Copy.scanningMac.t(lang))
                .font(F.largeTitle(compact: compact))
                .foregroundStyle(onWash)
                .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0), radius: 6, y: 1)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Copy.canClean.t(lang))
                        .font(F.callout())
                        .foregroundStyle(onWashSecondary)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0), radius: 6, y: 1)
                    Text(ByteFormat.string(state.selectedBytes > 0 ? state.selectedBytes : state.foundBytes, lang))
                        .font(F.heroSize())
                        .foregroundStyle(onWash)
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0), radius: 6, y: 1)
                    if state.foundBytes > state.selectedBytes, state.selectedBytes > 0 {
                        Text(Copy.foundLine(state.foundBytes).t(lang))
                            .font(F.callout())
                            .foregroundStyle(onWashSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        if mode == .scanning {
            VStack(spacing: 10) {
                ProgressCapsule(progress: state.progress)
                Button(Copy.stop.t(lang)) { state.cancelWork() }
                    .buttonStyle(QuietButton())
                    .keyboardShortcut(.cancelAction)
            }
        } else {
            HStack(spacing: 12) {
                Button(state.module == .trash ? Copy.cleanTrash.t(lang) : Copy.clean.t(lang)) {
                    state.requestClean()
                }
                .buttonStyle(PrimaryButton(enabled: state.canClean))
                .disabled(!state.canClean)
                .keyboardShortcut(.defaultAction)

                Button(Copy.scanAgain.t(lang)) { state.prepareRescan() }
                    .buttonStyle(QuietButton(enabled: !state.isBusy))
                    .disabled(state.isBusy)

                Button(Copy.safe.t(lang)) { state.selectSafeVisible() }
                    .buttonStyle(GhostButton())
                    .disabled(!state.canSelectSafe)

                if state.canDeselect {
                    Button(Copy.deselect.t(lang)) { state.deselectVisible() }
                        .buttonStyle(GhostButton())
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func tile(_ kind: SmartCareKind, compact: Bool) -> some View {
        let on = active == kind
        let found = bytes(for: kind)
        let detail: String = {
            if mode == .scanning {
                return on ? state.status.t(lang) : idleDetail(for: kind, found: found)
            }
            if found > 0 {
                return ByteFormat.string(found, lang)
            }
            return Copy.layerClean.t(lang)
        }()

        let content = SmartCareTile(
            kind: kind,
            active: on,
            emphasize: mode == .results && found > 0,
            detail: detail,
            titleOverride: mode == .results ? kind.title.t(lang) : nil,
            compact: compact
        )

        if mode == .results {
            Button {
                state.openCareKind(kind)
            } label: {
                content
            }
            .buttonStyle(.plain)
            .opacity(found > 0 || on ? 1 : 0.82)
        } else {
            content
                .opacity(on ? 1 : 0.88)
                .allowsHitTesting(false)
        }
    }

    private func idleDetail(for kind: SmartCareKind, found: Int64) -> String {
        if found > 0 {
            return "\(ByteFormat.string(found, lang)) \(Copy.careFound.t(lang).lowercased())"
        }
        return Copy.careWaiting.t(lang)
    }
}

// MARK: - Tile

private struct SmartCareTile: View {
    let kind: SmartCareKind
    var active: Bool
    var emphasize: Bool = false
    var detail: String
    var titleOverride: String? = nil
    var compact: Bool
    @Environment(\.copyLang) private var lang
    @Environment(\.colorScheme) private var scheme

    private var fam: CareFamily { kind.family }
    private var lit: Bool { active || emphasize }
    private var radius: CGFloat { lit ? 26 : 20 }

    /// Lit tiles are deep rose — white ink. Idle light tiles need plum ink on frost.
    private var titleInk: Color {
        if lit { return .white.opacity(0.96) }
        return scheme == .light ? Color(red: 0.12, green: 0.05, blue: 0.10) : .white.opacity(0.95)
    }

    private var detailInk: Color {
        if lit { return .white.opacity(0.90) }
        return scheme == .light
            ? Color(red: 0.28, green: 0.12, blue: 0.20).opacity(0.92)
            : .white.opacity(0.70)
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let mark = side * (lit ? (compact ? 0.42 : 0.46) : 0.48)

            ZStack {
                tileChrome

                if active && titleOverride == nil {
                    VStack(spacing: compact ? 8 : 12) {
                        Text(kind.looking.t(lang))
                            .font(.system(size: compact ? 18 : 24, weight: .semibold, design: .rounded))
                            .foregroundStyle(titleInk)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, 12)

                        CareGlassMark(kind: kind, active: true, size: mark)
                            .frame(width: mark, height: mark)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        Text(detail)
                            .font(F.callout())
                            .foregroundStyle(detailInk)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                    }
                    .padding(.top, 14)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(titleOverride ?? kind.title.t(lang))
                            .font(.system(size: lit ? 17 : 15, weight: .semibold, design: .rounded))
                            .foregroundStyle(titleInk)
                        Text(detail)
                            .font(lit ? F.title() : F.callout())
                            .foregroundStyle(detailInk)
                            .lineLimit(3)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                    CareGlassMark(kind: kind, active: lit, size: mark)
                        .frame(width: mark, height: mark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                        .padding(.trailing, 10)
                        .padding(.bottom, 10)
                        .opacity(0.95)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
        .shadow(color: lit ? fam.glow : Color.black.opacity(0.18), radius: lit ? 18 : 8, y: lit ? 6 : 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.title.t(lang)), \(detail)")
        .accessibilityAddTraits(active ? [.updatesFrequently] : [])
    }

    private var tileChrome: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(lit ? AnyShapeStyle(
                LinearGradient(
                    colors: [fam.hi.opacity(0.98), fam.mid.opacity(0.92), fam.lo.opacity(0.95)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            ) : AnyShapeStyle(
                LinearGradient(
                    colors: scheme == .light
                        ? [
                            Color.white.opacity(0.72),
                            fam.mid.opacity(0.22),
                            Color.white.opacity(0.55)
                        ]
                        : [
                            Color.white.opacity(0.14),
                            fam.mid.opacity(0.16),
                            Color.black.opacity(0.18)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            ))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        scheme == .light && !lit
                            ? Color.black.opacity(0.10)
                            : Color.white.opacity(lit ? 0.40 : 0.18),
                        lineWidth: 1
                    )
            )
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .opacity(lit ? 0 : (scheme == .light ? 0.95 : 0.85))
            }
    }
}

// MARK: - Glass marks (original PNGs; CMM used only as visual reference)

struct CareGlassMark: View {
    let kind: SmartCareKind
    var active: Bool
    var size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var assetName: String {
        switch kind {
        case .cleanup: "CareCleanup"
        case .protection: "CareProtect"
        case .performance: "CarePerf"
        case .applications: "CareApps"
        case .clutter: "CareClutter"
        }
    }

    var body: some View {
        Group {
            if active && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: false)) { tl in
                    art(at: tl.date.timeIntervalSinceReferenceDate)
                }
            } else {
                art(at: 0)
            }
        }
    }

    private func art(at t: TimeInterval) -> some View {
        let wobble = active ? sin(t * 1.6) * 2.2 : 0
        return Image(nsImage: Art.image(assetName))
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .rotationEffect(.degrees(wobble))
            .shadow(color: .black.opacity(active ? 0.22 : 0.12), radius: active ? 10 : 6, y: 3)
            .accessibilityHidden(true)
    }
}
