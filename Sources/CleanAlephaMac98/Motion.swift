import AppKit
import SwiftUI

/// Motion tokens from TZ-02 §6. Do not invent a new spring per screen.
enum Motion {
    static let springOrb: Animation = .spring(response: 0.80, dampingFraction: 0.84)
    static let springUI: Animation = .spring(response: 0.42, dampingFraction: 0.86)
    static let easeLevel: Animation = .easeInOut(duration: 0.85)
    static let easePress: Animation = .easeOut(duration: 0.12)
    static let easeHover: Animation = .easeOut(duration: 0.18)
    static let easeMicro: Animation = .easeInOut(duration: 0.20)
    static let easeReduced: Animation = .easeInOut(duration: 0.18)
    static let easeModule: Animation = .easeInOut(duration: 0.12)
    static let easeIntro: Animation = .easeOut(duration: 0.18)
    static let easeDisk: Animation = .easeInOut(duration: 0.40)
    static let flyLift: CGFloat = 12
    static let flyUp: Double = 0.36
    static let flyDown: Double = 0.44
    static let headerDelay: Double = 0.06
    static let cardGateDelay: Double = 0.10
    static let staggerStep: Double = 0.025
    static let staggerCap: Double = 0.40
    static let hoverLift: CGFloat = 1.015

    static func layout(reduce: Bool) -> Animation {
        reduce ? easeReduced : springOrb
    }

    static func level(reduce: Bool) -> Animation {
        reduce ? easeReduced : easeLevel
    }

    static func stagger(index: Int, reduce: Bool) -> Double {
        if reduce { return 0 }
        return cardGateDelay + min(staggerCap, Double(index) * staggerStep)
    }
}

struct PrimaryButton: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        PrimaryButtonBody(configuration: configuration, enabled: enabled)
    }
}

private struct PrimaryButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var enabled: Bool
    @State private var hover = false

    private var glare: Double {
        if !enabled { return 0.08 }
        if configuration.isPressed { return 0 }
        return hover ? 0.22 : 0.16
    }

    var body: some View {
        configuration.label
            .font(F.button())
            .foregroundStyle(.white)
            .frame(minWidth: 176, minHeight: 40)
            .padding(.horizontal, 10)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: enabled
                                    ? [C.action, C.actionPressed]
                                    : [C.action.opacity(0.35), C.action.opacity(0.28)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                        .fill(C.glassHi.opacity(glare))
                        .mask(
                            LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)
                        )
                }
            )
            .shadow(color: C.glow.opacity(enabled ? (hover ? 1.15 : 1) : 0), radius: hover && enabled ? 12 : 10, y: 4)
            .focusStroke(radius: S.buttonRadius)
            .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
            .animation(Motion.easeHover, value: hover)
            .onHover { hovering in
                hover = hovering && enabled
                if !enabled {
                    NSCursor.operationNotAllowed.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
    }
}

struct QuietButton: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.button())
            .foregroundStyle(C.ink.opacity(enabled ? 1 : 0.45))
            .frame(minHeight: 40)
            .padding(.horizontal, S.md)
            .background(
                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                    .fill(enabled ? (configuration.isPressed ? C.paperHover : C.paper) : C.paper.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                    .stroke(C.cardStroke, lineWidth: 1)
            )
            .focusStroke(radius: S.buttonRadius)
            .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
    }
}
struct GhostButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.callout())
            .foregroundStyle(C.secondary.opacity(configuration.isPressed ? 0.7 : 1))
            .frame(minHeight: S.hitMin)
            .padding(.horizontal, S.xs)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
    }
}

/// Quiet trash action — rose.deep, not alarm red (TZ-01 §7.5).
struct DestructiveQuiet: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(F.button())
            .foregroundStyle(enabled ? C.accentText : C.accentText.opacity(0.40))
            .frame(minWidth: 176, minHeight: 40)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                    .fill(C.action.opacity(enabled ? (configuration.isPressed ? 0.22 : 0.14) : 0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                    .stroke(C.accentText.opacity(enabled ? 0.35 : 0.12), lineWidth: 1)
            )
            .focusStroke(radius: S.buttonRadius)
            .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
    }
}

/// Makes empty chrome draggable; clicks on controls still work.
struct WindowBackgroundDrag: NSViewRepresentable {
    var appearance: AppearanceChoice = .system

    func makeNSView(context: Context) -> NSView {
        DragNSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.isMovableByWindowBackground = true
        nsView.window?.titlebarAppearsTransparent = true
        nsView.window?.setFrameAutosaveName("CAM98.Main")
        nsView.window?.appearance = appearance.nsAppearance
    }
}

private final class DragNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.isMovableByWindowBackground = true
        window?.titlebarAppearsTransparent = true
        window?.setFrameAutosaveName("CAM98.Main")
    }
}

/// One quiet glass tick on complete (TZ-02 §8). No whoosh, no per-check click.
@MainActor
enum GlassTick {
    private static var current: NSSound?

    static func play() {
        guard let url = Bundle.main.url(forResource: "glass-tick", withExtension: "wav"),
              let sound = NSSound(contentsOf: url, byReference: true) else { return }
        sound.volume = 0.55
        current = sound
        current?.play()
    }
}
