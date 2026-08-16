import AppKit
import SwiftUI

/// Glass sphere with liquid that occupies a spherical cap — not a rectangular wipe.
/// Rim is drawn outside the liquid clip (TZ §1). Idle: f≈0.42, bob ±1.1px, A=0.012R.
/// Cleaning: quieter surface, no scan arc, no bubbles (TZ-02 §3.6).
struct HeroOrb: View {
    var fill: Double
    var scanning: Bool
    var cleaning: Bool = false
    var size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appActive = true

    /// Only animate while work is happening. Idle = one static frame (0% display link).
    private var shouldAnimate: Bool {
        appActive && !reduceMotion && (scanning || cleaning)
    }

    var body: some View {
        let level = max(0.06, min(0.94, fill))
        let interval: Double = scanning ? 1.0 / 16.0 : 1.0 / 12.0
        Group {
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: interval, paused: false)) { timeline in
                    orbFrame(
                        level: level,
                        t: timeline.date.timeIntervalSinceReferenceDate,
                        reduced: false
                    )
                }
            } else {
                orbFrame(level: level, t: 0, reduced: true)
            }
        }
        .frame(width: size, height: size)
        .aspectRatio(1, contentMode: .fit)
        .animation(Motion.level(reduce: reduceMotion), value: fill)
        .onAppear { appActive = NSApp.isActive }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            appActive = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            appActive = false
        }
    }

    @ViewBuilder
    private func orbFrame(level: Double, t: Double, reduced: Bool) -> some View {
        let phase = reduced ? 0.0 : t * (scanning ? 2.8 : (cleaning ? 1.4 : 1.15))
        let amp = reduced ? 0.0 : (scanning ? 0.034 : (cleaning ? 0.018 : 0.012))
        let bob: CGFloat = reduced ? 0 : sin(t * 1.15) * (scanning ? 2.2 : (cleaning ? 0.55 : 1.1))
        let glowOpacity = scanning ? 0.30 : (cleaning ? 0.18 : 0.12)
        let specularDrift = reduced ? 0.0 : sin(t * (2 * .pi / 10.0)) * 0.012

        ZStack {
            Ellipse()
                .fill(C.glow.opacity(glowOpacity / 0.28))
                .frame(width: size * 0.52, height: size * 0.10)
                .offset(y: size * 0.42 + bob)
                .blur(radius: scanning ? 12 : 8)

            sphere(
                level: level,
                phase: phase,
                amp: amp,
                t: t,
                specularDrift: specularDrift,
                reduced: reduced,
                cleaning: cleaning
            )
            .offset(y: bob)
        }
        .frame(width: size, height: size)
    }

    private func sphere(
        level: Double,
        phase: Double,
        amp: Double,
        t: Double,
        specularDrift: Double,
        reduced: Bool,
        cleaning: Bool
    ) -> some View {
        let wall = max(5, size * 0.072)
        let inner = wall * 0.78
        let geo = OrbGeo(size: size, inset: wall, fill: level)
        let causticShift = reduced ? 0.0 : sin(t * (2 * .pi / 12.0)) * size * 0.02

        return ZStack {
            // Liquid + interior — clipped inside the glass wall
            ZStack {
                // Glass back / air cavity — transparent, not a white disc
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                C.glassHi.opacity(0.16),
                                C.glassHi.opacity(0.05),
                                C.liquidMid.opacity(0.04),
                                Color.clear
                            ],
                            center: UnitPoint(x: 0.36, y: 0.28),
                            startRadius: 0,
                            endRadius: size * 0.48
                        )
                    )

                // Liquid volume — deep at bottom, lighter toward surface
                SphericalCap(fill: level, phase: phase, amplitude: amp, inset: wall, meniscus: 0.025)
                    .fill(
                        RadialGradient(
                            colors: [C.liquidLo, C.liquidMid, C.liquidHi],
                            center: UnitPoint(x: 0.45, y: 0.88),
                            startRadius: 2,
                            endRadius: size * 0.58
                        )
                    )
                    .opacity(0.94)

                // Inner caustic near the bottom
                Ellipse()
                    .fill(
                        RadialGradient(
                            colors: [C.liquidHi.opacity(0.45), Color.clear],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.22
                        )
                    )
                    .frame(width: size * 0.42, height: size * 0.22)
                    .offset(x: -size * 0.04 + causticShift, y: size * 0.22)
                    .blendMode(.plusLighter)
                    .mask(
                        SphericalCap(fill: level, phase: 0, amplitude: 0, inset: wall, meniscus: 0)
                    )

                SphericalCap(fill: level, phase: phase + 0.7, amplitude: amp * 0.45, inset: wall + size * 0.02, meniscus: 0.02)
                    .fill(C.glassHi.opacity(0.14))
                    .blendMode(.plusLighter)
                    .mask(
                        LinearGradient(colors: [.white, .clear], startPoint: .bottom, endPoint: .center)
                    )

                waterSurface(geo: geo, phase: phase, amp: amp)

                if scanning && !reduced {
                    Bubbles(fill: level, inset: wall, t: t, size: size)
                }

                // Specular A — slow drift 8–12s
                Ellipse()
                    .fill(C.glassHi.opacity(0.58))
                    .frame(width: size * 0.28, height: size * 0.12)
                    .offset(
                        x: -size * 0.15 + size * specularDrift,
                        y: -size * 0.22 - size * specularDrift * 0.4
                    )
                    .blur(radius: 1.1)
                    .rotationEffect(.degrees(-18))

                // Specular B
                Ellipse()
                    .fill(C.glassHi.opacity(0.22))
                    .frame(width: size * 0.07, height: size * 0.24)
                    .offset(
                        x: size * 0.26 - size * specularDrift * 0.5,
                        y: -size * 0.02
                    )
                    .blur(radius: 0.7)
            }
            .padding(wall * 0.35)
            .clipShape(Circle())

            // Rim OUTSIDE liquid clip — readable glass edge
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            C.glassHi.opacity(0.95),
                            C.liquidHi.opacity(0.70),
                            C.liquidMid.opacity(0.35),
                            C.glassHi.opacity(0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: wall
                )

            Circle()
                .stroke(C.glassHi.opacity(0.88), lineWidth: max(1.4, size * 0.012))

            Circle()
                .stroke(C.liquidLo.opacity(0.22), lineWidth: max(1, size * 0.008))
                .padding(0.6)

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [C.glassHi.opacity(0.70), C.liquidMid.opacity(0.18), C.glassHi.opacity(0.40)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: max(1.2, size * 0.010)
                )
                .padding(inner)

            if scanning {
                Circle()
                    .trim(from: 0, to: 0.18)
                    .stroke(
                        AngularGradient(
                            colors: [C.action.opacity(0), C.action, C.glassHi],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: max(2.4, size * 0.018), lineCap: .round)
                    )
                    .padding(wall * 0.18)
                    .rotationEffect(.degrees(reduced ? 40 : t * 210))
            }
        }
        .frame(width: size, height: size)
        .shadow(
            color: C.action.opacity(scanning ? 0.42 : (cleaning ? 0.26 : 0.16)),
            radius: scanning ? 24 : (cleaning ? 16 : 12),
            y: 6
        )
    }

    private func waterSurface(geo: OrbGeo, phase: Double, amp: Double) -> some View {
        let w = geo.chord * 2
        let h = max(6, w * (0.17 + 0.10 * abs(geo.dy) / max(geo.r, 1)))
        return ZStack {
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [
                            C.glassHi.opacity(0.42),
                            C.liquidHi.opacity(0.70),
                            C.liquidMid.opacity(0.40)
                        ],
                        center: UnitPoint(x: 0.45, y: 0.35),
                        startRadius: 0,
                        endRadius: w * 0.55
                    )
                )
            Ellipse()
                .stroke(C.glassHi.opacity(0.45), lineWidth: 1)
                .blur(radius: 0.3)
            // Meniscus lift at the walls (ends of chord)
            Meniscus(phase: phase, amplitude: amp)
                .stroke(C.glassHi.opacity(0.55), lineWidth: 1.1)
                .padding(.horizontal, 2)
        }
        .frame(width: w, height: h)
        .offset(y: geo.surfaceY - geo.cy)
        .allowsHitTesting(false)
    }
}

