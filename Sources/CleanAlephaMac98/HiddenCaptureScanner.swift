import Darwin
import Foundation
import CryptoKit
import UniformTypeIdentifiers

/// Finds full-size screenshots and recordings that macOS can leave behind after the
/// visible copy has gone. Most are user documents and stay opt-in. Aged files in an
/// app container's TemporaryItems are the narrow Safe-preset exception. Deletion is
/// always limited to files re-classified at clean time.
enum HiddenCaptureScanner {
    enum SourceKind: String, Sendable {
        case darwinTemp
        case screenCaptureIntermediates
        case replaydTemporary
        case screenCaptureUITemporary
        case telegramTempMedia
        case screenCaptureGroup
        case legacyScreenRecordings
        case quickTimeAutosave
        case userAutosave
        case claudeCaptureCopies
        case cursorWorkspaceCaptures
        case cursorProjectCaptures
        case containerTemporaryItems
    }

    struct Remnant: Sendable {
        let url: URL
        let bytes: Int64
        let modified: Date
    }

    private struct Source {
        let id: String
        let kind: SourceKind
        let root: URL
        let minimumAge: TimeInterval
        let title: Line
    }

    private static let mediaExtensions: Set<String> = [
        "png", "jpg", "jpeg", "heic", "tiff", "gif", "webp", "avif",
        "mov", "mp4", "m4v", "webm"
    ]
    private static let capturePrefixes = [
        "screenshot", "screen shot", "screen recording", "screenrecording",
        "снимок экрана", "запись экрана", "знімок екрана", "запис екрана"
    ]
    private static let minimumCardBytes: Int64 = 16_384
    private static let maximumEntries = 20_000

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

    private static var sources: [Source] {
        var result: [Source] = [
            Source(
                id: "hidden-capture-group",
                kind: .screenCaptureGroup,
                root: home.appendingPathComponent(
                    "Library/Group Containers/group.com.apple.screencapture/ScreenRecordings"
                ),
                minimumAge: 3_600,
                title: Line(ru: "Скрытые записи экрана macOS", en: "Hidden macOS screen recordings")
            ),
            Source(
                id: "hidden-capture-legacy",
                kind: .legacyScreenRecordings,
                root: home.appendingPathComponent("Library/ScreenRecordings"),
                minimumAge: 3_600,
                title: Line(ru: "Старое хранилище записей экрана", en: "Legacy screen recording storage")
            ),
            Source(
                id: "hidden-capture-quicktime",
                kind: .quickTimeAutosave,
                root: home.appendingPathComponent(
                    "Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information"
                ),
                minimumAge: 86_400,
                title: Line(ru: "Забытые записи QuickTime", en: "Forgotten QuickTime recordings")
            ),
            Source(
                id: "hidden-capture-autosave",
                kind: .userAutosave,
                root: home.appendingPathComponent("Library/Autosave Information"),
                minimumAge: 86_400,
                title: Line(ru: "Автосохранения записей экрана", en: "Screen recording autosaves")
            )
        ]
        var runtimeSources: [Source] = []
        for (index, temporary) in darwinTemporaryRoots().enumerated() {
            let suffix = index == 0 ? "" : "-\(stableKey(canonicalPath(temporary)))"
            let oldRU = index == 0 ? "" : "Старое системное хранилище · "
            let oldEN = index == 0 ? "" : "Old system store · "
            runtimeSources.append(Source(
                id: "hidden-capture-darwin-temp\(suffix)",
                kind: .darwinTemp,
                root: temporary,
                minimumAge: 3_600,
                title: Line(
                    ru: "\(oldRU)скрытые копии скриншотов в temp",
                    en: "\(oldEN)hidden screenshot copies in temp"
                )
            ))
            // Telegram provenance is meaningful only for the active temp root. Old
            // Darwin roots are searched as generic media stores without attributing
            // extensionless files to an app.
            if index == 0 {
                runtimeSources.append(Source(
                    id: "hidden-media-telegram-temp",
                    kind: .telegramTempMedia,
                    root: temporary,
                    minimumAge: 3_600,
                    title: Line(
                        ru: "Telegram · скрытые временные медиа",
                        en: "Telegram · hidden temporary media"
                    )
                ))
            }
            runtimeSources.append(Source(
                id: "hidden-capture-nsird-intermediates\(suffix)",
                kind: .screenCaptureIntermediates,
                root: temporary.appendingPathComponent("TemporaryItems"),
                minimumAge: 3_600,
                title: Line(
                    ru: "\(oldRU)ScreenCaptureUI · удалённые снимки в NSIRD",
                    en: "\(oldEN)ScreenCaptureUI · deleted captures in NSIRD"
                )
            ))
            runtimeSources.append(Source(
                id: "hidden-capture-replayd-temp\(suffix)",
                kind: .replaydTemporary,
                root: temporary.appendingPathComponent("com.apple.replayd/TemporaryItems"),
                minimumAge: 3_600,
                title: Line(
                    ru: "\(oldRU)replayd · отброшенные записи экрана",
                    en: "\(oldEN)replayd · discarded screen recordings"
                )
            ))
            runtimeSources.append(Source(
                id: "hidden-capture-ui-temp\(suffix)",
                kind: .screenCaptureUITemporary,
                root: temporary.appendingPathComponent("com.apple.screencaptureui"),
                minimumAge: 3_600,
                title: Line(
                    ru: "\(oldRU)ScreenCaptureUI · временные снимки и записи",
                    en: "\(oldEN)ScreenCaptureUI · temporary captures"
                )
            ))
        }
        result.insert(contentsOf: runtimeSources, at: 0)
        result.append(contentsOf: [
            Source(
                id: "hidden-copy-claude-captures",
                kind: .claudeCaptureCopies,
                root: home.appendingPathComponent("Library/Application Support/Claude"),
                minimumAge: 7 * 86_400,
                title: Line(
                    ru: "Claude · копии старых скриншотов",
                    en: "Claude · copies of old screenshots"
                )
            ),
            Source(
                id: "hidden-copy-cursor-workspace-captures",
                kind: .cursorWorkspaceCaptures,
                root: home.appendingPathComponent("Library/Application Support/Cursor/User/workspaceStorage"),
                minimumAge: 7 * 86_400,
                title: Line(
                    ru: "Cursor · копии скриншотов в workspace",
                    en: "Cursor · workspace screenshot copies"
                )
            ),
            Source(
                id: "hidden-copy-cursor-project-captures",
                kind: .cursorProjectCaptures,
                root: home.appendingPathComponent(".cursor/projects"),
                minimumAge: 7 * 86_400,
                title: Line(
                    ru: "Cursor · дубли скриншотов в проектах",
                    en: "Cursor · project screenshot duplicates"
                )
            )
        ])
        result.append(contentsOf: containerTemporarySources())
        return result
    }

