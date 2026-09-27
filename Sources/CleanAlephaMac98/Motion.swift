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
    /// Day ↔ night: longer than micro UI, shorter than orb fill.
    static let themeCross: Animation = .timingCurve(0.22, 1, 0.36, 1, duration: 0.55)
    static let themeWashIn: Animation = .easeOut(duration: 0.28)
    static let themeWashOut: Animation = .easeIn(duration: 0.50)
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

/// Lets the click that activates an inactive window also press this control. SwiftUI swallows that
/// first click by default, so after switching over from another app "Scan" needed a second press.
/// Only for non-destructive controls (scan, stop, navigation) — never Clean, where a click meant to
/// focus the window must not start deleting.
struct ActsOnFirstClick: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.allowsWindowActivationEvents(true)
        } else {
            content
        }
    }
}

extension View {
    func actsOnFirstClick() -> some View { modifier(ActsOnFirstClick()) }
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
        let label = configuration.label
            .font(F.button())
            .foregroundStyle(enabled ? Color.white : Color.white.opacity(0.55))
            .frame(minWidth: 176, minHeight: 40)
            .padding(.horizontal, 10)

        Group {
            if #available(macOS 26.0, *) {
                label
                    .camGlass(
                        tint: enabled ? C.action : C.action.opacity(0.35),
                        interactive: enabled,
                        shape: .rounded
                    )
            } else {
                label
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
            }
        }
        .focusStroke(radius: S.buttonRadius)
        .opacity(configuration.isPressed && enabled ? 0.92 : 1)
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
        QuietButtonBody(configuration: configuration, enabled: enabled)
    }
}

private struct QuietButtonBody: View {
    let configuration: ButtonStyleConfiguration
    var enabled: Bool
    @Environment(\.careChrome) private var careChrome

    var body: some View {
        let label = configuration.label
            .font(F.button())
            .foregroundStyle(
                careChrome
                    ? C.careInk.opacity(enabled ? 1 : 0.45)
                    : C.ink.opacity(enabled ? 1 : 0.45)
            )
            .frame(minHeight: 40)
            .padding(.horizontal, S.md)

        Group {
            if #available(macOS 26.0, *) {
                label
                    .camGlass(
                        tint: C.action.opacity(enabled ? (careChrome ? 0.28 : 0.18) : 0.08),
                        interactive: enabled,
                        shape: .rounded
                    )
            } else {
                label
                    .background(
                        RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                            .fill(.thinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                                    .fill(
                                        enabled
                                            ? (careChrome
                                                ? C.careInk.opacity(configuration.isPressed ? 0.14 : 0.08)
                                                : C.action.opacity(configuration.isPressed ? 0.14 : 0.07))
                                            : C.action.opacity(0.03)
                                    )
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                            .stroke(careChrome ? C.careInk.opacity(0.28) : C.cardStroke, lineWidth: 1)
                    )
            }
        }
        .focusStroke(radius: S.buttonRadius)
        .opacity(configuration.isPressed && enabled ? 0.92 : 1)
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
        GhostButtonBody(configuration: configuration)
    }
}

private struct GhostButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.careChrome) private var careChrome
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false

    var body: some View {
        let label = configuration.label
            .font(F.callout())
            .foregroundStyle(
                (careChrome ? C.careSecondary : C.secondary)
                    .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.42)
            )
            .frame(minHeight: S.hitMin)
            .padding(.horizontal, S.sm)

        Group {
            if #available(macOS 26.0, *) {
                label.camGlass(
                    tint: C.action.opacity(hover ? 0.12 : 0.04),
                    interactive: enabled,
                    shape: .capsule
                )
            } else {
                label.background(
                    Capsule()
                        .fill(.ultraThinMaterial)
                        .overlay(Capsule().fill(C.action.opacity(hover ? 0.11 : 0.035)))
                        .overlay(Capsule().stroke(Color.white.opacity(hover ? 0.55 : 0.25), lineWidth: 1))
                )
            }
        }
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
            .animation(Motion.easeHover, value: hover)
            .onHover { hover = enabled && $0 }
    }
}

