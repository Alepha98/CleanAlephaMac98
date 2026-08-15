import AppKit
import SwiftUI

extension Notification.Name {
    static let cam98Scan = Notification.Name("cam98.scan")
    static let cam98Clean = Notification.Name("cam98.clean")
    static let cam98Safe = Notification.Name("cam98.safe")
    static let cam98Cancel = Notification.Name("cam98.cancel")
    static let cam98Clear = Notification.Name("cam98.clear")
    static let cam98Keys = Notification.Name("cam98.keys")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.cancelWork()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct CleanAlephaMac98App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState()

    init() {
        if CommandLine.arguments.contains("--auto") {
            AutoClean.runAndExit()
        }
    }

    var body: some Scene {
        let _ = state.canScan
        let _ = state.canClean
        let _ = state.canSelectSafe
        let _ = state.canDeselect
        let _ = state.canCancel
        let _ = state.appearance
        let _ = state.language
        let lang = state.copyLang
        WindowGroup("CleanAlephaMac98") {
            ShellView()
                .environment(state)
                .frame(minWidth: 860, minHeight: 560)
                .onAppear {
                    delegate.state = state
                    state.applyAppearance()
                    state.refreshFDA()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        .defaultPosition(.center)
        .windowResizability(.automatic)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(Copy.aboutApp.t(lang)) { showAbout(lang) }
            }
            CommandGroup(replacing: .newItem) {}
            CommandMenu(Copy.cleanMenu.t(lang)) {
                Button(Copy.scan.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Scan, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!state.canScan)
                Button(Copy.clean.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Clean, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.canClean)
                Button(Copy.safe.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Safe, object: nil)
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(!state.canSelectSafe)
                Button(Copy.deselect.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Clear, object: nil)
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(!state.canDeselect)
                Divider()
                Button(Copy.stop.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Cancel, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!state.canCancel)
            }
            CommandGroup(replacing: .help) {
                Button(Copy.shortcuts.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Keys, object: nil)
                }
            }
            CommandMenu(Copy.appearanceMenu.t(lang)) {
                Picker(Copy.appearanceMenu.t(lang), selection: Binding(
                    get: { state.appearance },
                    set: { state.appearance = $0 }
                )) {
                    ForEach(AppearanceChoice.allCases) { choice in
                        Text(choice.title(lang)).tag(choice)
                    }
                }
                .pickerStyle(.inline)
            }
            CommandMenu(Copy.languageMenu.t(lang)) {
                Picker(Copy.languageMenu.t(lang), selection: Binding(
                    get: { state.language },
                    set: { state.language = $0 }
                )) {
                    ForEach(LanguageChoice.allCases) { choice in
                        Text(choice.title(lang)).tag(choice)
                    }
                }
                .pickerStyle(.inline)
            }
        }
    }

    private func showAbout(_ lang: CopyLang) {
        let credits = NSAttributedString(
            string: Copy.aboutCredits.t(lang),
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.labelColor
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "CleanAlephaMac98",
            .credits: credits
        ])
    }
}