    static func items(now: Date = Date()) -> [JunkItem] {
        sources.compactMap { source in
            let found = remnants(in: source, now: now)
            let bytes = found.reduce(Int64(0)) { $0 + $1.bytes }
            guard bytes >= minimumCardBytes else { return nil }
            let oldestHours = found.map { Int(now.timeIntervalSince($0.modified) / 3_600) }.max() ?? 0
            let subtitle: Line
            switch source.kind {
            case .screenCaptureIntermediates:
                subtitle = Line(
                    ru: "\(found.count) полноразмерных снимков/записей в NSIRD_screencaptureui · до \(ageTextRU(hours: oldestHours)) · оригиналы уже могут быть удалены",
                    en: "\(found.count) full-size captures in NSIRD_screencaptureui · up to \(ageTextEN(hours: oldestHours)) old · originals may already be deleted"
                )
            case .telegramTempMedia:
                let imageCount = found.reduce(0) { $0 + (mediaKind($1.url) == .image ? 1 : 0) }
                let videoCount = found.reduce(0) { $0 + (mediaKind($1.url) == .video ? 1 : 0) }
                subtitle = Line(
                    ru: "\(found.count) файлов без расширения: \(imageCount) изображений, \(videoCount) видео · до \(ageTextRU(hours: oldestHours)) · аккаунты не затрагиваются",
                    en: "\(found.count) extensionless files: \(imageCount) images, \(videoCount) videos · up to \(ageTextEN(hours: oldestHours)) old · accounts stay untouched"
                )
            case .claudeCaptureCopies, .cursorWorkspaceCaptures, .cursorProjectCaptures:
                subtitle = Line(
                    ru: "\(found.count) старых локальных копий · до \(ageTextRU(hours: oldestHours)) · превью старых чатов могут исчезнуть",
                    en: "\(found.count) old local copies · up to \(ageTextEN(hours: oldestHours)) old · old chat previews may disappear"
                )
            case .containerTemporaryItems:
                let imageCount = found.reduce(0) { $0 + (mediaKind($1.url) == .image ? 1 : 0) }
                let videoCount = found.reduce(0) { $0 + (mediaKind($1.url) == .video ? 1 : 0) }
                let duplicates = exactDuplicateSummary(found)
                let duplicateRU = duplicates.files > 0
                    ? " · точных лишних копий: \(duplicates.files) в \(duplicates.groups) группах (\(ByteFormat.string(duplicates.bytes, .ru)))"
                    : ""
                let duplicateEN = duplicates.files > 0
                    ? " · exact redundant copies: \(duplicates.files) in \(duplicates.groups) groups (\(ByteFormat.string(duplicates.bytes, .en)))"
                    : ""
                subtitle = Line(
                    ru: "\(found.count) старых файлов: \(imageCount) изображений, \(videoCount) видео\(duplicateRU) · до \(ageTextRU(hours: oldestHours)) · системный TemporaryItems · входит в безопасный выбор",
                    en: "\(found.count) old files: \(imageCount) images, \(videoCount) videos\(duplicateEN) · up to \(ageTextEN(hours: oldestHours)) old · system TemporaryItems · included by Select safe items"
                )
            default:
                subtitle = Line(
                    ru: "\(found.count) полных копий · до \(ageTextRU(hours: oldestHours)) · скрыто Finder",
                    en: "\(found.count) full-size copies · up to \(ageTextEN(hours: oldestHours)) old · hidden by Finder"
                )
            }
            return JunkItem(
                id: source.id,
                module: .junk,
                title: source.title,
                subtitle: subtitle,
                url: source.root,
                bytes: bytes,
                selected: false,
                kind: .deleteCaptureRemnants,
                keepsLogins: source.kind == .telegramTempMedia || source.kind == .containerTemporaryItems
            )
        }.sorted { $0.bytes > $1.bytes }
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        guard item.kind == .deleteCaptureRemnants,
              let source = source(for: item),
              canonicalPath(source.root) == canonicalPath(item.url) else { return false }
        return true
    }

