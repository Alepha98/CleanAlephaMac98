import AppKit
import Foundation

/// Cache files can be safe on disk but unsafe to unlink while their owner is running:
/// an app may later flush stale session state over the surviving files. Refuse those jobs
/// and ask for a retry after the owner has been closed instead of terminating apps silently.
enum SessionGuard {
    private struct Owner {
        let name: String
        let pathMarkers: [String]
        let bundleIDs: Set<String>
        let appNames: Set<String>
    }

    private static let owners: [Owner] = [
        Owner(
            name: "Telegram",
            pathMarkers: ["/telegram desktop/", "ru.keepcoder.telegram", "/telegram/"],
            bundleIDs: ["org.telegram.desktop", "ru.keepcoder.Telegram"],
            appNames: ["telegram", "telegram desktop"]
        ),
        Owner(
            name: "Messages",
            pathMarkers: ["/containers/com.apple.mobilesms/", "/library/messages/"],
            bundleIDs: ["com.apple.MobileSMS"],
            appNames: ["messages", "сообщения"]
        ),
        Owner(
            name: "Safari",
            pathMarkers: ["/com.apple.safari", "/library/safari/"],
            bundleIDs: ["com.apple.Safari"],
            appNames: ["safari"]
        ),
        Owner(
            name: "Google Chrome",
            pathMarkers: ["/google/chrome", "/com.google.chrome"],
            bundleIDs: ["com.google.Chrome", "com.google.Chrome.canary"],
            appNames: ["google chrome", "google chrome canary"]
        ),
        Owner(
            name: "Microsoft Edge",
            pathMarkers: ["/microsoft edge", "/com.microsoft.edgemac"],
            bundleIDs: ["com.microsoft.edgemac", "com.microsoft.edgemac.Dev"],
            appNames: ["microsoft edge"]
        ),
        Owner(
            name: "Brave",
            pathMarkers: ["/bravesoftware/", "/com.brave.browser"],
            bundleIDs: ["com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly"],
            appNames: ["brave browser", "brave"]
        ),
        Owner(
            name: "Firefox",
            pathMarkers: ["/firefox/", "/org.mozilla.firefox"],
            bundleIDs: ["org.mozilla.firefox", "org.mozilla.nightly"],
            appNames: ["firefox", "firefox nightly"]
        ),
        Owner(
            name: "Yandex Browser",
            pathMarkers: ["/yandex/yandexbrowser", "/ru.yandex.desktop.yandex-browser"],
            bundleIDs: ["ru.yandex.desktop.yandex-browser"],
            appNames: ["yandex", "yandex browser"]
        ),
        Owner(
            name: "Claude",
            pathMarkers: ["/.claude/", "/application support/claude/", "/tmp/claude-"],
            bundleIDs: ["com.anthropic.claudefordesktop"],
            appNames: ["claude"]
        ),
        Owner(
            name: "ChatGPT / Codex",
            pathMarkers: ["/.codex/", "/com.openai.chat", "/codex-runtimes/"],
            bundleIDs: ["com.openai.chat", "com.openai.codex"],
            appNames: ["chatgpt", "codex"]
        ),
        Owner(
            name: "Cursor",
            pathMarkers: ["/.cursor/", "/application support/cursor/", "/todesktop.230313mzl4w4u92"],
            bundleIDs: ["com.todesktop.230313mzl4w4u92"],
            appNames: ["cursor"]
        ),
        Owner(
            name: "OpenCode",
            pathMarkers: ["/.local/share/opencode/", "/application support/ai.opencode.desktop/"],
            bundleIDs: ["ai.opencode.desktop"],
            appNames: ["opencode"]
        ),
        Owner(
            name: "Visual Studio Code",
            pathMarkers: ["/application support/code/", "/com.microsoft.vscode"],
            bundleIDs: ["com.microsoft.VSCode"],
            appNames: ["visual studio code", "code"]
        ),
        Owner(
            name: "Discord",
            pathMarkers: ["/application support/discord/", "/com.hnc.discord"],
            bundleIDs: ["com.hnc.Discord"],
            appNames: ["discord"]
        ),
        Owner(
            name: "Slack",
            pathMarkers: ["/application support/slack/", "/com.tinyspeck.slackmacgap"],
            bundleIDs: ["com.tinyspeck.slackmacgap"],
            appNames: ["slack"]
        ),
        Owner(
            name: "Spotify",
            pathMarkers: ["/spotify/", "/com.spotify.client"],
            bundleIDs: ["com.spotify.client"],
            appNames: ["spotify"]
        ),
        Owner(
            name: "Zoom",
            pathMarkers: ["/zoom.us/", "/us.zoom.xos"],
            bundleIDs: ["us.zoom.xos"],
            appNames: ["zoom.us", "zoom"]
        ),
        Owner(
            name: "Figma",
            pathMarkers: ["/application support/figma/"],
            bundleIDs: ["com.figma.Desktop"],
            appNames: ["figma"]
        ),
        Owner(
            name: "Notion",
            pathMarkers: ["/application support/notion/"],
            bundleIDs: ["notion.id"],
            appNames: ["notion"]
        ),
        Owner(
            name: "Obsidian",
            pathMarkers: ["/application support/obsidian/"],
            bundleIDs: ["md.obsidian"],
            appNames: ["obsidian"]
        ),
        Owner(
            name: "Steam",
            pathMarkers: ["/application support/steam/"],
            bundleIDs: ["com.valvesoftware.steam"],
            appNames: ["steam"]
        ),
        Owner(
            name: "CapCut",
            pathMarkers: ["/capcut/"],
            bundleIDs: ["com.lemon.lvoverseas"],
            appNames: ["capcut"]
        ),
        Owner(
            name: "Screenshot / QuickTime",
            pathMarkers: [
                "/group.com.apple.screencapture/", "/library/screenrecordings/",
                "/com.apple.quicktimeplayerx/"
            ],
            bundleIDs: ["com.apple.QuickTimePlayerX", "com.apple.screencaptureui"],
            appNames: ["quicktime player", "screenshot"]
        )
    ]

