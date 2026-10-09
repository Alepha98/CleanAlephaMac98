import Darwin
import Foundation

/// Read-only forensic discovery for captures that are no longer in their original folder.
///
/// Unlike `HiddenCaptureScanner`, discovery does not start from an app catalogue. Spotlight
/// metadata finds screen captures anywhere on the accessible data volume, then path context
/// separates normal user documents from copies retained by hidden/system-managed storage.
/// Protected stores are always reported when macOS refuses access instead of being treated as
/// empty. Nothing returned here is destructive.
enum ForensicRemnantScanner {
    private enum Access {
        case readable
        case denied
        case missing
    }

    private struct ProtectedStore {
        let id: String
        let title: Line
        let url: URL
        let isThumbnailCache: Bool
    }

    struct IndexedCapture: Sendable {
        let url: URL
        let bytes: Int64
    }

    private struct CachedIndex: Sendable {
        let created: Date
        let rows: [IndexedCapture]
    }

    private struct FinderCaptureSummary {
        let containers: Int
        let files: Int
        let videos: Int
        let bytes: Int64
    }

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    private static let indexLock = NSLock()
    nonisolated(unsafe) private static var captureIndexCache: CachedIndex?
    nonisolated(unsafe) private static var mediaIndexCache: CachedIndex?
    private static let indexReuseSeconds: TimeInterval = 180