    static func isSafeDeletionCandidate(_ item: JunkItem, now: Date = Date()) -> Bool {
        guard isExplicitCard(item), let source = source(for: item) else { return false }
        return !remnants(in: source, now: now).isEmpty
    }

    /// Old media in a sandbox `TemporaryItems` directory is a narrow, rebuild-free
    /// cleanup boundary and can be added by the user's Safe button. Other full-size
    /// capture copies remain manual because they may be the only recoverable copy.
    static func isSafePresetCard(_ item: JunkItem) -> Bool {
        guard let source = source(for: item), isExplicitCard(item) else { return false }
        return source.kind == .containerTemporaryItems
    }

    static func currentBytes(for item: JunkItem, now: Date = Date()) -> Int64 {
        guard let source = source(for: item), isExplicitCard(item) else { return 0 }
        return remnants(in: source, now: now).reduce(Int64(0)) { $0 + $1.bytes }
    }

    /// Avoid double-counting these full-size files in SystemDeepScanner's temp audit.
    static func bytesInsideDarwinTemp(_ root: URL, now: Date = Date()) -> Int64 {
        sources
            .filter {
                ($0.kind == .darwinTemp
                    || $0.kind == .screenCaptureIntermediates
                    || $0.kind == .telegramTempMedia)
                    && canonicalPath($0.root) == canonicalPath(root)
            }
            .flatMap { remnants(in: $0, now: now) }
            .reduce(Int64(0)) { $0 + $1.bytes }
    }

    static func blockingProcessName(for item: JunkItem, now: Date = Date()) -> String? {
        guard let source = source(for: item), isExplicitCard(item) else { return nil }
        let found = remnants(in: source, now: now)
        guard !found.isEmpty else { return nil }

        for start in stride(from: 0, to: found.count, by: 120) {
            let batch = Array(found[start..<min(start + 120, found.count)])
            var arguments = ["-Fpc", "-nP", "--"]
            arguments.append(contentsOf: batch.map(\.url.path))
            let ran = CamProcess.run(path: "/usr/sbin/lsof", arguments: arguments, timeout: 3)
            if ran.timedOut { return "active screen capture" }
            if let process = firstForeignProcess(in: ran.out) { return process }
        }
        return nil
    }

    static func removeEligibleRemnants(
        for item: JunkItem,
        now: Date = Date()
    ) -> (before: Int64, after: Int64, failed: Bool) {
        guard let source = source(for: item), isExplicitCard(item) else { return (0, 0, true) }
        let beforeRows = remnants(in: source, now: now)
        let before = beforeRows.reduce(Int64(0)) { $0 + $1.bytes }
        guard before > 0 else { return (0, 0, false) }
        var failed = false
        for remnant in beforeRows {
            if Keep.isExtraProtected(remnant.url) { failed = true; continue }
            do {
                try FileManager.default.removeItem(at: remnant.url)
            } catch {
                failed = true
            }
        }
        let after = remnants(in: source, now: now).reduce(Int64(0)) { $0 + $1.bytes }
        return (before, after, failed && after > 0)
    }

