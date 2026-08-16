import SwiftUI

/// Full-window wash — under sidebar and main pane on every module.
struct ShellAtmosphere: View {
    /// Rich Smart Care chrome (scan + results).
    var richCare: Bool
    var family: CareFamily
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if richCare {
                LinearGradient(
                    colors: scheme == .dark
                        ? [
                            Color(red: 0.16, green: 0.06, blue: 0.14),
                            Color(red: 0.09, green: 0.03, blue: 0.08),
                            Color(red: 0.05, green: 0.02, blue: 0.05)
                        ]
                        : [
                            // Day Smart Care: pale lilac paper — dark ink must read clearly.
                            Color(red: 0.94, green: 0.88, blue: 0.92),
                            Color(red: 0.88, green: 0.78, blue: 0.86),
                            Color(red: 0.82, green: 0.70, blue: 0.80)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [family.mid.opacity(scheme == .dark ? 0.42 : 0.18), .clear],
                    center: UnitPoint(x: 0.55, y: 0.35),
                    startRadius: 20,
                    endRadius: 560
                )
                RadialGradient(
                    colors: [family.lo.opacity(scheme == .dark ? 0.26 : 0.12), .clear],
                    center: UnitPoint(x: 0.9, y: 0.95),
                    startRadius: 10,
                    endRadius: 360
                )
            } else {
                // Same language of light as Smart Care — dusty rose depth, not a flat white slab.
                LinearGradient(
                    colors: scheme == .dark
                        ? [
                            Color(red: 0.14, green: 0.07, blue: 0.10),
                            Color(red: 0.08, green: 0.04, blue: 0.06),
                            Color(red: 0.04, green: 0.02, blue: 0.04)
                        ]
                        : [
                            Color(red: 0.93, green: 0.86, blue: 0.90),
                            Color(red: 0.87, green: 0.74, blue: 0.82),
                            Color(red: 0.80, green: 0.64, blue: 0.74)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [
                        family.mid.opacity(scheme == .dark ? 0.28 : 0.34),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.62, y: 0.28),
                    startRadius: 30,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [
                        C.glow.opacity(scheme == .dark ? 0.35 : 0.50),
                        Color.clear
                    ],
                    center: .top,
                    startRadius: 16,
                    endRadius: 480
                )
                .blendMode(scheme == .dark ? .plusLighter : .normal)
                RadialGradient(
                    colors: [family.lo.opacity(scheme == .dark ? 0.20 : 0.24), .clear],
                    center: UnitPoint(x: 0.08, y: 0.92),
                    startRadius: 8,
                    endRadius: 340
                )
            }
        }
        .ignoresSafeArea()
        .animation(Motion.easeModule, value: richCare)
        .animation(Motion.easeMicro, value: family)
    }
}