private struct OrbGeo {
    var size: CGFloat
    var inset: CGFloat
    var fill: Double

    var r: CGFloat { size / 2 - inset }
    var cx: CGFloat { size / 2 }
    var cy: CGFloat { size / 2 }
    var surfaceY: CGFloat { cy + r - 2 * r * CGFloat(fill) }
    var dy: CGFloat { surfaceY - cy }
    var chord: CGFloat { sqrt(max(1, r * r - dy * dy)) }
}

/// Liquid volume: circular arc along the glass, wavy meniscus as the free surface.
/// `meniscus` lifts the surface near the walls (fraction of R).
private struct SphericalCap: Shape {
    var fill: Double
    var phase: Double
    var amplitude: Double
    var inset: CGFloat
    var meniscus: Double

    var animatableData: AnimatablePair<Double, AnimatablePair<Double, Double>> {
        get { AnimatablePair(fill, AnimatablePair(phase, amplitude)) }
        set {
            fill = newValue.first
            phase = newValue.second.first
            amplitude = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let r = max(4, s / 2 - inset)
        let cx = rect.midX
        let cy = rect.midY
        let f = max(0.04, min(0.96, fill))
        let y0 = cy + r - 2 * r * CGFloat(f)
        let dy = y0 - cy
        let half = sqrt(max(1, r * r - dy * dy))
        let amp = r * CGFloat(amplitude)
        let menLift = r * CGFloat(meniscus)
        let left = CGPoint(x: cx - half, y: y0 - menLift * 0.35)
        let right = CGPoint(x: cx + half, y: y0 - menLift * 0.35)
        let start = Angle(radians: atan2(left.y - cy, left.x - cx))
        let end = Angle(radians: atan2(right.y - cy, right.x - cx))

        var p = Path()
        p.move(to: left)
        // y-down coords: clockwise left→right sweeps the BOTTOM (liquid volume)
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: start, endAngle: end, clockwise: true)

        let steps = 48
        for i in 0...steps {
            let tt = CGFloat(i) / CGFloat(steps)
            let x = right.x - 2 * half * tt
            let nx = Double((x - cx) / r)
            let edge = abs(nx)
            let wallLift = menLift * CGFloat(pow(edge, 2.2))
            var y = y0
                - wallLift
                + sin(nx * .pi * 2.15 + phase) * amp
                + sin(nx * .pi * 4.4 + phase * 1.55) * amp * 0.32
            let maxOff = sqrt(max(0, r * r - (x - cx) * (x - cx)))
            y = min(cy + maxOff - 0.8, max(cy - maxOff + 0.8, y))
            p.addLine(to: CGPoint(x: x, y: y))
        }
        p.closeSubpath()
        return p
    }
}