    static func isCaptureForQA(
        name: String,
        contentType: UTType?,
        dedicatedRoot: Bool,
        hasCaptureMetadata: Bool,
        temporaryPathMarker: Bool
    ) -> Bool {
        isCaptureMedia(
            name: name,
            contentType: contentType,
            dedicatedRoot: dedicatedRoot,
            hasCaptureMetadata: hasCaptureMetadata,
            temporaryPathMarker: temporaryPathMarker
        )
    }

    static func isEligibleDarwinFileForQA(_ url: URL, now: Date) -> Bool {
        guard let source = activeDarwinSource(kind: .darwinTemp),
              canonicalPath(url.deletingLastPathComponent()) == canonicalPath(source.root),
              let values = darwinCaptureValues(url, source: source) else { return false }
        return remnant(url, values: values, source: source, now: now) != nil
    }

    static func isKnownDarwinCapture(_ url: URL) -> Bool {
        // This hot path runs once per child while SystemDeepScanner inventories T.
        // Do not rebuild the complete dynamic source catalogue for every file.
        if let source = activeDarwinSource(kind: .darwinTemp),
           darwinCaptureValues(url, source: source) != nil { return true }
        guard let telegram = activeDarwinSource(kind: .telegramTempMedia) else { return false }
        return telegramTempValues(url, source: telegram) != nil
    }

    static func isTelegramTemporaryMedia(_ url: URL) -> Bool {
        guard let source = activeDarwinSource(kind: .telegramTempMedia) else { return false }
        return telegramTempValues(url, source: source) != nil
    }

    static func declaredOwnerName(for item: JunkItem) -> String? {
        guard let source = source(for: item), isExplicitCard(item) else { return nil }
        switch source.kind {
        case .telegramTempMedia: return "Telegram"
        case .containerTemporaryItems:
            return canonicalPath(source.root).contains("/Containers/com.apple.MobileSMS/")
                ? "Messages" : nil
        case .claudeCaptureCopies: return "Claude"
        case .cursorWorkspaceCaptures, .cursorProjectCaptures: return "Cursor"
        default: return nil
        }
    }

    /// Full-size hidden captures used as read-only references by the provenance pass.
    /// Moving the comparison clock forward includes recent captures without making their
    /// cleanup cards eligible any earlier than their normal per-source minimum age.
    static func provenanceCaptureURLs(now: Date = Date()) -> [URL] {
        let comparisonNow = now.addingTimeInterval(31 * 86_400)
        var seen = Set<String>()
        return sources
            .filter { $0.kind != .telegramTempMedia && $0.kind != .containerTemporaryItems }
            .flatMap { remnants(in: $0, now: comparisonNow) }
            .map(\.url)
            .filter { seen.insert(canonicalPath($0)).inserted }
    }

    static func isTelegramTemporaryMediaForQA(
        name: String,
        header: Data,
        quarantine: String
    ) -> Bool {
        isNumericTemporaryName(name)
            && hasMediaMagic(header)
            && quarantineAgent(quarantine)?.caseInsensitiveCompare("Telegram") == .orderedSame
    }

    static func darwinTemporaryRootsForQA() -> [URL] {
        darwinTemporaryRoots()
    }