    static func items() -> [JunkItem] {
        var rows: [JunkItem] = []
        let captures = indexedHiddenCaptures()
        let captureBytes = captures.reduce(Int64(0)) { $0 + $1.bytes }
        let capturePaths = Set(captures.map { canonicalPath($0.url) })
        if !captures.isEmpty {
            rows.append(JunkItem(
                id: "forensic-indexed-screen-captures",
                module: .junk,
                title: Line(
                    ru: "Системный индекс · скрытые копии снимков",
                    en: "System index · hidden capture copies"
                ),
                subtitle: Line(
                    ru: "\(captures.count) файлов определены macOS как скриншоты/записи вне обычных папок · только аудит",
                    en: "\(captures.count) files classified by macOS as captures outside normal folders · audit only"
                ),
                url: home.appendingPathComponent("Library"),
                bytes: captureBytes,
                selected: false,
                kind: .advice,
                keepsLogins: true
            ))
        }
        if let pixelmator = pixelmatorRecoveryCard(captures: captures) {
            rows.append(pixelmator)
        }

        let otherMedia = indexedHiddenMedia(excluding: capturePaths)
        let otherMediaBytes = otherMedia.reduce(Int64(0)) { $0 + $1.bytes }
        if !otherMedia.isEmpty {
            rows.append(JunkItem(
                id: "forensic-indexed-hidden-media",
                module: .junk,
                title: Line(ru: "Скрытое хранилище · все медиа", en: "Hidden storage · all media"),
                subtitle: Line(
                    ru: "\(otherMedia.count) изображений/видео найдены без каталога приложений · не всё является мусором · только аудит",
                    en: "\(otherMedia.count) images/videos found without an app catalogue · not all are junk · audit only"
                ),
                url: home.appendingPathComponent("Library"),
                bytes: otherMediaBytes,
                selected: false,
                kind: .advice,
                keepsLogins: true
            ))
        }

        for store in protectedStores() {
            switch access(to: store.url) {
            case .missing:
                continue
            case .denied:
                if store.id == "darwin-user-temporary-items",
                   let summary = finderCaptureSummary(in: store.url),
                   summary.files > 0,
                   summary.bytes > 0 {
                    rows.append(JunkItem(
                        id: "forensic-audit-\(store.id)",
                        module: .junk,
                        title: Line(
                            ru: "ScreenCaptureUI · найдено скрытое хранилище оригиналов",
                            en: "ScreenCaptureUI · hidden full-size capture store found"
                        ),
                        subtitle: Line(
                            ru: "\(summary.files) полных файлов (видео: \(summary.videos)) в \(summary.containers) NSIRD-контейнерах · Finder-аудит · для очистки нужен Полный доступ к диску",
                            en: "\(summary.files) full-size files (videos: \(summary.videos)) in \(summary.containers) NSIRD containers · Finder audit · Full Disk Access required to clean"
                        ),
                        url: store.url,
                        bytes: summary.bytes,
                        selected: false,
                        kind: .advice,
                        keepsLogins: true
                    ))
                    continue
                }
                let knownChildren = directoryChildLowerBound(store.url)
                let knownRU = knownChildren > 0 ? "метаданные видят минимум \(knownChildren) вложенных папок · " : ""
                let knownEN = knownChildren > 0 ? "metadata sees at least \(knownChildren) nested folders · " : ""
                let needsPrivilege = store.id.hasPrefix("document-revisions") || store.id == "root-trash"
                let accessRU = needsPrivilege
                    ? "нужен привилегированный read-only аудит (Full Disk Access недостаточно)"
                    : "нужен Полный доступ к диску"
                let accessEN = needsPrivilege
                    ? "a privileged read-only audit is required (Full Disk Access is insufficient)"
                    : "Full Disk Access required"
                rows.append(JunkItem(
                    id: "forensic-denied-\(store.id)",
                    module: .junk,
                    title: store.title,
                    subtitle: Line(
                        ru: "\(knownRU)macOS запретила чтение · содержимое и размер не считаются пустыми · \(accessRU)",
                        en: "\(knownEN)macOS denied reading · contents and size are not treated as empty · \(accessEN)"
                    ),
                    url: store.url,
                    bytes: 0,
                    selected: false,
                    kind: .advice,
                    keepsLogins: true
                ))
            case .readable:
                guard store.isThumbnailCache else { continue }
                let bytes = DiskSizer.duSK(store.url, timeout: 8) ?? 0
                guard bytes > 0 else { continue }
                rows.append(JunkItem(
                    id: "forensic-audit-\(store.id)",
                    module: .junk,
                    title: store.title,
                    subtitle: Line(
                        ru: "Превью существующих и уже удалённых файлов · не полноразмерные оригиналы · только аудит",
                        en: "Previews of existing and deleted files · not full-size originals · audit only"
                    ),
                    url: store.url,
                    bytes: bytes,
                    selected: false,
                    kind: .advice,
                    keepsLogins: true
                ))
            }
        }

        let coverage = deniedLibraryCoverage()
        if coverage.denied > 0 {
            rows.append(JunkItem(
                id: "forensic-denied-library-coverage",
                module: .junk,
                title: Line(
                    ru: "Скрытые папки macOS · неполное покрытие",
                    en: "macOS hidden folders · incomplete coverage"
                ),
                subtitle: Line(
                    ru: "macOS закрыла \(coverage.denied) из \(coverage.checked) проверенных хранилищ · они не считаются пустыми · нужен Полный доступ к диску",
                    en: "macOS denied \(coverage.denied) of \(coverage.checked) checked stores · they are not treated as empty · Full Disk Access required"
                ),
                url: home.appendingPathComponent("Library"),
                bytes: 0,
                selected: false,
                kind: .advice,
                keepsLogins: true
            ))
        }

        if let runtimeCoverage = runtimeTemporaryCoverageCard() {
            rows.append(runtimeCoverage)
        }

        CamLog.line(
            "forensic remnants indexedCaptures=\(captures.count) bytes=\(captureBytes) "
                + "otherMedia=\(otherMedia.count) otherBytes=\(otherMediaBytes) "
                + "deniedCoverage=\(coverage.denied)/\(coverage.checked) cards=\(rows.count)"
        )
        return rows.sorted { $0.bytes > $1.bytes }
    }

