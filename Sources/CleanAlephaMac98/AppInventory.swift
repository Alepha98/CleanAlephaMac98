import Foundation

/// Snapshot of installed apps used to decide whether a leftover cache/container/pref folder still
/// has an owner. Reads each app's real `CFBundleIdentifier`, so bundle-id-named folders
/// (`com.spotify.client`) match precisely — replacing the old fuzzy substring match plus a
/// hand-maintained, machine-specific alias table.
struct AppInventory: Sendable {
    /// Normalized display names, e.g. "Visual Studio Code" → "visualstudiocode".
    let names: Set<String>
    /// Lowercased bundle identifiers, e.g. "com.spotify.client".
    let bundleIDs: Set<String>

    static func scan() -> AppInventory {
        let fm = FileManager.default
        var names = Set<String>()
        var ids = Set<String>()
        for root in ["/Applications", NSHomeDirectory() + "/Applications"] {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                names.insert(normalize(String(entry.dropLast(4))))
                let info = URL(fileURLWithPath: root)
                    .appendingPathComponent(entry)
                    .appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOf: info),
                   let id = dict["CFBundleIdentifier"] as? String {
                    ids.insert(id.lowercased())
                }
            }
        }
        return AppInventory(names: names, bundleIDs: ids)
    }

    /// Does `folder` (a `Caches` / `Containers` / `Preferences` / `LaunchAgents` name) belong to an
    /// installed app? Apple and our own folders always count as owned.
    func hasOwner(_ folder: String) -> Bool {
        let lower = folder.lowercased()
        if lower == "apple" || lower.hasPrefix("com.apple") || folder == "CleanAlephaMac98" {
            return true
        }

        if lower.contains(".") {
            // Bundle-id shaped: exact, or a parent/child id (com.google.Chrome.helper ↔ com.google.Chrome).
            if bundleIDs.contains(lower) { return true }
            if bundleIDs.contains(where: { lower.hasPrefix($0 + ".") || $0.hasPrefix(lower + ".") }) {
                return true
            }
            // Fall back to the trailing token vs display names ("com.spotify.client" → "client"/"spotify").
            let tokens = lower.split(separator: ".").map(String.init)
            return tokens.contains { tok in
                let n = Self.normalize(tok)
                return n.count >= 3 && names.contains { $0 == n || $0.contains(n) }
            }
        }

        // Plain display-name folder ("Google", "Cursor", "Code").
        let nf = Self.normalize(folder)
        guard nf.count >= 3 else { return false }
        if names.contains(where: { $0 == nf || $0.contains(nf) || nf.contains($0) }) { return true }
        return bundleIDs.contains { id in
            id.split(separator: ".").contains { Self.normalize(String($0)) == nf }
        }
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }
}