    private static func remnants(in source: Source, now: Date) -> [Remnant] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }
        switch source.kind {
        case .darwinTemp:
            return darwinTempRemnants(source: source, now: now)
        case .screenCaptureIntermediates:
            return screenCaptureIntermediateRemnants(source: source, now: now)
        case .replaydTemporary, .screenCaptureUITemporary:
            return dedicatedMediaRemnants(source: source, now: now)
        case .telegramTempMedia:
            return telegramTempRemnants(source: source, now: now)
        case .quickTimeAutosave, .userAutosave:
            return autosaveRemnants(source: source, now: now)
        case .screenCaptureGroup, .legacyScreenRecordings:
            return dedicatedMediaRemnants(source: source, now: now)
        case .containerTemporaryItems:
            return dedicatedMediaRemnants(source: source, now: now)
        case .claudeCaptureCopies, .cursorWorkspaceCaptures, .cursorProjectCaptures:
            return appCaptureCopies(source: source, now: now)
        }
    }

    private static func activeDarwinSource(kind: SourceKind) -> Source? {
        guard let temporary = SystemDeepScanner.tempRootURL else { return nil }
        switch kind {
        case .darwinTemp:
            return Source(
                id: "hidden-capture-darwin-temp",
                kind: kind,
                root: temporary,
                minimumAge: 3_600,
                title: Line(ru: "Скрытые копии скриншотов в temp", en: "Hidden screenshot copies in temp")
            )
        case .telegramTempMedia:
            return Source(
                id: "hidden-media-telegram-temp",
                kind: kind,
                root: temporary,
                minimumAge: 3_600,
                title: Line(
                    ru: "Telegram · скрытые временные медиа",
                    en: "Telegram · hidden temporary media"
                )
            )
        default:
            return nil
        }
    }

    private static func telegramTempRemnants(source: Source, now: Date) -> [Remnant] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: source.root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            CamLog.line("telegram temp denied \(source.root.path)")
            return []
        }
        return children.compactMap { url in
            guard let values = telegramTempValues(url, source: source) else { return nil }
            return remnant(url, values: values, source: source, now: now)
        }
    }

    private static func appCaptureCopies(source: Source, now: Date) -> [Remnant] {
        var denied = false
        guard let enumerator = FileManager.default.enumerator(
            at: source.root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in denied = true; return true }
        ) else { return [] }
        var rows: [Remnant] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > 60_000 { break }
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  isAppCapturePath(url, kind: source.kind),
                  isCaptureMedia(
                    name: url.lastPathComponent,
                    contentType: values.contentType,
                    dedicatedRoot: false,
                    hasCaptureMetadata: hasCaptureXattr(url),
                    temporaryPathMarker: false
                  ),
                  let row = remnant(url, values: values, source: source, now: now) else { continue }
            rows.append(row)
        }
        if denied { CamLog.line("hidden app captures partial \(source.root.path)") }
        return dedupe(rows)
    }

    private static func isAppCapturePath(_ url: URL, kind: SourceKind) -> Bool {
        let path = url.standardizedFileURL.path.lowercased()
        switch kind {
        case .claudeCaptureCopies:
            return path.contains("/uploads/") || path.contains("/pending-uploads/")
        case .cursorWorkspaceCaptures:
            return path.contains("/workspacestorage/") && path.contains("/images/")
        case .cursorProjectCaptures:
            return path.contains("/.cursor/projects/")
                && (path.contains("/assets/") || path.contains("/uploads/"))
        case .containerTemporaryItems:
            return false
        default:
            return false
        }
    }

    private static func darwinTempRemnants(source: Source, now: Date) -> [Remnant] {
        let keys = resourceKeys
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: source.root,
            includingPropertiesForKeys: Array(keys),
            options: []
        ) else {
            CamLog.line("hidden capture denied \(source.root.path)")
            return []
        }
        var rows: [Remnant] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: keys), values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true,
               isCaptureMedia(
                name: child.lastPathComponent,
                contentType: values.contentType,
                dedicatedRoot: false,
                hasCaptureMetadata: hasCaptureXattr(child),
                temporaryPathMarker: false
               ),
               let row = remnant(child, values: values, source: source, now: now) {
                rows.append(row)
                continue
            }
            guard values.isDirectory == true,
                  child.lastPathComponent.lowercased().hasPrefix("nsird_screencaptureui_") else { continue }
            rows.append(contentsOf: temporaryItems(in: child, source: source, now: now))
        }
        return dedupe(rows)
    }

    /// `screencaptureui` creates NSIRD directories when a floating screenshot is dragged,
    /// shared or handed to another process. The visible original may later be deleted while
    /// this full-size intermediate remains in protected TemporaryItems.
    private static func screenCaptureIntermediateRemnants(source: Source, now: Date) -> [Remnant] {
        var denied = false
        guard let enumerator = FileManager.default.enumerator(
            at: source.root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in denied = true; return true }
        ) else {
            CamLog.line("NSIRD screen captures denied \(source.root.path)")
            return []
        }
        var rows: [Remnant] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maximumEntries { break }
            let lowerPath = url.standardizedFileURL.path.lowercased()
            guard lowerPath.contains("/nsird_screencaptureui_"),
                  let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  isCaptureMedia(
                    name: url.lastPathComponent,
                    contentType: values.contentType,
                    dedicatedRoot: false,
                    hasCaptureMetadata: hasCaptureXattr(url),
                    temporaryPathMarker: true
                  ),
                  let row = remnant(url, values: values, source: source, now: now) else { continue }
            rows.append(row)
        }
        if denied { CamLog.line("NSIRD screen captures partial \(source.root.path)") }
        return dedupe(rows)
    }

    private static func temporaryItems(in root: URL, source: Source, now: Date) -> [Remnant] {
        var denied = false
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in denied = true; return true }
        ) else { return [] }
        var rows: [Remnant] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maximumEntries { break }
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true else { continue }
            let marker = url.path.lowercased().contains("screencapture")
                || url.path.lowercased().contains("nsird_")
            guard isCaptureMedia(
                name: url.lastPathComponent,
                contentType: values.contentType,
                dedicatedRoot: false,
                hasCaptureMetadata: hasCaptureXattr(url),
                temporaryPathMarker: marker
            ), let row = remnant(url, values: values, source: source, now: now) else { continue }
            rows.append(row)
        }
        if denied { CamLog.line("hidden capture partial \(root.path)") }
        return rows
    }

    private static func dedicatedMediaRemnants(source: Source, now: Date) -> [Remnant] {
        var denied = false
        guard let enumerator = FileManager.default.enumerator(
            at: source.root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [],
            errorHandler: { _, _ in denied = true; return true }
        ) else {
            CamLog.line("hidden capture denied \(source.root.path)")
            return []
        }
        var rows: [Remnant] = []
        var count = 0
        for case let url as URL in enumerator {
            count += 1
            if count > maximumEntries { break }
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true,
                  values.isRegularFile == true,
                  isCaptureMedia(
                    name: url.lastPathComponent,
                    contentType: values.contentType,
                    dedicatedRoot: true,
                    hasCaptureMetadata: hasCaptureXattr(url),
                    temporaryPathMarker: true
                  ),
                  let row = remnant(url, values: values, source: source, now: now) else { continue }
            rows.append(row)
        }
        if denied { CamLog.line("hidden capture partial \(source.root.path)") }
        return dedupe(rows)
    }

    private static func autosaveRemnants(source: Source, now: Date) -> [Remnant] {
        let fm = FileManager.default
        guard let children = try? fm.contentsOfDirectory(
            at: source.root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: []
        ) else {
            CamLog.line("hidden capture denied \(source.root.path)")
            return []
        }
        var rows: [Remnant] = []
        for child in children {
            guard let values = try? child.resourceValues(forKeys: resourceKeys),
                  values.isSymbolicLink != true else { continue }
            let lower = child.lastPathComponent.lowercased()
            let isComposition = ["qtpxcomposition", "qtxcomposition"].contains(child.pathExtension.lowercased())
            let isQuickTime = lower.contains("quicktime") || isComposition
            if values.isDirectory == true, isQuickTime {
                guard eligible(values: values, minimumAge: source.minimumAge, now: now) else { continue }
                let bytes = DiskSizer.duSK(child, timeout: 5) ?? 0
                if bytes > 0 {
                    rows.append(Remnant(
                        url: child,
                        bytes: bytes,
                        modified: newestDate(values)
                    ))
                }
                continue
            }
            guard values.isRegularFile == true,
                  isQuickTime,
                  isCaptureMedia(
                    name: child.lastPathComponent,
                    contentType: values.contentType,
                    dedicatedRoot: true,
                    hasCaptureMetadata: hasCaptureXattr(child),
                    temporaryPathMarker: true
                  ),
                  let row = remnant(child, values: values, source: source, now: now) else { continue }
            rows.append(row)
        }
        return dedupe(rows)
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        .contentModificationDateKey, .creationDateKey, .contentTypeKey
    ]

    private static func remnant(
        _ url: URL,
        values: URLResourceValues,
        source: Source,
        now: Date
    ) -> Remnant? {
        guard eligible(values: values, minimumAge: source.minimumAge, now: now) else { return nil }
        let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        guard bytes > 0 else { return nil }
        return Remnant(url: url, bytes: bytes, modified: newestDate(values))
    }

    private static func eligible(values: URLResourceValues, minimumAge: TimeInterval, now: Date) -> Bool {
        let date = newestDate(values)
        return date <= now && now.timeIntervalSince(date) >= minimumAge
    }

    private static func newestDate(_ values: URLResourceValues) -> Date {
        max(values.contentModificationDate ?? .distantPast, values.creationDate ?? .distantPast)
    }

    private static func isCaptureMedia(
        name: String,
        contentType: UTType?,
        dedicatedRoot: Bool,
        hasCaptureMetadata: Bool,
        temporaryPathMarker: Bool
    ) -> Bool {
        let lower = name.precomposedStringWithCanonicalMapping.lowercased()
        let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
        let media = mediaExtensions.contains(ext)
            || contentType?.conforms(to: .image) == true
            || contentType?.conforms(to: .movie) == true
            || contentType?.conforms(to: .audiovisualContent) == true
        guard media else { return false }
        if dedicatedRoot { return true }
        return hasCaptureMetadata
            || temporaryPathMarker
            || capturePrefixes.contains { lower.hasPrefix($0) }
    }

    private static func hasCaptureXattr(_ url: URL) -> Bool {
        url.path.withCString { path in
            "com.apple.metadata:kMDItemIsScreenCapture".withCString { name in
                getxattr(path, name, nil, 0, 0, 0) > 0
            }
        }
    }

    private static func telegramTempValues(_ url: URL, source: Source) -> URLResourceValues? {
        guard canonicalPath(url.deletingLastPathComponent()) == canonicalPath(source.root),
              isNumericTemporaryName(url.lastPathComponent),
              quarantineAgent(of: url)?.caseInsensitiveCompare("Telegram") == .orderedSame,
              hasMediaMagic(url),
              let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isSymbolicLink != true,
              values.isRegularFile == true else { return nil }
        return values
    }

    private static func isNumericTemporaryName(_ name: String) -> Bool {
        let digits = name.hasPrefix("-") ? name.dropFirst() : name[...]
        return !digits.isEmpty && digits.count <= 20 && digits.allSatisfy(\.isNumber)
    }

    private static func quarantineAgent(of url: URL) -> String? {
        guard let value = extendedAttribute("com.apple.quarantine", of: url),
              let text = String(data: value, encoding: .utf8) else { return nil }
        return quarantineAgent(text)
    }

    private static func quarantineAgent(_ value: String) -> String? {
        let fields = value.split(separator: ";", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { return nil }
        let agent = String(fields[2]).trimmingCharacters(in: .whitespacesAndNewlines)
        return agent.isEmpty ? nil : agent
    }

    private static func extendedAttribute(_ name: String, of url: URL) -> Data? {
        let size = url.path.withCString { path in
            name.withCString { getxattr(path, $0, nil, 0, 0, 0) }
        }
        guard size > 0, size <= 16_384 else { return nil }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { buffer in
            url.path.withCString { path in
                name.withCString { getxattr(path, $0, buffer.baseAddress, size, 0, 0) }
            }
        }
        guard read == size else { return nil }
        return data
    }

    private static func hasMediaMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 24) else { return false }
        return hasMediaMagic(data)
    }

    private enum BinaryMediaKind { case image, video }

    private static func mediaKind(_ url: URL) -> BinaryMediaKind? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 24) else { return nil }
        let bytes = [UInt8](data.prefix(24))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            || bytes.starts(with: [0xFF, 0xD8, 0xFF])
            || bytes.starts(with: Array("GIF8".utf8)) { return .image }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return .image }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) {
            let brand = String(bytes: bytes[8..<12], encoding: .ascii)?.lowercased() ?? ""
            return ["heic", "heix", "hevc", "hevx", "mif1", "msf1", "avif", "avis"].contains(brand)
                ? .image : .video
        }
        return nil
    }

    private static func hasMediaMagic(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(24))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF8".utf8)) { return true }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return true }
        return false
    }

    private static func darwinCaptureValues(_ url: URL, source: Source) -> URLResourceValues? {
        guard canonicalPath(url.deletingLastPathComponent()) == canonicalPath(source.root),
              let values = try? url.resourceValues(forKeys: resourceKeys),
              values.isSymbolicLink != true,
              values.isRegularFile == true,
              isCaptureMedia(
                name: url.lastPathComponent,
                contentType: values.contentType,
                dedicatedRoot: false,
                hasCaptureMetadata: hasCaptureXattr(url),
                temporaryPathMarker: false
              ) else { return nil }
        return values
    }

    private static func firstForeignProcess(in output: String) -> String? {
        var pid: String?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let marker = line.first else { continue }
            let value = String(line.dropFirst())
            if marker == "p" { pid = value; continue }
            if marker == "c", pid != String(getpid()) {
                let lower = value.lowercased()
                if lower != "lsof" && !lower.contains("cleanal") {
                    return value.isEmpty ? "active screen capture" : value
                }
            }
        }
        return nil
    }

    private static func source(for item: JunkItem) -> Source? {
        sources.first { $0.id == item.id }
    }

    private static func containerTemporarySources() -> [Source] {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library")
        var roots: [(owner: String, url: URL)] = []
        let containers = library.appendingPathComponent("Containers")
        if let children = try? fm.contentsOfDirectory(
            at: containers,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            for container in children {
                let root = container.appendingPathComponent("Data/tmp/TemporaryItems")
                if isRealDirectory(root) {
                    let owner = container.lastPathComponent == "com.apple.MobileSMS"
                        ? "Apple Messages" : container.lastPathComponent
                    roots.append((owner, root))
                }
            }
        }
        let groups = library.appendingPathComponent("Group Containers")
        if let children = try? fm.contentsOfDirectory(
            at: groups,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ) {
            for group in children {
                let root = group.appendingPathComponent("TemporaryItems")
                if isRealDirectory(root) { roots.append((group.lastPathComponent, root)) }
            }
        }
        var seen = Set<String>()
        return roots
            .filter { seen.insert(canonicalPath($0.url)).inserted }
            .map { entry in
                Source(
                    id: "hidden-container-temporary-\(stableKey(canonicalPath(entry.url)))",
                    kind: .containerTemporaryItems,
                    root: entry.url,
                    minimumAge: 7 * 86_400,
                    title: Line(
                        ru: "\(entry.owner) · забытые медиа в TemporaryItems",
                        en: "\(entry.owner) · forgotten media in TemporaryItems"
                    )
                )
            }
    }

    /// `confstr` returns only the active Darwin token. macOS can leave older tokens
    /// behind after migration, an OS upgrade, or account recreation, so discover every
    /// real T directory owned by the current uid while refusing symlinks and foreign roots.
    private static func darwinTemporaryRoots() -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        var seen = Set<String>()
        if let current = SystemDeepScanner.tempRootURL,
           isOwnedDirectory(current),
           seen.insert(darwinPathKey(current)).inserted {
            result.append(current)
        }

        let base = URL(fileURLWithPath: "/private/var/folders", isDirectory: true)
        guard let buckets = try? fm.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsSubdirectoryDescendants]
        ) else { return result }
        var discovered: [URL] = []
        var inspected = 0
        for bucket in buckets.sorted(by: { $0.path < $1.path }) {
            guard let tokens = try? fm.contentsOfDirectory(
                at: bucket,
                includingPropertiesForKeys: nil,
                options: [.skipsSubdirectoryDescendants]
            ) else { continue }
            for token in tokens.sorted(by: { $0.path < $1.path }) {
                inspected += 1
                if inspected > 4_096 { break }
                let temporary = token.appendingPathComponent("T", isDirectory: true)
                let path = darwinPathKey(temporary)
                guard path.hasPrefix("/var/folders/"),
                      isOwnedDirectory(token),
                      isOwnedDirectory(temporary),
                      seen.insert(path).inserted else { continue }
                discovered.append(temporary)
            }
            if inspected > 4_096 { break }
        }
        result.append(contentsOf: discovered.sorted { $0.path < $1.path })
        return result
    }

    private static func darwinPathKey(_ url: URL) -> String {
        let path = canonicalPath(url)
        return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
    }

    private static func isOwnedDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return info.st_uid == getuid() && (info.st_mode & S_IFMT) == S_IFDIR
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
            return false
        }
        return values.isDirectory == true && values.isSymbolicLink != true
    }

    private static func exactDuplicateSummary(
        _ remnants: [Remnant]
    ) -> (groups: Int, files: Int, bytes: Int64) {
        let sizes = Dictionary(grouping: remnants) { remnant -> Int64 in
            var info = stat()
            guard remnant.url.path.withCString({ lstat($0, &info) }) == 0 else { return -1 }
            return Int64(info.st_size)
        }
        var groups = 0
        var files = 0
        var bytes: Int64 = 0
        for (size, sameSize) in sizes where size > 0 && sameSize.count > 1 {
            let byDigest = Dictionary(grouping: sameSize) {
                Scanner.contentSignature($0.url, size: size)
            }
            for exact in byDigest.values where exact.count > 1 {
                groups += 1
                let redundant = exact.sorted { $0.url.path < $1.url.path }.dropFirst()
                files += redundant.count
                bytes += redundant.reduce(Int64(0)) { $0 + $1.bytes }
            }
        }
        return (groups, files, bytes)
    }

    private static func dedupe(_ rows: [Remnant]) -> [Remnant] {
        var seen = Set<String>()
        return rows.filter {
            let key = canonicalPath($0.url)
            if seen.contains(key) { return false }
            seen.insert(key)
            return true
        }
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func stableKey(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    private static func ageTextRU(hours: Int) -> String {
        if hours >= 48 { return "\(hours / 24) дн." }
        return "\(max(1, hours)) ч"
    }

    private static func ageTextEN(hours: Int) -> String {
        if hours >= 48 { return "\(hours / 24) days" }
        return "\(max(1, hours)) hours"
    }
}
