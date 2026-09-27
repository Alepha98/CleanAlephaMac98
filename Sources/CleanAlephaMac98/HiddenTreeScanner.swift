import CryptoKit
import Darwin
import Foundation

/// Blind inventory of dot-directories. Discovery deliberately does not start from a
/// catalogue of apps or expected cache paths: every outer hidden tree in the user's
/// working roots and every top-level dot-directory in the home folder is measured.
/// Names are consulted only after discovery, to decide whether a row is read-only or a
/// narrowly revalidated rebuildable cache.
enum HiddenTreeScanner {
    private enum Role: Equatable {
        case rebuildable
        case environment
        case sourceOrDatabase
        case unknown
    }

    private struct TreeStats {
        var files = 0
        var newest = Date.distantPast
        var complete = true
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var workingRoots: [URL] {
        ["Downloads", "Desktop", "Documents", "Projects", "Movies", "Pictures"]
            .map { home.appendingPathComponent($0, isDirectory: true) }
    }

    /// These are build products, never source-of-truth. Even so they remain opt-in.
    private static let rebuildableNames: Set<String> = [
        ".turbo", ".dart_tool", ".cxx", ".next", ".nuxt", ".svelte-kit",
        ".angular", ".parcel-cache", ".vite", ".mypy_cache", ".pytest_cache",
        ".ruff_cache", ".expo", ".gradle", ".build"
    ]

    private static let sourceOrDatabaseNames: Set<String> = [
        ".git", ".svn", ".hg", ".ssh", ".gnupg", ".aws", ".kube",
        ".cursor", ".claude", ".codex", ".idea", ".vscode", ".obsidian"
    ]

    private static let traversalSkipNames: Set<String> = [
        "node_modules", "Pods", "Carthage", "site-packages", "vendor", ".git"
    ]

    private static let sensitiveFragments = [
        "auth", "account", "cookie", "credential", "identity", "keychain",
        "login", "password", "secret", "session", "token", "wallet", "tdata"
    ]

    static func items(
        now: Date = Date(),
        cancellation: ScanCancellation? = nil
    ) -> [JunkItem] {
        let started = Date()
        let discovered = discoverOuterHiddenTrees(cancellation: cancellation)
        guard cancellation?.isCancelled != true else { return [] }
        let sizes = batchAuditBytes(
            discovered.map(\.url),
            timeout: 35,
            cancellation: cancellation
        )
        var rows: [JunkItem] = []
        var fullyInspected = 0

        for candidate in discovered {
            guard cancellation?.isCancelled != true else { return [] }
            let path = candidate.url.standardizedFileURL.path
            let bytes = sizes[path] ?? 0
            let role = role(for: candidate.url, topLevelHome: candidate.topLevelHome)
            let minimum: Int64 = role == .rebuildable ? 16 * 1_048_576 : 64 * 1_048_576
            guard bytes >= minimum else { continue }

            var stats: TreeStats?
            if role == .rebuildable {
                stats = inspectTree(candidate.url, entryLimit: 300_000, cancellation: cancellation)
                if stats?.complete == true { fullyInspected += 1 }
            }
            let ageDays = stats.map { max(0, Int(now.timeIntervalSince($0.newest) / 86_400)) }
            let cleanable = role == .rebuildable
                && stats?.complete == true
                && !Keep.isExtraProtected(candidate.url)
            let kind: CleanKind = cleanable ? .wipeChildren : .advice
            let idPrefix = cleanable ? "hidden-tree-cache-" : "hidden-tree-audit-"
            let filePart = stats.map { " · \($0.files) файлов" } ?? ""
            let agePart = ageDays.map { " · \($0) дн." } ?? ""
            rows.append(JunkItem(
                id: idPrefix + stableKey(path),
                module: .junk,
                title: title(for: role, url: candidate.url),
                subtitle: Line(
                    ru: cleanable
                        ? "Слепой поиск\(filePart)\(agePart) · пересоздаётся · выкл."
                        : "Слепой поиск · содержимое не признано безопасным кэшем · только аудит",
                    en: cleanable
                        ? "Blind discovery\(filePart)\(agePart) · rebuilds · off"
                        : "Blind discovery · contents not proven disposable · audit only"
                ),
                url: candidate.url,
                bytes: bytes,
                selected: false,
                kind: kind,
                keepsLogins: true
            ))
        }

        CamLog.line(
            "hidden tree scan discovered=\(discovered.count) measured=\(sizes.count) "
                + "inspected=\(fullyInspected) rows=\(rows.count) "
                + "ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        )
        return nonOverlapping(rows.sorted { $0.bytes > $1.bytes }, limit: 80)
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        let path = item.url.standardizedFileURL.path
        guard item.module == .junk || item.module == .deepSearch, isInAuditScope(item.url), isDotDirectory(item.url),
              isDirectoryWithoutSymlink(item.url) else { return false }
        if item.id == "hidden-tree-audit-\(stableKey(path))" {
            return item.kind == .advice
        }
        if item.id == "hidden-tree-cache-\(stableKey(path))" {
            return item.kind == .wipeChildren
                && role(for: item.url, topLevelHome: isTopLevelHomeHidden(item.url)) == .rebuildable
        }
        return false
    }

    static func isSafeDeletionCandidate(_ item: JunkItem) -> Bool {
        guard isExplicitCard(item), item.id.hasPrefix("hidden-tree-cache-"),
              item.kind == .wipeChildren, !Keep.isExtraProtected(item.url),
              !isTopLevelHomeHidden(item.url),
              role(for: item.url, topLevelHome: false) == .rebuildable,
              let stats = inspectTree(item.url, entryLimit: 300_000), stats.complete else {
            return false
        }
        return stats.files > 0
    }

    static func blockingProcessName(for item: JunkItem) -> String? {
        guard isExplicitCard(item), item.id.hasPrefix("hidden-tree-cache-") else { return nil }
        let ran = CamProcess.run(
            path: "/usr/sbin/lsof",
            arguments: ["+D", item.url.path, "-Fpc", "-nP"],
            timeout: 3
        )
        if ran.timedOut { return "active process" }
        var pid: String?
        for line in ran.out.split(whereSeparator: \.isNewline) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            if marker == "p" {
                pid = value
            } else if marker == "c", pid != String(getpid()) {
                let lower = value.lowercased()
                if lower != "lsof" && !lower.contains("cleanal") {
                    return value.isEmpty ? "active process" : value
                }
            }
        }
        return nil
    }

