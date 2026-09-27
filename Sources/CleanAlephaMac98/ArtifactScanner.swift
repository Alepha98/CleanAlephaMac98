import Darwin
import Foundation

/// Conservative finds outside classic app caches: old screenshots, downloaded AI outputs,
/// incomplete downloads, and stale local output folders created by Claude / ChatGPT / Codex.
/// User-authored files are always opt-in; only reproducible caches are selected by default.
enum ArtifactScanner {
    enum Match: Equatable, Sendable {
        case screenshot
        case aiOutput
        case genericOutput
        case incompleteDownload

        var minimumAgeDays: Int {
            switch self {
            case .incompleteDownload: 2
            case .screenshot, .aiOutput: 14
            case .genericOutput: 30
            }
        }
    }

    private static let artifactExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "gif", "avif", "heic", "tiff",
        "mp4", "mov", "webm", "m4v",
        "pdf", "docx", "pptx", "xlsx", "csv", "txt", "md", "json",
        "zip", "rar", "7z"
    ]

    private static let screenshotPrefixes = [
        "screenshot", "screen shot", "screen recording",
        "снимок экрана", "запись экрана",
        "знімок екрана", "запис екрана",
        "cleanshot"
    ]

    private static let aiNameMarkers = [
        "chatgpt", "chat gpt", "dall e", "dalle", "openai", "claude",
        "sora", "midjourney", "gemini", "copilot", "perplexity", "grok",
        "runway", "ideogram", "leonardo ai", "stable diffusion", "firefly",
        "generated image"
    ]

    private static let aiOriginMarkers = [
        "chatgpt.com", "chat.openai.com", "openai.com", "oaiusercontent.com",
        "oaistatic.com", "claude.ai", "anthropic.com", "gemini.google.com",
        "copilot.microsoft.com", "perplexity.ai", "grok.com", "x.ai",
        "midjourney.com", "runwayml.com", "ideogram.ai", "leonardo.ai",
        "firefly.adobe.com", "huggingface.co"
    ]

    private static let genericOutputPrefixes = [
        "output", "result", "export", "generated", "untitled", "download"
    ]

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    static func items(now: Date = Date()) -> [JunkItem] {
        let started = Date()
        var rows = cacheItems()
        let afterCaches = Date()
        rows.append(contentsOf: userFiles(now: now))
        let afterFiles = Date()
        rows.append(contentsOf: staleLocalAIItems(now: now))
        CamLog.line(
            "artifact scan caches=\(Int(afterCaches.timeIntervalSince(started) * 1000))ms "
                + "files=\(Int(afterFiles.timeIntervalSince(afterCaches) * 1000))ms "
                + "local=\(Int(Date().timeIntervalSince(afterFiles) * 1000))ms rows=\(rows.count)"
        )
        return dedupe(rows).sorted { lhs, rhs in
            if lhs.selected != rhs.selected { return lhs.selected && !rhs.selected }
            return lhs.bytes > rhs.bytes
        }
    }

    static func isSafePresetCard(_ item: JunkItem) -> Bool {
        guard item.id.hasPrefix("artifact-file-"), item.kind == .deleteItem else { return false }
        let lower = item.url.lastPathComponent.lowercased()
        return lower.hasSuffix(".crdownload")
            || lower.hasSuffix(".download")
            || lower.hasSuffix(".part")
            || lower.hasSuffix(".partial")
            || lower.hasSuffix(".aria2")
            || lower.hasSuffix(".opdownload")
    }

    // MARK: - Old screenshots and downloaded outputs

    static func classify(
        name: String,
        modified: Date,
        origins: [String],
        isDownloads: Bool,
        now: Date = Date()
    ) -> Match? {
        let age = now.timeIntervalSince(modified)
        guard age >= 0 else { return nil }
        let lower = normalized(name)
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()

        if ["crdownload", "part", "partial", "download", "aria2", "opdownload", "filepart"].contains(ext),
           age >= days(2) {
            return .incompleteDownload
        }

        guard artifactExtensions.contains(ext) else { return nil }
        if screenshotPrefixes.contains(where: { lower.hasPrefix($0) }), age >= days(14) {
            return .screenshot
        }

        let isAIOrigin = origins.contains { origin in
            let value = origin.lowercased()
            return aiOriginMarkers.contains { value.contains($0) }
        }
        let stem = normalized(URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent)
        let isAIName = aiNameMarkers.contains { containsPhrase(stem, phrase: $0) }
        if (isAIOrigin || isAIName), age >= days(14) {
            return .aiOutput
        }

        if isDownloads,
           genericOutputPrefixes.contains(where: { hasFilenamePrefix(stem, prefix: $0) }),
           age >= days(30) {
            return .genericOutput
        }
        return nil
    }

    private static func userFiles(now: Date) -> [JunkItem] {
        let roots = [
            (home.appendingPathComponent("Desktop"), false),
            (home.appendingPathComponent("Downloads"), true),
            (home.appendingPathComponent("Pictures"), false),
            (home.appendingPathComponent("Desktop/Screenshots"), false),
            (home.appendingPathComponent("Desktop/Снимки экрана"), false),
            (home.appendingPathComponent("Pictures/Screenshots"), false),
            (home.appendingPathComponent("Pictures/Снимки экрана"), false)
        ]
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
            .contentModificationDateKey
        ]
        var rows: [JunkItem] = []

        for (root, isDownloads) in roots {
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { continue }
            for url in children {
                if Keep.isProtected(url) { continue }
                guard let values = try? url.resourceValues(forKeys: keys),
                      values.isSymbolicLink != true else { continue }
                let ext = url.pathExtension.lowercased()
                let isIncompleteDirectory = values.isDirectory == true && ext == "download"
                guard values.isRegularFile == true || isIncompleteDirectory else { continue }
                let modified = values.contentModificationDate ?? .distantPast
                let origins = downloadOrigins(of: url)
                guard let match = classify(
                    name: url.lastPathComponent,
                    modified: modified,
                    origins: origins,
                    isDownloads: isDownloads,
                    now: now
                ) else { continue }
                let bytes = values.isRegularFile == true
                    ? Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
                    : DiskSizer.bytes(at: url)
                guard bytes > 16_384 else { continue }
                let ageDays = max(0, Int(now.timeIntervalSince(modified) / 86_400))
                rows.append(JunkItem(
                    id: "artifact-file-\(stableKey(url.standardizedFileURL.path))",
                    module: .junk,
                    title: Line.proper(url.lastPathComponent),
                    subtitle: subtitle(for: match, ageDays: ageDays, parent: root),
                    url: url,
                    bytes: bytes,
                    selected: match == .incompleteDownload,
                    kind: .deleteItem,
                    keepsLogins: false
                ))
            }
        }
        return Array(rows.sorted { $0.bytes > $1.bytes }.prefix(80))
    }

    private static func subtitle(for match: Match, ageDays: Int, parent: URL) -> Line {
        let location = PathFormat.tilde(parent)
        switch match {
        case .screenshot:
            return Line(
                ru: "Старый скриншот · \(ageDays) дн. · \(location) · выкл.",
                en: "Old screenshot · \(ageDays)d · \(location) · off"
            )
        case .aiOutput:
            return Line(
                ru: "Старый AI-результат · \(ageDays) дн. · \(location) · выкл.",
                en: "Old AI output · \(ageDays)d · \(location) · off"
            )
        case .genericOutput:
            return Line(
                ru: "Старый output/export · \(ageDays) дн. · \(location) · выкл.",
                en: "Old output/export · \(ageDays)d · \(location) · off"
            )
        case .incompleteDownload:
            return Line(
                ru: "Незавершённая загрузка · \(ageDays) дн.",
                en: "Incomplete download · \(ageDays)d"
            )
        }
    }

    // MARK: - Rebuildable AI app caches

    private static func cacheItems() -> [JunkItem] {
        let fixed: [(String, String, Line)] = [
            ("claude-gpu", "Library/Application Support/Claude/GPUCache", Line(ru: "GPU-кэш Claude", en: "Claude GPU cache")),
            ("claude-dawn", "Library/Application Support/Claude/DawnGraphiteCache", Line(ru: "Графический кэш Claude", en: "Claude graphics cache")),
            ("claude-webgpu", "Library/Application Support/Claude/DawnWebGPUCache", Line(ru: "WebGPU-кэш Claude", en: "Claude WebGPU cache")),
            ("claude-crashpad", "Library/Application Support/Claude/Crashpad", Line(ru: "Отчёты падений Claude", en: "Claude crash reports")),
            ("claude-cli-cache", ".claude/cache", Line(ru: "Кэш Claude Code", en: "Claude Code cache")),
            ("claude-telemetry", ".claude/telemetry", Line(ru: "Локальные логи Claude Code", en: "Claude Code local logs")),
            ("codex-cache", ".codex/cache", Line(ru: "Кэш ChatGPT / Codex", en: "ChatGPT / Codex cache")),
            ("chatgpt-cache", "Library/Caches/com.openai.chat", Line(ru: "Кэш ChatGPT", en: "ChatGPT cache")),
            ("chatgpt-cache-legacy", "Library/Caches/com.openai.ChatGPT", Line(ru: "Кэш ChatGPT", en: "ChatGPT cache"))
        ]
        return fixed.compactMap { id, relative, title in
            let url = home.appendingPathComponent(relative)
            if Keep.isProtected(url) { return nil }
            let bytes = DiskSizer.bytes(at: url)
            guard bytes > 16_384 else { return nil }
            return JunkItem(
                id: "artifact-cache-\(id)",
                module: .junk,
                title: title,
                subtitle: Line(ru: "Пересоздаётся · чаты и проекты целы", en: "Rebuilds · chats and projects stay"),
                url: url,
                bytes: bytes,
                selected: true,
                kind: .wipeChildren,
                keepsLogins: true
            )
        }
    }

    // MARK: - Stale local Claude / ChatGPT / Codex outputs

    private static func staleLocalAIItems(now: Date) -> [JunkItem] {
        var candidates: [(URL, String, String)] = []

        let claudeProjects = home.appendingPathComponent(".claude/projects")
        candidates += matchingDirectories(at: claudeProjects, maxDepth: 4) {
            $0.lastPathComponent == "tool-results"
        }.map { ($0, "Claude Code tool-results", "Claude Code tool-results") }

        let claudeLocal = home.appendingPathComponent("Library/Application Support/Claude/local-agent-mode-sessions")
        candidates += matchingDirectories(at: claudeLocal, maxDepth: 4) {
            $0.lastPathComponent.hasPrefix("local_")
        }.map { ($0, "Локальный output Claude", "Claude local output") }

        candidates += topLevelEntries(at: home.appendingPathComponent(".claude/downloads"))
            .map { ($0, "Загрузка Claude", "Claude download") }
        candidates += topLevelEntries(at: home.appendingPathComponent(".codex/generated_images"))
            .map { ($0, "Изображения ChatGPT / Codex", "ChatGPT / Codex images") }
        candidates += matchingDirectories(at: home.appendingPathComponent(".codex/visualizations"), maxDepth: 5) {
            looksLikeUUID($0.lastPathComponent)
        }.map { ($0, "Визуализация ChatGPT / Codex", "ChatGPT / Codex visualization") }

        // These are reproducible but may be in use by a running Codex app, so keep them opt-in.
        candidates += topLevelEntries(at: home.appendingPathComponent(".codex/.tmp"))
            .map { ($0, "Временные данные ChatGPT / Codex", "ChatGPT / Codex temporary data") }

        var rows: [JunkItem] = []
        for (url, ruTitle, enTitle) in candidates {
            if Keep.isExtraProtected(url) { continue }
            if Keep.isProtected(url), !isAllowedProtectedArtifact(url) { continue }
            guard let stats = recursiveStats(at: url, limit: 25_000) else { continue }
            let ageDays = max(0, Int(now.timeIntervalSince(stats.newest) / 86_400))
            guard ageDays >= 30 else { continue }
            let bytes = stats.bytes
            guard bytes > 16_384 else { continue }
            let isRunningAppTemp = url.path.contains("/.codex/.tmp/")
            rows.append(JunkItem(
                id: "artifact-local-\(stableKey(url.standardizedFileURL.path))",
                module: .junk,
                title: Line(ru: ruTitle, en: enTitle),
                subtitle: Line(
                    ru: "Не чаты и не проекты · \(ageDays) дн. · выкл.",
                    en: "Not chats or projects · \(ageDays)d · off"
                ),
                url: url,
                bytes: bytes,
                selected: false,
                kind: isRunningAppTemp ? .wipeChildren : .deleteItem,
                keepsLogins: true
            ))
        }
        return Array(dedupe(rows).sorted { $0.bytes > $1.bytes }.prefix(60))
    }

    /// Narrow exception for opt-in, aged artifact cards that live below otherwise protected
    /// chat/session roots. The broad roots remain invisible to Large Files and Leftovers.
    static func isAllowedProtectedArtifact(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if path.contains("/.claude/projects/"), path.hasSuffix("/tool-results") { return true }
        if path.contains("/Library/Application Support/Claude/local-agent-mode-sessions/"),
           url.lastPathComponent.hasPrefix("local_") { return true }
        if path.contains("/.claude/downloads/") { return true }
        if path.contains("/.codex/generated_images/") { return true }
        if path.contains("/.codex/visualizations/") { return true }
        if path.contains("/.codex/.tmp/") { return true }
        return false
    }

    private static func topLevelEntries(at root: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ))?.filter { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isSymbolicLink != true && (values.isDirectory == true || values.isRegularFile == true)
        } ?? []
    }

    private static func matchingDirectories(
        at root: URL,
        maxDepth: Int,
        predicate: (URL) -> Bool
    ) -> [URL] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        let rootDepth = root.standardizedFileURL.pathComponents.count
        var rows: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > 20_000 { break }
            let depth = url.standardizedFileURL.pathComponents.count - rootDepth
            if depth > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            if predicate(url) {
                rows.append(url)
                enumerator.skipDescendants()
            }
        }
        return rows
    }

    /// Nil means unreadable or too large to classify safely; such folders are never offered.
    private static func recursiveStats(at url: URL, limit: Int) -> (newest: Date, bytes: Int64)? {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey, .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey
        ]
        guard let rootValues = try? url.resourceValues(forKeys: keys),
              rootValues.isSymbolicLink != true else { return nil }
        var newest = rootValues.contentModificationDate ?? .distantPast
        var bytes = Int64(
            rootValues.totalFileAllocatedSize
                ?? rootValues.fileAllocatedSize
                ?? rootValues.fileSize
                ?? 0
        )
        if rootValues.isDirectory != true { return (newest, bytes) }
        guard let enumerator = fm.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        var visited = 0
        for case let child as URL in enumerator {
            visited += 1
            if visited > limit { return nil }
            guard let values = try? child.resourceValues(forKeys: keys),
                  values.isSymbolicLink != true else { continue }
            if let modified = values.contentModificationDate, modified > newest { newest = modified }
            if values.isRegularFile == true {
                bytes += Int64(
                    values.totalFileAllocatedSize
                        ?? values.fileAllocatedSize
                        ?? values.fileSize
                        ?? 0
                )
            }
        }
        return (newest, bytes)
    }

    // MARK: - Helpers

    private static func downloadOrigins(of url: URL) -> [String] {
        let attribute = "com.apple.metadata:kMDItemWhereFroms"
        return url.withUnsafeFileSystemRepresentation { path -> [String] in
            guard let path else { return [] }
            let size = getxattr(path, attribute, nil, 0, 0, 0)
            guard size > 0, size <= 1_048_576 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                getxattr(path, attribute, bytes.baseAddress, bytes.count, 0, 0)
            }
            guard count > 0 else { return [] }
            let data = Data(buffer.prefix(count))
            guard let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else {
                return []
            }
            return value as? [String] ?? []
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
    }

    private static func containsPhrase(_ value: String, phrase: String) -> Bool {
        if value == phrase { return true }
        let padded = " \(value) "
        return padded.contains(" \(phrase) ")
            || padded.contains(" \(phrase)(")
            || padded.contains(" \(phrase) ")
    }

    private static func hasFilenamePrefix(_ value: String, prefix: String) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        if value == prefix { return true }
        let next = value[value.index(value.startIndex, offsetBy: prefix.count)]
        return next.isWhitespace || next.isNumber || next == "(" || next == "."
    }

    private static func looksLikeUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil || (value.count >= 24 && value.contains("-"))
    }

    private static func days(_ count: Int) -> TimeInterval {
        TimeInterval(count) * 86_400
    }

    private static func stableKey(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func dedupe(_ items: [JunkItem]) -> [JunkItem] {
        var seen = Set<String>()
        return items.filter { item in
            let key = item.url.standardizedFileURL.path
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }
}
