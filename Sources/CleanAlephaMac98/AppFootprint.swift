import Foundation

/// The on-disk *footprint* of a macOS app — the residue a real "uninstaller" removes when you drag an
/// app to the Trash: caches, application support, containers, group containers, preferences, saved
/// state, logs, cookies, HTTP storage, WebKit data, launch agents. Keyed by `CFBundleIdentifier` and
/// display name, the way competitors (CleanMyMac's uninstaller / leftover scan) attribute residue.
///
/// Two entry points share one location catalog:
///  - `footprint(bundleID:name:home:)` returns every existing residue path a *specific* app left
///    behind. It deletes nothing — it hands back URLs for a confirm step, so it is the primitive a
///    future "pick an app → uninstall it and everything it scattered" screen drives.
///  - `orphans(inventory:home:config:)` sweeps the residue locations the rest of the scanner does
///    **not** already owner-filter — `Library/Cookies` and per-app `Library/Logs` — for entries whose
///    owning app is no longer installed, and surfaces them as off-by-default `.leftovers` cards so the
///    footprint coverage is complete. (Caches / Containers / Preferences / LaunchAgents orphans and
///    the HTTPStorages / WebKit / Saved-State piles are already carded elsewhere; this fills the gaps
///    without double-listing.)
///
/// Both are parameterized on `home` + `AppInventory`, so they are unit-testable against a temp tree —
/// unlike the ad-hoc `~/Library`-reading passes they complement.
enum AppFootprint {
    struct Config: Sendable {
        /// A residue *directory* (per-app Logs) worth surfacing.
        var minDirBytes: Int64 = 2_097_152      // 2 MB
        /// A residue *file* (a `.binarycookies` jar) worth surfacing.
        var minFileBytes: Int64 = 16_384         // 16 KB
        var maxItems: Int = 120
    }

    /// Shape of the residue inside a location directory.
    enum Shape: Sendable, Equatable {
        /// Each child directory is one app's residue: `Caches/<id>/`, `Containers/<id>/`, `Logs/<name>/`.
        case childDirectories
        /// Each matching file is one app's residue: `Preferences/<id>.plist`, `Cookies/<id>.binarycookies`.
        case files(suffix: String)
        /// Each matching directory is one app's residue: `Saved Application State/<id>.savedState/`.
        case suffixedDirectories(suffix: String)
    }

    struct Location: Sendable, Equatable {
        let rel: String
        let shape: Shape
    }

    /// Every place an app scatters residue — the complete footprint the uninstaller primitive walks.
    static let locations: [Location] = [
        Location(rel: "Library/Caches", shape: .childDirectories),
        Location(rel: "Library/Application Support", shape: .childDirectories),
        Location(rel: "Library/Containers", shape: .childDirectories),
        Location(rel: "Library/Group Containers", shape: .childDirectories),
        Location(rel: "Library/HTTPStorages", shape: .childDirectories),
        Location(rel: "Library/WebKit", shape: .childDirectories),
        Location(rel: "Library/Logs", shape: .childDirectories),
        Location(rel: "Library/Preferences", shape: .files(suffix: ".plist")),
        Location(rel: "Library/Cookies", shape: .files(suffix: ".binarycookies")),
        Location(rel: "Library/LaunchAgents", shape: .files(suffix: ".plist")),
        Location(rel: "Library/Saved Application State", shape: .suffixedDirectories(suffix: ".savedState"))
    ]

    // MARK: - Uninstaller primitive

    /// One installed app, enough to attribute its residue.
    struct InstalledApp: Sendable, Equatable {
        let name: String        // display name, e.g. "Spotify"
        let bundleID: String    // CFBundleIdentifier, e.g. "com.spotify.client"
        let url: URL            // the .app bundle
    }

    /// Installed apps under `/Applications` and `~/Applications`, with their bundle ids.
    static func installedApps(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [InstalledApp] {
        let fm = FileManager.default
        var out: [InstalledApp] = []
        for root in ["/Applications", home.appendingPathComponent("Applications").path] {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let appURL = URL(fileURLWithPath: root).appendingPathComponent(entry)
                let info = appURL.appendingPathComponent("Contents/Info.plist")
                let bundleID = (NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String) ?? ""
                out.append(InstalledApp(name: String(entry.dropLast(4)), bundleID: bundleID, url: appURL))
            }
        }
        return out
    }

