import SwiftUI

/// Liquid Glass helpers (macOS 26+) with no-op fallbacks on older systems.
enum GlassChrome {
    static var isLiquid: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
}

/// Nearby glass without forced morph-merge.
/// Apple's GlassEffectContainer merges anything closer than `spacing` —
/// our action chips sit ~8–12pt apart, so a 24pt threshold glued them into one blob.
struct GlassActions<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
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
}