private struct Meniscus: Shape {
    var phase: Double
    var amplitude: Double

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let steps = 28
        for i in 0...steps {
            let tt = CGFloat(i) / CGFloat(steps)
            let x = rect.width * tt
            let nx = Double(tt * 2 - 1)
            let edgeLift = pow(abs(nx), 2.2) * rect.height * 0.22
            let y = rect.midY
                - edgeLift
                + sin(nx * .pi * 2.15 + phase) * rect.height * CGFloat(amplitude) * 2.2
            if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
            else { p.addLine(to: CGPoint(x: x, y: y)) }
        }
        return p
    }
}

private struct Bubbles: View {
    var fill: Double
    var inset: CGFloat
    var t: Double
    var size: CGFloat

    var body: some View {
        Canvas { ctx, canvas in
            let r = canvas.width / 2 - inset
            let c = CGPoint(x: canvas.width / 2, y: canvas.height / 2)
            let ySurf = c.y + r - 2 * r * CGFloat(fill)
            for i in 0..<9 {
                let seed = Double(i) * 17.13
                let life = (t * (0.35 + Double(i).truncatingRemainder(dividingBy: 0.4)) + seed)
                    .truncatingRemainder(dividingBy: 2.4) / 2.4
                let ang = seed * 0.4
                let rad = r * (0.15 + 0.55 * CGFloat((sin(seed) + 1) / 2))
                let x = c.x + cos(ang) * rad * 0.55
                let yStart = c.y + r * 0.72
                let y = yStart - CGFloat(life) * r * 1.15
                let br = 1.6 + CGFloat(i % 3)
                guard y < ySurf - 4, hypot(x - c.x, y - c.y) < r - 6 else { continue }
                let rect = CGRect(x: x - br, y: y - br, width: br * 2, height: br * 2)
                ctx.opacity = 0.35 * (1 - life)
                ctx.fill(Path(ellipseIn: rect), with: .color(C.glassHi))
            }
        }
        .allowsHitTesting(false)
    }
}