    /// Every existing residue path belonging to the app with this bundle id / display name. Deletes
    /// nothing — returns URLs for a confirm step. Skips `Keep`-protected paths.
    static func footprint(
        bundleID: String,
        name: String,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var seen = Set<String>()
        for loc in locations {
            let root = home.appendingPathComponent(loc.rel)
            guard let kids = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: []
            ) else { continue }
            for url in kids {
                guard let stem = stem(of: url.lastPathComponent, in: loc.shape) else { continue }
                guard belongs(stem: stem, bundleID: bundleID, name: name) else { continue }
                if Keep.isProtected(url) { continue }
                if seen.insert(url.standardizedFileURL.path).inserted { out.append(url) }
            }
        }
        return out
    }

    /// Precise per-app ownership test for a residue entry stem (a folder name or a file stem). Kept
    /// deliberately conservative: it under-matches rather than over-matches, so the uninstaller never
    /// sweeps a path it cannot confidently attribute to the chosen app.
    static func belongs(stem: String, bundleID: String, name: String) -> Bool {
        let s = stem.lowercased()
        let bid = bundleID.lowercased()
        if !bid.isEmpty {
            // Exact, or a parent/child id (com.google.Chrome ↔ com.google.Chrome.helper).
            if s == bid || s.hasPrefix(bid + ".") || bid.hasPrefix(s + ".") { return true }
        }
        let nn = AppInventory.normalize(name)
        guard nn.count >= 3 else { return false }
        if AppInventory.normalize(s) == nn { return true }
        // A dotted / team-prefixed id whose own token equals the app name ("UBF8T346G9.Spotify").
        return s.split(separator: ".").contains { AppInventory.normalize(String($0)) == nn }
    }

    // MARK: - Orphan leftovers (Cookies + per-app Logs)

    private static let orphanLocations: [Location] = [
        Location(rel: "Library/Cookies", shape: .files(suffix: ".binarycookies")),
        Location(rel: "Library/Logs", shape: .childDirectories)
    ]

    /// Non-app entries under `~/Library/Logs` that must never be attributed to a missing app.
    private static let logsDenylist: Set<String> = [
        "DiagnosticReports", "DoNotDisturb", "CoreDuet", "Homebrew",
        "Bluetooth", "SoftwareUpdate", "MobileSync", "Screen Sharing"
    ]

    /// Residue of *removed* apps in the locations no other pass owner-filters. Off by default, review.
    static func orphans(
        inventory: AppInventory,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        config: Config = Config()
    ) -> [JunkItem] {
        let fm = FileManager.default
        var out: [JunkItem] = []
        var n = 0
        for loc in orphanLocations {
            let root = home.appendingPathComponent(loc.rel)
            guard let kids = try? fm.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.fileSizeKey], options: []
            ) else { continue }
            let isCookies = loc.rel.hasSuffix("Cookies")
            for url in kids {
                ScanThrottle.tickSync(every: 40, counter: &n)
                let entry = url.lastPathComponent
                if entry.hasPrefix(".") { continue }
                if entry.lowercased().hasPrefix("com.apple") { continue }
                if !isCookies, logsDenylist.contains(entry) { continue }
                guard let stem = stem(of: entry, in: loc.shape) else { continue }
                if inventory.hasOwner(stem) { continue }
                if Keep.isProtected(url) { continue }

                let bytes: Int64
                if isCookies {
                    bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                    guard bytes >= config.minFileBytes else { continue }
                } else {
                    bytes = DiskSizer.bytes(at: url)
                    guard bytes >= config.minDirBytes else { continue }
                }

                let title = isCookies
                    ? Line(ru: "Cookies · \(short(stem))", en: "Cookies · \(short(stem))")
                    : Line(ru: "Логи · \(short(stem))", en: "Logs · \(short(stem))")
                out.append(JunkItem(
                    id: "left-\(isCookies ? "cookies" : "logs")-\(StableID.of(url.standardizedFileURL.path))",
                    module: .leftovers,
                    title: title,
                    subtitle: Copy.leftoverGone,
                    url: url,
                    bytes: bytes,
                    selected: false,
                    kind: isCookies ? .deleteItem : .wipeChildren,
                    keepsLogins: false
                ))
            }
        }
        return Array(out.sorted { $0.bytes > $1.bytes }.prefix(config.maxItems))
    }

    // MARK: - Helpers

    /// The identifying stem of an entry for a given location shape, or `nil` if it does not match.
    private static func stem(of entry: String, in shape: Shape) -> String? {
        switch shape {
        case .childDirectories:
            return entry
        case .files(let suffix), .suffixedDirectories(let suffix):
            guard entry.hasSuffix(suffix) else { return nil }
            return String(entry.dropLast(suffix.count))
        }
    }

    private static func short(_ id: String) -> String {
        id.count <= 32 ? id : "…" + String(id.suffix(28))
    }
}
