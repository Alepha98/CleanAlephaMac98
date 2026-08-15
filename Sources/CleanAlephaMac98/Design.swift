import AppKit
import SwiftUI

/// Northern day / northern night. Night is a new lighting scheme, not inverted day (TZ-03 §10).
enum AppearanceChoice: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

enum C {
    /// Dusty-rose tokens: day from TZ-01 §4.2; night is a plum lab, not #000 invert.
    static let bgTop = token("bgTop", light: (0.97, 0.93, 0.94), dark: (0.10, 0.06, 0.08))
    static let bgBot = token("bgBot", light: (0.92, 0.86, 0.88), dark: (0.06, 0.04, 0.06))
    static let rail = token("rail", light: (0.98, 0.95, 0.96), dark: (0.14, 0.09, 0.11))
    static let ink = token("ink", light: (0.18, 0.11, 0.14), dark: (0.96, 0.90, 0.92))
    static let secondary = token("secondary", light: (0.52, 0.42, 0.46), dark: (0.74, 0.60, 0.64))
    static let hairline = token("hairline", light: (0.88, 0.80, 0.82), dark: (0.32, 0.22, 0.26))
    static let rose = token("rose", light: (0.86, 0.42, 0.54), dark: (0.90, 0.50, 0.60))
    static let roseDeep = token("roseDeep", light: (0.62, 0.24, 0.36), dark: (0.58, 0.20, 0.32))
    static let rosePressed = token("rosePressed", light: (0.74, 0.32, 0.44), dark: (0.78, 0.36, 0.48))
    static let roseHi = token("roseHi", light: (0.98, 0.78, 0.84), dark: (0.86, 0.58, 0.66))
    static let warn = token("warn", light: (0.78, 0.28, 0.32), dark: (0.88, 0.46, 0.48))

    /// Paper glass — night is dark rose glass, not inverted white.
    static let paper = token("paper", light: (1, 1, 1, 0.74), dark: (0.20, 0.13, 0.16, 0.82))
    static let paperHover = token("paperHover", light: (1, 1, 1, 0.92), dark: (0.26, 0.16, 0.20, 0.90))
    static let pill = token("pill", light: (1, 1, 1, 0.88), dark: (0.28, 0.16, 0.20, 0.92))
    static let pillHover = token("pillHover", light: (1, 1, 1, 0.40), dark: (0.24, 0.14, 0.18, 0.55))
    static let chip = token("chip", light: (0, 0, 0, 0.05), dark: (1, 0.94, 0.95, 0.08))
    static let glass = token("glass", light: (1, 1, 1, 0.45), dark: (0.30, 0.18, 0.22, 0.50))
    static let cardStroke = token("cardStroke", light: (1, 1, 1, 0.88), dark: (0.46, 0.30, 0.34, 0.55))
    static let iconWell = token("iconWell", light: (0, 0, 0, 0.05), dark: (1, 0.94, 0.95, 0.08))
    /// Labels on rose (not liquid depth). Night: petal, readable on plum.
    static let accentText = token("accentText", light: (0.62, 0.24, 0.36), dark: (0.94, 0.70, 0.76))
    /// Glass highlights — warm pearl at night, not chalk white.
    static let glassHi = token("glassHi", light: (1, 1, 1), dark: (0.94, 0.86, 0.88))
    static let cardShadow = token("cardShadow", light: (0.62, 0.24, 0.36, 0.08), dark: (0.02, 0.00, 0.01, 0.55))
    static let pillShadow = token("pillShadow", light: (0, 0, 0, 0.05), dark: (0, 0, 0, 0.35))
    /// Protected disk segment — dusty mauve, not a hole, not mint.
    static let reserved = token("reserved", light: (0.70, 0.56, 0.58), dark: (0.50, 0.34, 0.38))

    static let card = paper
    static let action = rose
    static let actionPressed = rosePressed
    static let liquidHi = roseHi
    static let liquidMid = rose
    static let liquidLo = roseDeep
    static let glow = token("glow", light: (0.86, 0.42, 0.54, 0.28), dark: (0.90, 0.48, 0.58, 0.40))

    private static func token(
        _ name: String,
        light: (CGFloat, CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: NSColor.Name("cam98.\(name)")) { appearance in
            let night = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let t = night ? dark : light
            return NSColor(srgbRed: t.0, green: t.1, blue: t.2, alpha: t.3)
        })
    }

    private static func token(
        _ name: String,
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        token(name, light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }
}

/// 4pt spacing grid (TZ §4.4)
enum S {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 20
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    static let sidebar: CGFloat = 228
    static let trafficClearance: CGFloat = 36
    static let cardMin: CGFloat = 236
    static let cardRadius: CGFloat = 18
    static let buttonRadius: CGFloat = 12
    static let iconSquircle: CGFloat = 8
    static let hitMin: CGFloat = 28
    static let orbTitleGap: CGFloat = 14
}

enum F {
    static func largeTitle(compact: Bool = false) -> Font {
        .system(size: compact ? 22 : 28, weight: .semibold, design: .rounded)
    }
    static func title() -> Font { .system(size: 15, weight: .semibold, design: .rounded) }
    static func body() -> Font { .system(size: 13, weight: .regular) }
    static func callout() -> Font { .system(size: 12, weight: .regular) }
    static func size() -> Font { .system(size: 13, weight: .semibold, design: .rounded).monospacedDigit() }
    static func heroSize() -> Font { .system(size: 36, weight: .semibold, design: .rounded).monospacedDigit() }
    static func stat() -> Font { .system(size: 15, weight: .semibold, design: .rounded).monospacedDigit() }
    static func button() -> Font { .system(size: 15, weight: .semibold, design: .rounded) }
    static func micro() -> Font { .system(size: 10, weight: .semibold) }
}