    static func isExplicitCard(_ item: JunkItem) -> Bool {
        guard item.kind == .advice, item.selected == false else { return false }
        if item.id == "forensic-indexed-screen-captures" {
            return canonicalPath(item.url) == canonicalPath(home.appendingPathComponent("Library"))
        }
        if item.id == "forensic-indexed-hidden-media" {
            return canonicalPath(item.url) == canonicalPath(home.appendingPathComponent("Library"))
        }
        if item.id == "forensic-denied-library-coverage" {
            return canonicalPath(item.url) == canonicalPath(home.appendingPathComponent("Library"))
        }
        if item.id == "forensic-runtime-temporary-coverage" {
            return SystemDeepScanner.tempRootURL.map { canonicalPath(item.url) == canonicalPath($0) } ?? false
        }
        if item.id == "forensic-pixelmator-recovery" {
            return canonicalPath(item.url) == canonicalPath(pixelmatorSessionRoot)
        }
        for store in protectedStores() {
            if item.id == "forensic-denied-\(store.id)" || item.id == "forensic-audit-\(store.id)" {
                return canonicalPath(item.url) == canonicalPath(store.url)
            }
        }
        return false
    }

    static func indexedHiddenCaptures() -> [IndexedCapture] {
        if let cached = cachedIndex(&captureIndexCache) { return cached }
        let query = "kMDItemIsScreenCapture == 1 || kMDItemImageIsScreenshot == 1"
        let ran = CamProcess.run(path: "/usr/bin/mdfind", arguments: ["-0", query], timeout: 10)
        guard !ran.timedOut else {
            CamLog.line("forensic capture metadata query timed out")
            return []
        }
        var seen = Set<String>()
        var rows: [IndexedCapture] = []
        for rawPath in ran.out.split(separator: "\0", omittingEmptySubsequences: true) {
            let url = URL(fileURLWithPath: String(rawPath))
            let path = canonicalPath(url)
            guard !seen.contains(path), isResidualContext(url),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey, .fileSizeKey
                  ]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            guard bytes > 0 else { continue }
            seen.insert(path)
            rows.append(IndexedCapture(url: url, bytes: bytes))
        }
        let sorted = rows.sorted { $0.bytes > $1.bytes }
        saveIndex(sorted, into: &captureIndexCache)
        return sorted
    }

    private static func indexedHiddenMedia(excluding excludedPaths: Set<String>) -> [IndexedCapture] {
        allIndexedHiddenMedia().filter { !excludedPaths.contains(canonicalPath($0.url)) }
    }

    /// Reused immediately by the similar-capture pass. The index is only a candidate
    /// source: every returned path is revalidated before image decoding or reporting.
    static func indexedHiddenMediaForCorrelation() -> [IndexedCapture] {
        allIndexedHiddenMedia()
    }

    private static func allIndexedHiddenMedia() -> [IndexedCapture] {
        if let cached = cachedIndex(&mediaIndexCache) { return cached }
        let query = "kMDItemContentTypeTree == 'public.image'cd || kMDItemContentTypeTree == 'public.movie'cd"
        let ran = CamProcess.run(path: "/usr/bin/mdfind", arguments: ["-0", query], timeout: 18)
        guard !ran.timedOut else {
            CamLog.line("forensic hidden-media metadata query timed out")
            return []
        }
        var seen = Set<String>()
        var rows: [IndexedCapture] = []
        for rawPath in ran.out.split(separator: "\0", omittingEmptySubsequences: true) {
            let url = URL(fileURLWithPath: String(rawPath))
            let path = canonicalPath(url)
            guard !seen.contains(path), isResidualContext(url),
                  let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey,
                    .fileAllocatedSizeKey, .fileSizeKey
                  ]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let bytes = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
            guard bytes > 0 else { continue }
            seen.insert(path)
            rows.append(IndexedCapture(url: url, bytes: bytes))
        }
        let sorted = rows.sorted { $0.bytes > $1.bytes }
        saveIndex(sorted, into: &mediaIndexCache)
        return sorted
    }

    private static func cachedIndex(_ slot: inout CachedIndex?) -> [IndexedCapture]? {
        indexLock.lock()
        defer { indexLock.unlock() }
        guard let cached = slot,
              Date().timeIntervalSince(cached.created) <= indexReuseSeconds else {
            slot = nil
            return nil
        }
        return cached.rows.filter { row in
            guard let facts = FileStorageFacts.read(row.url), !facts.isCloudPlaceholder else { return false }
            return facts.allocatedBytes > 0
        }
    }

    private static func saveIndex(_ rows: [IndexedCapture], into slot: inout CachedIndex?) {
        indexLock.lock()
        slot = CachedIndex(created: Date(), rows: rows)
        indexLock.unlock()
    }

    static func isResidualContextForQA(_ url: URL) -> Bool {
        isResidualContext(url)
    }

    static func hasMediaMagicForQA(_ data: Data) -> Bool {
        hasMediaMagic(data)
    }

    private static var pixelmatorSessionRoot: URL {
        home.appendingPathComponent(
            "Library/Containers/com.pixelmatorteam.pixelmator.x/Data/Library/Application Support/Pixelmator Pro/SessionData"
        )
    }

    /// Pixelmator keeps full layer payloads for crash recovery. They can outlive the
    /// source image and include screenshots that no longer exist in user folders, but
    /// deleting them blindly could destroy recovery of an unsaved document. Surface the
    /// exact store and physical size while keeping it permanently audit-only.
    private static func pixelmatorRecoveryCard(captures: [IndexedCapture]) -> JunkItem? {
        let root = pixelmatorSessionRoot
        guard let sessions = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: []
        ).filter({ url in
            guard Int(url.lastPathComponent) != nil,
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else {
                return false
            }
            return values.isDirectory == true && values.isSymbolicLink != true
        }), !sessions.isEmpty else { return nil }

        let rootPath = canonicalPath(root)
        let hiddenCaptures = captures.filter { canonicalPath($0.url).hasPrefix(rootPath + "/") }
        guard !hiddenCaptures.isEmpty else { return nil }
        let bytes = DiskSizer.duSK(root, timeout: 8) ?? hiddenCaptures.reduce(0) { $0 + $1.bytes }
        guard bytes > 0 else { return nil }

        var newest = Date.distantPast
        if let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isSymbolicLinkKey],
            options: [.skipsPackageDescendants]
        ) {
            var visited = 0
            for case let url as URL in enumerator {
                visited += 1
                if visited > 20_000 { break }
                guard let values = try? url.resourceValues(
                    forKeys: [.contentModificationDateKey, .isSymbolicLinkKey]
                ) else { continue }
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                newest = max(newest, values.contentModificationDate ?? .distantPast)
            }
        }
        let age = newest == .distantPast ? nil : max(0, Int(Date().timeIntervalSince(newest) / 86_400))
        let ageRU = age.map { " · последнее изменение: \($0) дн. назад" } ?? ""
        let ageEN = age.map { " · last modified \($0) days ago" } ?? ""
        return JunkItem(
            id: "forensic-pixelmator-recovery",
            module: .junk,
            title: Line(
                ru: "Pixelmator Pro · скрытые recovery-сессии",
                en: "Pixelmator Pro · hidden recovery sessions"
            ),
            subtitle: Line(
                ru: "\(sessions.count) сессий · полноразмерных снимков: \(hiddenCaptures.count)\(ageRU) · может восстанавливать несохранённый документ · только аудит",
                en: "\(sessions.count) sessions · full-size captures: \(hiddenCaptures.count)\(ageEN) · may recover an unsaved document · audit only"
            ),
            url: root,
            bytes: bytes,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    private static func protectedStores() -> [ProtectedStore] {
        var stores = [
            ProtectedStore(
                id: "document-revisions",
                title: Line(ru: "Версии удалённых документов macOS", en: "macOS deleted document versions"),
                url: URL(fileURLWithPath: "/System/Volumes/Data/.DocumentRevisions-V100"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "data-temporary-items",
                title: Line(ru: "Системные скрытые TemporaryItems", en: "System hidden TemporaryItems"),
                url: URL(fileURLWithPath: "/System/Volumes/Data/.TemporaryItems"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "root-trash",
                title: Line(
                    ru: "Скрытая корзина системного пользователя root",
                    en: "Hidden root-user Trash"
                ),
                url: URL(fileURLWithPath: "/private/var/root/.Trash"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "screen-capture-container",
                title: Line(ru: "Закрытое хранилище ScreenCapture", en: "Protected ScreenCapture storage"),
                url: home.appendingPathComponent("Library/Group Containers/group.com.apple.screencapture"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "replayd-container",
                title: Line(ru: "Закрытое хранилище записей replayd", en: "Protected replayd recording storage"),
                url: home.appendingPathComponent("Library/Group Containers/group.com.apple.replayd"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "quicktime-autosave",
                title: Line(ru: "Закрытые автосохранения QuickTime", en: "Protected QuickTime autosaves"),
                url: home.appendingPathComponent(
                    "Library/Containers/com.apple.QuickTimePlayerX/Data/Library/Autosave Information"
                ),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "user-autosave",
                title: Line(ru: "Закрытые автосохранения пользователя", en: "Protected user autosaves"),
                url: home.appendingPathComponent("Library/Autosave Information"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "icloud-file-provider",
                title: Line(ru: "iCloud Drive · локальные остатки удалённых файлов", en: "iCloud Drive · local deleted-file remnants"),
                url: home.appendingPathComponent("Library/Application Support/CloudDocs"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "file-provider",
                title: Line(ru: "Облачные диски · закрытое локальное хранилище", en: "Cloud drives · protected local storage"),
                url: home.appendingPathComponent("Library/Application Support/FileProvider"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "icloud-drive-group",
                title: Line(ru: "iCloud Drive · закрытый групповой контейнер", en: "iCloud Drive · protected group container"),
                url: home.appendingPathComponent("Library/Group Containers/group.com.apple.iCloudDrive"),
                isThumbnailCache: false
            ),
            ProtectedStore(
                id: "icloud-bird-group",
                title: Line(ru: "iCloud Drive · индекс синхронизации bird", en: "iCloud Drive · bird sync index"),
                url: home.appendingPathComponent("Library/Group Containers/com.apple.bird"),
                isThumbnailCache: false
            )
        ]
        let revisionsPerUser = URL(fileURLWithPath: "/System/Volumes/Data/.DocumentRevisions-V100/PerUID")
            .appendingPathComponent(String(getuid()))
        stores.append(ProtectedStore(
            id: "document-revisions-user-\(getuid())",
            title: Line(
                ru: "Версии документов текущего пользователя",
                en: "Current-user document versions"
            ),
            url: revisionsPerUser,
            isThumbnailCache: false
        ))
        if let temp = SystemDeepScanner.tempRootURL {
            let cacheRoot = temp.deletingLastPathComponent()
            let cache = cacheRoot
                .appendingPathComponent("C/com.apple.quicklook.ThumbnailsAgent/com.apple.QuickLook.thumbnailcache")
            stores.append(ProtectedStore(
                id: "quicklook-thumbnail-cache",
                title: Line(ru: "Quick Look · изображения удалённых файлов", en: "Quick Look · deleted-file images"),
                url: cache,
                isThumbnailCache: true
            ))
            stores.append(contentsOf: [
                ProtectedStore(
                    id: "darwin-user-temporary-items",
                    title: Line(ru: "Darwin · скрытые TemporaryItems пользователя", en: "Darwin · hidden user TemporaryItems"),
                    url: temp.appendingPathComponent("TemporaryItems"),
                    isThumbnailCache: false
                ),
                ProtectedStore(
                    id: "replayd-temporary-items",
                    title: Line(ru: "replayd · отброшенные записи экрана", en: "replayd · discarded screen recordings"),
                    url: temp.appendingPathComponent("com.apple.replayd/TemporaryItems"),
                    isThumbnailCache: false
                ),
                ProtectedStore(
                    id: "screencaptureui-temporary-items",
                    title: Line(ru: "ScreenCaptureUI · временные снимки и записи", en: "ScreenCaptureUI · temporary captures"),
                    url: temp.appendingPathComponent("com.apple.screencaptureui/TemporaryItems"),
                    isThumbnailCache: false
                ),
                ProtectedStore(
                    id: "fileprovider-temporary-items",
                    title: Line(ru: "FileProvider · временные удалённые файлы", en: "FileProvider · temporary deleted files"),
                    url: temp.appendingPathComponent("com.apple.fileproviderd/TemporaryItems"),
                    isThumbnailCache: false
                ),
                ProtectedStore(
                    id: "bird-temporary-items",
                    title: Line(ru: "iCloud bird · временные удалённые файлы", en: "iCloud bird · temporary deleted files"),
                    url: temp.appendingPathComponent("com.apple.bird/TemporaryItems"),
                    isThumbnailCache: false
                ),
                ProtectedStore(
                    id: "quicklook-temporary-items",
                    title: Line(ru: "Quick Look · временные изображения", en: "Quick Look · temporary images"),
                    url: temp.appendingPathComponent("com.apple.quicklook.ThumbnailsAgent/TemporaryItems"),
                    isThumbnailCache: false
                ),
                ProtectedStore(
                    id: "screencaptureui-cache-root",
                    title: Line(ru: "ScreenCaptureUI · системный скрытый cache-root", en: "ScreenCaptureUI · hidden system cache root"),
                    url: cacheRoot.appendingPathComponent("C/com.apple.screencaptureui"),
                    isThumbnailCache: false
                )
            ])
        }
        return stores
    }

    private static func directoryChildLowerBound(_ url: URL) -> Int {
        var info = stat()
        let status = url.path.withCString { lstat($0, &info) }
        guard status == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return 0 }
        return max(0, Int(info.st_nlink) - 2)
    }

    /// Discover every per-process `TemporaryItems` store under the current Darwin token,
    /// including services unknown to this build. Metadata-only lower bounds still work when
    /// TCC denies directory enumeration, so a whole class of runtime storage cannot vanish.
    private static func runtimeTemporaryCoverageCard() -> JunkItem? {
        guard let temp = SystemDeepScanner.tempRootURL,
              let children = try? FileManager.default.contentsOfDirectory(
                at: temp,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
              ) else { return nil }
        var candidates = [temp.appendingPathComponent("TemporaryItems")]
        candidates.append(contentsOf: children.map { $0.appendingPathComponent("TemporaryItems") })
        var seen = Set<String>()
        var stores = 0
        var denied = 0
        var lowerBound = 0
        for url in candidates {
            let path = canonicalPath(url)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            var info = stat()
            guard url.path.withCString({ lstat($0, &info) }) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { continue }
            stores += 1
            lowerBound += max(0, Int(info.st_nlink) - 2)
            if case .denied = access(to: url) { denied += 1 }
        }
        guard stores > 0, denied > 0 else { return nil }
        return JunkItem(
            id: "forensic-runtime-temporary-coverage",
            module: .junk,
            title: Line(
                ru: "Все runtime TemporaryItems · покрытие",
                en: "All runtime TemporaryItems · coverage"
            ),
            subtitle: Line(
                ru: "Найдено \(stores) хранилищ, закрыто macOS: \(denied), метаданные видят минимум \(lowerBound) вложенных папок · ничего не считается пустым",
                en: "Found \(stores) stores, macOS denied \(denied), metadata sees at least \(lowerBound) nested folders · none are treated as empty"
            ),
            url: temp,
            bytes: 0,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
    }

    /// Finder can enumerate this user-owned TCC container even when direct filesystem calls
    /// are denied. The bridge is audit-only: cleanup still requires Full Disk Access and a
    /// fresh file-by-file validation by `HiddenCaptureScanner`.
    private static func finderCaptureSummary(in root: URL) -> FinderCaptureSummary? {
        let lines = [
            "on run argv",
            "tell application \"Finder\"",
            "set f to (POSIX file (item 1 of argv) as alias)",
            "set mediaExt to {\"png\", \"jpg\", \"jpeg\", \"heic\", \"tiff\", \"gif\", \"webp\", \"avif\", \"mov\", \"mp4\", \"m4v\", \"webm\"}",
            "set videoExt to {\"mov\", \"mp4\", \"m4v\", \"webm\"}",
            "set dirCount to 0",
            "set fileCount to 0",
            "set videoCount to 0",
            "set byteCount to 0",
            "repeat with dr in (get every item of f)",
            "set d to contents of dr",
            "if (name of d) starts with \"NSIRD_screencaptureui_\" then",
            "set dirCount to dirCount + 1",
            "repeat with yr in (get every item of d)",
            "set y to contents of yr",
            "set ext to name extension of y",
            "if ext is in mediaExt then",
            "set fileCount to fileCount + 1",
            "set byteCount to byteCount + (size of y)",
            "if ext is in videoExt then set videoCount to videoCount + 1",
            "end if",
            "end repeat",
            "end if",
            "end repeat",
            "return (dirCount as text) & \"|\" & (fileCount as text) & \"|\" & (videoCount as text) & \"|\" & (byteCount as text)",
            "end tell",
            "end run"
        ]
        var arguments: [String] = []
        for line in lines {
            arguments.append("-e")
            arguments.append(line)
        }
        arguments.append(root.path)
        let ran = CamProcess.run(path: "/usr/bin/osascript", arguments: arguments, timeout: 8)
        guard !ran.timedOut else { return nil }
        let fields = ran.out.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard fields.count == 4,
              let containers = Int(fields[0]),
              let files = Int(fields[1]),
              let videos = Int(fields[2]),
              let bytes = Int64(fields[3]) else { return nil }
        CamLog.line(
            "Finder NSIRD audit containers=\(containers) files=\(files) videos=\(videos) bytes=\(bytes)"
        )
        return FinderCaptureSummary(
            containers: containers,
            files: files,
            videos: videos,
            bytes: bytes
        )
    }

    /// TCC can expose a container name while denying its contents. Probe every immediate
    /// Library store plus every app/group container boundary so a denied subtree can never
    /// silently turn into a zero-byte result. This is coverage accounting, not deletion.
    private static func deniedLibraryCoverage() -> (checked: Int, denied: Int) {
        let fm = FileManager.default
        let library = home.appendingPathComponent("Library")
        let containerRoots = [
            library,
            library.appendingPathComponent("Application Support"),
            library.appendingPathComponent("Containers"),
            library.appendingPathComponent("Group Containers"),
            library.appendingPathComponent("CloudStorage")
        ]
        var candidates: [URL] = []
        for root in containerRoots {
            guard let children = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: []
            ) else { continue }
            candidates.append(contentsOf: children)
            if root.lastPathComponent == "Containers" {
                candidates.append(contentsOf: children.map { $0.appendingPathComponent("Data") })
            }
        }
        var seen = Set<String>()
        var checked = 0
        var denied = 0
        for url in candidates {
            let path = url.standardizedFileURL.path
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            switch access(to: url) {
            case .readable:
                checked += 1
            case .denied:
                checked += 1
                denied += 1
            case .missing:
                continue
            }
        }
        return (checked, denied)
    }

    private static func access(to url: URL) -> Access {
        var info = stat()
        errno = 0
        let status = url.path.withCString { lstat($0, &info) }
        if status != 0 {
            return errno == EPERM || errno == EACCES ? .denied : .missing
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { return .missing }
        errno = 0
        guard let directory = url.path.withCString({ opendir($0) }) else {
            return errno == EPERM || errno == EACCES ? .denied : .missing
        }
        closedir(directory)
        return .readable
    }

    private static func isResidualContext(_ url: URL) -> Bool {
        let path = canonicalPath(url)
        let homePath = canonicalPath(home)
        if path.hasPrefix(homePath + "/") {
            let relative = String(path.dropFirst(homePath.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            if components.first == "Library" { return true }
            return components.contains { $0.hasPrefix(".") && $0 != "." && $0 != ".." }
        }
        if path.hasPrefix("/private/") { return true }
        if path.hasPrefix("/System/Volumes/Data/.") { return true }
        return path.contains("/.Trashes/") || path.contains("/.Trash/")
    }

    private static func hasMediaMagic(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(32))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if bytes.starts(with: Array("GIF8".utf8)) { return true }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) {
            return true
        }
        if bytes.count >= 12,
           Array(bytes[0..<4]) == Array("RIFF".utf8),
           Array(bytes[8..<12]) == Array("WEBP".utf8) { return true }
        if bytes.count >= 12, Array(bytes[4..<8]) == Array("ftyp".utf8) { return true }
        return false
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