    // MARK: - Blind discovery

    private static func discoverOuterHiddenTrees(
        cancellation: ScanCancellation? = nil
    ) -> [(url: URL, topLevelHome: Bool)] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        var found: [(URL, Bool)] = []

        if let homeChildren = try? fm.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) {
            for url in homeChildren where isDotDirectory(url) {
                if cancellation?.isCancelled == true { return found }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isDirectory == true, values.isSymbolicLink != true else { continue }
                found.append((url, true))
            }
        }

        for root in workingRoots where fm.fileExists(atPath: root.path) {
            if cancellation?.isCancelled == true { break }
            var failures = 0
            guard let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsPackageDescendants],
                errorHandler: { _, _ in
                    failures += 1
                    return true
                }
            ) else { continue }
            var visited = 0
            for case let url as URL in enumerator {
                if cancellation?.isCancelled == true { return found }
                visited += 1
                if visited > 240_000 { break }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isDirectory == true else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                let name = url.lastPathComponent
                if traversalSkipNames.contains(name) {
                    if name.hasPrefix(".") { found.append((url, false)) }
                    enumerator.skipDescendants()
                    continue
                }
                if name.hasPrefix("."), name != ".", name != ".." {
                    found.append((url, false))
                    enumerator.skipDescendants()
                }
            }
            if failures > 0 {
                CamLog.line("hidden tree partial root=\(PathFormat.tilde(root)) denied=\(failures)")
            }
        }

        var seen = Set<String>()
        return found.filter { candidate in
            let path = candidate.0.standardizedFileURL.path
            if seen.contains(path) { return false }
            seen.insert(path)
            return true
        }.map { (url: $0.0, topLevelHome: $0.1) }
    }

    /// `du` is invoked without Keep filtering because audit-only rows must include protected
    /// stores such as .git, .gradle, .codex, and VM roots. This function never deletes.
    private static func batchAuditBytes(
        _ urls: [URL],
        timeout: TimeInterval,
        cancellation: ScanCancellation? = nil
    ) -> [String: Int64] {
        guard !urls.isEmpty else { return [:] }
        let ran = CamProcess.run(
            path: "/usr/bin/du",
            arguments: ["-sk"] + urls.map { $0.standardizedFileURL.path },
            timeout: timeout,
            cancellation: cancellation
        )
        var result: [String: Int64] = [:]
        for line in ran.out.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: true)
            guard fields.count == 2,
                  let kb = Int64(fields[0].trimmingCharacters(in: .whitespaces)) else { continue }
            result[String(fields[1])] = kb * 1024
        }
        if ran.timedOut {
            CamLog.line("hidden tree size pass timed out partial=\(result.count)/\(urls.count)")
        }
        return result
    }

    // MARK: - Revalidation and semantics

    private static func inspectTree(
        _ root: URL,
        entryLimit: Int,
        cancellation: ScanCancellation? = nil
    ) -> TreeStats? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .contentModificationDateKey
        ]
        guard isDirectoryWithoutSymlink(root), !pathContainsSensitiveName(root) else { return nil }
        var stats = TreeStats()
        var traversalFailed = false
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in
                traversalFailed = true
                return false
            }
        ) else { return nil }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        for case let child as URL in enumerator {
            if cancellation?.isCancelled == true { return nil }
            if stats.files > entryLimit || Keep.isExtraProtected(child) || pathContainsSensitiveName(child) {
                return nil
            }
            guard let values = try? child.resourceValues(forKeys: keys) else { return nil }
            if values.isSymbolicLink == true {
                let target = child.standardizedFileURL.resolvingSymlinksInPath().path
                if target != canonicalRoot && !target.hasPrefix(canonicalRoot + "/") { return nil }
                enumerator.skipDescendants()
                continue
            }
            guard values.isDirectory == true || values.isRegularFile == true else { return nil }
            if values.isRegularFile == true {
                stats.files += 1
                stats.newest = max(stats.newest, values.contentModificationDate ?? .distantPast)
            }
        }
        stats.complete = !traversalFailed
        return stats
    }

    private static func role(for url: URL, topLevelHome: Bool) -> Role {
        let name = url.lastPathComponent.lowercased()
        if topLevelHome { return sourceOrDatabaseNames.contains(name) ? .sourceOrDatabase : .unknown }
        if rebuildableNames.contains(name) { return .rebuildable }
        if name.hasPrefix(".venv") || name.hasPrefix(".tools-venv")
            || name == ".terraform" || name == ".local" {
            return .environment
        }
        if sourceOrDatabaseNames.contains(name) || name.hasPrefix(".pg") || name.hasPrefix(".env") {
            return .sourceOrDatabase
        }
        return .unknown
    }

    private static func title(for role: Role, url: URL) -> Line {
        let name = url.lastPathComponent
        switch role {
        case .rebuildable:
            return Line(ru: "Скрытый build-кэш · \(name)", en: "Hidden build cache · \(name)")
        case .environment:
            return Line(ru: "Скрытое окружение · \(name)", en: "Hidden environment · \(name)")
        case .sourceOrDatabase:
            return Line(ru: "Скрытые данные · \(name)", en: "Hidden data · \(name)")
        case .unknown:
            return Line(ru: "Неизвестное скрытое дерево · \(name)", en: "Unknown hidden tree · \(name)")
        }
    }

    private static func pathContainsSensitiveName(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { component in
            let lower = component.lowercased()
            return sensitiveFragments.contains { lower.contains($0) }
        }
    }

    private static func isDotDirectory(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix(".") && name != "." && name != ".."
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func isTopLevelHomeHidden(_ url: URL) -> Bool {
        url.standardizedFileURL.deletingLastPathComponent().path == home.standardizedFileURL.path
            && isDotDirectory(url)
    }

    private static func isInAuditScope(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if isTopLevelHomeHidden(url) { return true }
        return workingRoots.contains { root in
            let rootPath = root.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/")
        }
    }

    private static func nonOverlapping(_ rows: [JunkItem], limit: Int) -> [JunkItem] {
        var result: [JunkItem] = []
        for row in rows {
            let path = row.url.standardizedFileURL.path
            let overlaps = result.contains { other in
                let otherPath = other.url.standardizedFileURL.path
                return path == otherPath || path.hasPrefix(otherPath + "/") || otherPath.hasPrefix(path + "/")
            }
            if !overlaps { result.append(row) }
            if result.count >= limit { break }
        }
        return result
    }

    private static func stableKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - QA hooks

    static func isRebuildableNameForQA(_ value: String, topLevelHome: Bool = false) -> Bool {
        role(for: URL(fileURLWithPath: "/tmp/\(value)"), topLevelHome: topLevelHome) == .rebuildable
    }

    static func isSensitiveNameForQA(_ value: String) -> Bool {
        let lower = value.lowercased()
        return sensitiveFragments.contains { lower.contains($0) }
    }
}