/// Quiet trash action — rose.deep, not alarm red (TZ-01 §7.5).
struct DestructiveQuiet: ButtonStyle {
    var enabled: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        DestructiveQuietBody(configuration: configuration, enabled: enabled)
    }
}

private struct DestructiveQuietBody: View {
    let configuration: ButtonStyleConfiguration
    var enabled: Bool

    var body: some View {
        let label = configuration.label
            .font(F.button())
            .foregroundStyle(enabled ? C.accentText : C.accentText.opacity(0.40))
            .frame(minWidth: 176, minHeight: 40)
            .padding(.horizontal, 10)

        Group {
            if #available(macOS 26.0, *) {
                label
                    .camGlass(
                        tint: C.action.opacity(enabled ? 0.28 : 0.10),
                        interactive: enabled,
                        shape: .rounded
                    )
            } else {
                label
                    .background(
                        RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                            .fill(C.action.opacity(enabled ? (configuration.isPressed ? 0.22 : 0.14) : 0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                            .stroke(C.accentText.opacity(enabled ? 0.35 : 0.12), lineWidth: 1)
                    )
            }
        }
        .focusStroke(radius: S.buttonRadius)
        .opacity(configuration.isPressed && enabled ? 0.92 : 1)
        .scaleEffect(configuration.isPressed && enabled ? 0.98 : 1)
        .animation(Motion.easePress, value: configuration.isPressed)
    }
}

struct BackChromeButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        let label = configuration.label
            .font(F.button())
            .foregroundStyle(C.accentText)
            .frame(minHeight: 40)
            .padding(.horizontal, S.md)

        Group {
            if #available(macOS 26.0, *) {
                label.camGlass(tint: C.action.opacity(0.14), interactive: true, shape: .rounded)
            } else {
                label
                    .background(
                        RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                            .fill(.thinMaterial)
                            .overlay(
                                RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                                    .fill(C.action.opacity(configuration.isPressed ? 0.16 : 0.08))
                            )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: S.buttonRadius, style: .continuous)
                            .stroke(C.action.opacity(configuration.isPressed ? 0.55 : 0.34), lineWidth: 1.2)
                    )
                    .shadow(color: C.pillShadow, radius: 6, y: 2)
            }
        }
            .focusStroke(radius: S.buttonRadius)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(Motion.easePress, value: configuration.isPressed)
    }
}

/// Makes empty chrome draggable; clicks on controls still work.
struct WindowBackgroundDrag: NSViewRepresentable {
    var appearance: AppearanceChoice = .system

    func makeNSView(context: Context) -> NSView {
        DragNSView()
    }

    /// Runs on every SwiftUI update of the shell, so it only touches the window when something differs:
    /// re-assigning the appearance (a fresh NSAppearance object each time) and the autosave name on
    /// every update made AppKit re-resolve the whole view tree while the user was clicking.
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        DragNSView.configure(window)
        let wanted = appearance.nsAppearance
        if window.appearance?.name != wanted?.name {
            window.appearance = wanted
        }
    }
}

private final class DragNSView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { DragNSView.configure(window) }
    }

    /// Movable background, transparent title bar, frame autosave — plus no tab bar and no full-screen
    /// for this single-window utility (the top strip is just the traffic lights, and the "View" menu,
    /// which would otherwise carry "Enter Full Screen", stays empty). Idempotent and cheap.
    static func configure(_ window: NSWindow) {
        if !window.isMovableByWindowBackground { window.isMovableByWindowBackground = true }
        if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
        if window.frameAutosaveName != "CAM98.Main" { window.setFrameAutosaveName("CAM98.Main") }
        if window.tabbingMode != .disallowed { window.tabbingMode = .disallowed }
        if !window.collectionBehavior.isDisjoint(with: [.fullScreenPrimary, .fullScreenAuxiliary]) {
            window.collectionBehavior.subtract([.fullScreenPrimary, .fullScreenAuxiliary])
        }
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
