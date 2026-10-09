import SwiftUI

/// Liquid Glass helpers (macOS 26+) with no-op fallbacks on older systems.
enum GlassChrome {
    static var isLiquid: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Nearby controls share one sampling region on macOS 26. A 6pt merge distance keeps
/// buttons visually separate at rest while still letting native Liquid Glass render
/// and animate them as a coherent functional layer.
struct GlassActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 6) {
                content()
            }
        } else {
            content()
        }
    }
}

enum CamGlassShape {
    case rounded, card, capsule, circle
}

extension View {
    /// Dusty-rose Liquid Glass surface. No-op before macOS 26.
    @ViewBuilder
    func camGlass(
        tint: Color? = nil,
        interactive: Bool = true,
        shape: CamGlassShape = .rounded
    ) -> some View {
        if #available(macOS 26.0, *) {
            let glass = Self.makeGlass(tint: tint, interactive: interactive)
            switch shape {
            case .rounded:
                self.glassEffect(glass, in: .rect(cornerRadius: S.buttonRadius))
            case .card:
                self.glassEffect(glass, in: .rect(cornerRadius: S.cardRadius))
            case .capsule:
                self.glassEffect(glass, in: .capsule)
            case .circle:
                self.glassEffect(glass, in: .circle)
            }
        } else {
            self
        }
    }

    @available(macOS 26.0, *)
    private static func makeGlass(tint: Color?, interactive: Bool) -> Glass {
        var g = Glass.regular
        if let tint {
            g = g.tint(tint)
        }
        if interactive {
            g = g.interactive()
        }
        return g
    }

    /// Floating functional chrome: native Liquid Glass on Tahoe, one carefully
    /// layered material panel on older macOS. Use for headers and navigation, not
    /// for every content card.
    @ViewBuilder
    func camFunctionalGlass(
        family: CareFamily,
        interactive: Bool = false,
        radius: CGFloat = S.cardRadius + 4
    ) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                Self.makeGlass(tint: family.mid.opacity(0.12), interactive: interactive),
                in: .rect(cornerRadius: radius)
            )
        } else {
            self.background(
                CardBackground(
                    selected: false,
                    hover: false,
                    family: family,
                    radius: radius,
                    prominent: true
                )
            )
        }
    }
}

/// Small optical well for glyphs. Content icons use the lightweight material
/// treatment by default; truly floating controls can opt into native glass.
struct GlassIconWell: View {
    let glyph: Glyph
    var family: CareFamily = .system
    var selected = false
    var muted = false
    var size: CGFloat = 30
    var glyphSize: CGFloat = 16
    var lightInk = false
    var nativeGlass = false

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let content = CamIcon(glyph: glyph, size: glyphSize)
            .foregroundStyle(iconInk)
            .frame(width: size, height: size)

        Group {
            if #available(macOS 26.0, *), nativeGlass {
                content.camGlass(
                    tint: family.mid.opacity(selected ? 0.28 : 0.12),
                    interactive: false,
                    shape: .rounded
                )
            } else {
                content.background(fallback)
            }
        }
        .shadow(
            color: selected ? family.glow.opacity(0.65) : C.pillShadow.opacity(0.75),
            radius: selected ? 9 : 5,
            y: selected ? 3 : 2
        )
    }

    private var iconInk: Color {
        if lightInk { return Color.white.opacity(muted ? 0.62 : 0.94) }
        if selected { return C.accentText.opacity(muted ? 0.62 : 1) }
        return C.secondary.opacity(muted ? 0.55 : 0.88)
    }

    private var fallback: some View {
        let shape = RoundedRectangle(cornerRadius: min(11, size * 0.34), style: .continuous)
        return ZStack {
            shape.fill(
                reduceTransparency
                    ? AnyShapeStyle(C.paper)
                    : AnyShapeStyle(.ultraThinMaterial)
            )
            shape.fill(
                LinearGradient(
                    colors: scheme == .dark
                        ? [Color.white.opacity(0.18), family.mid.opacity(0.16), Color.black.opacity(0.08)]
                        : [Color.white.opacity(0.66), family.hi.opacity(0.24), family.mid.opacity(0.10)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape.stroke(
                LinearGradient(
                    colors: [Color.white.opacity(0.76), family.mid.opacity(0.30), Color.white.opacity(0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
    }
}