    private static func owner(for url: URL) -> Owner? {
        let path = url.standardizedFileURL.path.lowercased()
        return owners.first(where: { spec in
            spec.pathMarkers.contains { path.contains($0) }
        })
    }

    static func ownerName(for url: URL) -> String? {
        owner(for: url)?.name
    }

    static func runningOwner(for url: URL) -> String? {
        runningOwner(for: url, running: NSWorkspace.shared.runningApplications.map {
            RunningApp(bundleID: $0.bundleIdentifier, name: $0.localizedName)
        })
    }

    struct RunningApp {
        let bundleID: String?
        let name: String?
    }

    /// Testable core. A curated owner is authoritative: its exact bundle ids / names decide, and the
    /// fuzzy fallbacks below never run for it — they once matched `~/…/Application Support/Cursor`
    /// to Apple's always-on `CursorUIViewService`, so Cursor's caches were refused forever.
    static func runningOwner(for url: URL, running: [RunningApp]) -> String? {
        if let owner = owner(for: url) {
            let isRunning = running.contains { app in
                if let bundle = app.bundleID, owner.bundleIDs.contains(bundle) { return true }
                if let name = app.name?.lowercased(), owner.appNames.contains(name) { return true }
                return false
            }
            return isRunning ? owner.name : nil
        }

        // Generic sandbox/cache fallback: Library/Containers/<bundle-id>/... and
        // Library/Caches/<bundle-id>/... cover apps not present in the curated list.
        let components = url.standardizedFileURL.pathComponents
        for marker in ["Containers", "Caches"] {
            guard let index = components.lastIndex(of: marker), index + 1 < components.count else { continue }
            let candidate = components[index + 1]
            guard candidate.contains(".") else { continue }
            if let app = running.first(where: { $0.bundleID?.caseInsensitiveCompare(candidate) == .orderedSame }) {
                return app.name ?? candidate
            }
        }

        // Unknown apps under Application Support / Group Containers are discovered by
        // the content-driven scanner. Match their storage owner dynamically so a newly
        // installed app receives the same close-before-clean protection as curated apps.
        for marker in ["Application Support", "Group Containers", "WebKit"] {
            guard let index = components.lastIndex(of: marker), index + 1 < components.count else { continue }
            let candidate = components[index + 1]
            let candidateToken = ownerToken(candidate)
            guard candidateToken.count >= 4 else { continue }
            if let app = running.first(where: { app in
                if let bundle = app.bundleID {
                    let bundleToken = ownerToken(bundle)
                    if bundle.caseInsensitiveCompare(candidate) == .orderedSame
                        || candidate.lowercased().hasSuffix(bundle.lowercased())
                        || (bundleToken.count >= 6 && candidateToken.contains(bundleToken)) {
                        return true
                    }
                }
                guard let name = app.name else { return false }
                let nameToken = ownerToken(name)
                guard nameToken.count >= 4 else { return false }
                if candidateToken == nameToken { return true }
                // Partial name similarity only for third-party apps: macOS runs hundreds of agents
                // and XPC services whose names merely contain a word (CursorUIViewService ⊃ "cursor").
                if app.bundleID?.lowercased().hasPrefix("com.apple.") == true { return false }
                return (nameToken.count >= 6 && candidateToken.contains(nameToken))
                    || (candidateToken.count >= 6 && nameToken.contains(candidateToken))
            }) {
                return app.name ?? app.bundleID ?? candidate
            }
        }

        // The Darwin per-user C/T roots sit outside ~/Library. Their immediate child
        // is commonly a bundle id; keep it untouched while that app is alive.
        if let token = SystemDeepScanner.runtimeOwnerToken(for: url)?.lowercased() {
            if let app = running.first(where: { app in
                guard let bundle = app.bundleID?.lowercased() else { return false }
                return token == bundle
                    || token.hasPrefix(bundle + ".")
                    || token.hasSuffix("." + bundle)
            }) {
                return app.name ?? app.bundleID ?? token
            }
        }
        return nil
    }

    private static func ownerToken(_ value: String) -> String {
        value.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func blockingOwner(for item: JunkItem) -> String? {
        switch item.kind {
        case .wipeChildren, .safariNetworkCache, .deleteItem:
            return runningOwner(for: item.url)
                ?? StorageIntelligenceScanner.blockingProcessName(for: item)
                ?? HiddenTreeScanner.blockingProcessName(for: item)
                ?? SystemDeepScanner.blockingProcessName(for: item)
        case .deleteCaptureRemnants:
            return runningDeclaredOwner(for: item)
                ?? runningOwner(for: item.url)
                ?? HiddenCaptureScanner.blockingProcessName(for: item)
        default:
            return nil
        }
    }

    private static func runningDeclaredOwner(for item: JunkItem) -> String? {
        guard let name = HiddenCaptureScanner.declaredOwnerName(for: item),
              let owner = owners.first(where: { $0.name == name }) else { return nil }
        let running = NSWorkspace.shared.runningApplications
        let isRunning = running.contains { app in
            if let bundle = app.bundleIdentifier, owner.bundleIDs.contains(bundle) { return true }
            if let appName = app.localizedName?.lowercased(), owner.appNames.contains(appName) { return true }
            return false
        }
        return isRunning ? owner.name : nil
    }
}
