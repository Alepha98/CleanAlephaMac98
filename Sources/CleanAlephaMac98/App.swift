import AppKit
import SwiftUI

extension Notification.Name {
    static let cam98Scan = Notification.Name("cam98.scan")
    static let cam98Clean = Notification.Name("cam98.clean")
    static let cam98Safe = Notification.Name("cam98.safe")
    static let cam98Cancel = Notification.Name("cam98.cancel")
    static let cam98Clear = Notification.Name("cam98.clear")
    static let cam98Keys = Notification.Name("cam98.keys")
    static let cam98Go = Notification.Name("cam98.go")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var state: AppState?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // `open -n` during installs spawned 3 copies, each burning ~30% CPU on the orb.
        let id = Bundle.main.bundleIdentifier ?? "com.alepha98.CleanAlephaMac98"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { $0 != NSRunningApplication.current }
        guard let existing = others.first else { return }
        existing.activate()
        NSApp.terminate(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        state?.cancelWork()
        return .terminateNow
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
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
        if CommandLine.arguments.contains("--qa-pulse") {
            QAHarness.pulse()
        }
        if CommandLine.arguments.contains("--qa-protect") {
            QAHarness.protect()
        }
        if CommandLine.arguments.contains("--qa-startup") {
            QAHarness.startup()
        }
        if CommandLine.arguments.contains("--qa-keep") {
            QAHarness.keep()
        }
        if CommandLine.arguments.contains("--qa-smart") {
            QAHarness.smart()
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
                    if let i = CommandLine.arguments.firstIndex(of: "--module"),
                       i + 1 < CommandLine.arguments.count,
                       let m = Module(rawValue: CommandLine.arguments[i + 1]) {
                        state.module = m
                    }
                    if CommandLine.arguments.contains("--auto-scan") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
                            state.requestScan()
                        }
                    }
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
            CommandGroup(replacing: .newItem) {
                Button(Copy.scan.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Scan, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(!state.canScan)
            }
            CommandMenu(Copy.menuFile.t(lang)) {
                Button(Copy.scan.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Scan, object: nil)
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!state.canScan)
                Button(Copy.scanAgain.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Scan, object: nil)
                }
                .disabled(state.isBusy)
                Divider()
                Button(Copy.close.t(lang)) {
                    NSApp.keyWindow?.close()
                }
                .keyboardShortcut("w", modifiers: .command)
            }
            CommandMenu(Copy.menuEdit.t(lang)) {
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
            }
            CommandMenu(Copy.cleanMenu.t(lang)) {
                Button(Copy.scan.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Scan, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!state.canScan)
                Button(Copy.clean.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Clean, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!state.canClean)
                Divider()
                Button(Copy.stop.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Cancel, object: nil)
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!state.canCancel)
            }
            CommandMenu(Copy.menuSections.t(lang)) {
                Button(Copy.moduleSmart.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.smart.rawValue)
                }
                .keyboardShortcut("1", modifiers: .command)
                Button(Copy.moduleJunk.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.junk.rawValue)
                }
                .keyboardShortcut("2", modifiers: .command)
                Button(Copy.moduleMail.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.mail.rawValue)
                }
                .keyboardShortcut("3", modifiers: .command)
                Button(Copy.moduleTrash.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.trash.rawValue)
                }
                .keyboardShortcut("4", modifiers: .command)
                Button(Copy.moduleLeftovers.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.leftovers.rawValue)
                }
                .keyboardShortcut("5", modifiers: .command)
                Button(Copy.moduleLarge.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.large.rawValue)
                }
                .keyboardShortcut("6", modifiers: .command)
                Button(Copy.moduleDuplicates.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.duplicates.rawValue)
                }
                .keyboardShortcut("d", modifiers: .command)
                Button(Copy.moduleBrowsers.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.browsers.rawValue)
                }
                .keyboardShortcut("7", modifiers: .command)
                Button(Copy.moduleDev.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.dev.rawValue)
                }
                .keyboardShortcut("8", modifiers: .command)
                Button(Copy.moduleMessengers.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.messengers.rawValue)
                }
                .keyboardShortcut("9", modifiers: .command)
                Divider()
                Button(Copy.modulePulse.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.pulse.rawValue)
                }
                .keyboardShortcut("b", modifiers: .command)
                Button(Copy.moduleProtect.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.protect.rawValue)
                }
                .keyboardShortcut("k", modifiers: .command)
                Button(Copy.moduleStartup.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.startup.rawValue)
                }
                .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button(Copy.moduleSpace.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.space.rawValue)
                }
                .keyboardShortcut("0", modifiers: .command)
                Button(Copy.moduleTools.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Go, object: Module.tools.rawValue)
                }
                .keyboardShortcut("-", modifiers: .command)
            }
            CommandMenu(Copy.appearanceMenu.t(lang)) {
                Picker(Copy.appearanceMenu.t(lang), selection: Binding(
                    get: { state.appearance },
                    set: { state.chooseAppearance($0) }
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
            CommandGroup(replacing: .help) {
                Button(Copy.shortcuts.t(lang)) {
                    NotificationCenter.default.post(name: .cam98Keys, object: nil)
                }
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