enum Art {
    static func image(_ name: String) -> NSImage {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let img = NSImage(contentsOf: url) {
            img.isTemplate = false
            return img
        }
        return NSImage()
    }
}

struct CardBackground: View {
    var selected: Bool = false
    var hover: Bool = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous)
            .fill(hover ? C.paperHover : C.paper)
            .overlay(
                RoundedRectangle(cornerRadius: S.cardRadius, style: .continuous)
                    .stroke(
                        selected
                            ? C.liquidLo.opacity(increased ? 0.90 : 0.55)
                            : (increased ? C.ink.opacity(0.28) : C.cardStroke),
                        lineWidth: selected ? (increased ? 2 : 1.4) : (increased ? 1.5 : 1)
                    )
            )
            .shadow(color: C.cardShadow.opacity(hover ? 1.4 : 1), radius: hover ? 18 : 10, y: 6)
    }
}

struct MicroBadge: View {
    enum Tone { case safe, quiet, caution }
    var text: String
    var tone: Tone = .quiet

    private var ink: Color {
        switch tone {
        case .safe: C.accentText
        case .quiet: C.secondary
        case .caution: C.warn
        }
    }

    private var fill: Color {
        switch tone {
        case .safe: C.action.opacity(0.12)
        case .quiet: C.chip
        case .caution: C.warn.opacity(0.10)
        }
    }

    var body: some View {
        Text(text)
            .font(F.micro())
            .tracking(0.6)
            .foregroundStyle(ink)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(fill))
    }
}

struct BannerInfo: View {
    var text: String

    var body: some View {
        HStack(alignment: .top, spacing: S.sm) {
            CamIcon(glyph: .check, size: 13)
                .foregroundStyle(C.accentText)
                .padding(.top, 1)
            Text(text)
                .font(F.callout())
                .foregroundStyle(C.accentText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(S.sm)
        .background(
            RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                .fill(C.action.opacity(0.10))
        )
        .accessibilityElement(children: .combine)
    }
}

struct BannerWarn: View {
    var text: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: S.sm) {
            CamIcon(glyph: .warn, size: 13)
                .foregroundStyle(C.warn)
                .padding(.top, 1)
            Text(text)
                .font(F.callout())
                .foregroundStyle(C.warn)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(GhostButton())
            }
        }
        .padding(S.sm)
        .background(
            RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                .fill(C.warn.opacity(0.08))
        )
        .accessibilityElement(children: .combine)
    }
}

struct FocusStroke: ViewModifier {
    var radius: CGFloat
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let increased = contrast == .increased
        content.overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(C.action.opacity(focused ? 1 : 0), lineWidth: increased ? 2.2 : 1.6)
                .padding(-2)
                .allowsHitTesting(false)
        )
    }
}

extension View {
    func focusStroke(radius: CGFloat) -> some View {
        modifier(FocusStroke(radius: radius))
    }
}

struct ProgressCapsule: View {
    var progress: Double
    @Environment(\.copyLang) private var lang

    var body: some View {
        Capsule()
            .fill(C.glass)
            .frame(width: 220, height: 6)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(C.action)
                    .frame(width: 220 * max(0.08, min(1, progress)))
            }
            .accessibilityLabel(Copy.progress.t(lang))
            .accessibilityValue(Copy.percent(Int(max(0, min(1, progress)) * 100)).t(lang))
    }
}

struct ProtectedList: View {
    @Environment(AppState.self) private var state
    @Environment(\.copyLang) private var lang

    private var rows: [ShieldRow] {
        let _ = state.extraProtected
        return Keep.visibleShields()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: S.xs) {
            Text(Copy.dontTouch.t(lang))
                .font(F.title())
            Text(Copy.exclusionsLead.t(lang))
                .font(F.callout())
                .foregroundStyle(C.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            ForEach(rows) { row in
                ProtectedRow(
                    name: row.name,
                    reason: row.reason.t(lang),
                    removable: row.removable,
                    onRemove: row.removable ? { state.removeExclusion(row.path) } : nil
                )
            }
            Button(Copy.addFolder.t(lang)) {
                state.pickExclusions()
            }
            .buttonStyle(QuietButton())
            .padding(.top, 6)
        }
        .padding(S.lg)
        .background(CardBackground())
    }
}

private struct ProtectedRow: View {
    let name: String
    let reason: String
    var removable: Bool = false
    var onRemove: (() -> Void)?
    @Environment(\.copyLang) private var lang
    @State private var hover = false

    var body: some View {
        HStack(spacing: S.xs) {
            CamIcon(glyph: .lock, size: 11)
                .foregroundStyle(C.accentText)
                .frame(width: 14)
            Text(name)
                .font(F.body())
                .foregroundStyle(C.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if removable, let onRemove {
                Button(Copy.removeExclusion.t(lang), action: onRemove)
                    .buttonStyle(GhostButton())
            }
        }
        .padding(.horizontal, 6)
        .frame(minHeight: S.hitMin)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hover ? C.pillHover : Color.clear)
        )
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.08), value: hover)
        .help(reason)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityHint(reason)
    }
}
