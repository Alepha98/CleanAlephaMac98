import Darwin
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum QAHarness {
    static func pulse() -> Never {
        CamLog.line("qa pulse begin")
        let t0 = Date()
        let mem = LiveProbe.pulseMemory()
        CamLog.line("qa pulse mem used=\(mem.used) total=\(mem.total) swap=\(mem.swap) cpu=\(Int(mem.cpuBusy)) load=\(String(format: "%.2f", mem.loadAvg)) pressure=\(mem.pressure.rawValue) apps=\(mem.apps.count)")
        for app in mem.apps.prefix(8) {
            CamLog.line("qa pulse app \(app.name) bytes=\(app.bytes) cpu=\(String(format: "%.1f", app.cpu)) kids=\(app.children.count)")
        }
        let cards = LiveProbe.junk(fromMemory: mem)
        CamLog.line("qa pulse ram-cards=\(cards.count)")
        let tabs = LiveProbe.pulseTabs(into: mem)
        CamLog.line("qa pulse tabs=\(tabs.tabs.count) note=\(tabs.tabAccess?.en ?? "none")")
        CamLog.line("qa pulse ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-pulse ok apps=\(mem.apps.count) tabs=\(tabs.tabs.count) cards=\(cards.count)\n".utf8))
        exit(0)
    }

    static func protect() -> Never {
        CamLog.line("qa protect begin")
        let t0 = Date()
        let rows = LiveProbe.junkProtect()
        CamLog.line("qa protect items=\(rows.count)")
        for row in rows.prefix(12) {
            CamLog.line("qa protect \(row.id) bytes=\(row.bytes) kind-sel=\(row.selected)")
        }
        CamLog.line("qa protect ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-protect ok items=\(rows.count)\n".utf8))
        exit(0)
    }

    static func startup() -> Never {
        CamLog.line("qa startup begin")
        let t0 = Date()
        let rows = LiveProbe.junkStartup()
        CamLog.line("qa startup items=\(rows.count)")
        for row in rows.prefix(20) {
            CamLog.line("qa startup \(row.title.ru) kind-advice=\(row.kind == .advice)")
        }
        CamLog.line("qa startup ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-startup ok items=\(rows.count)\n".utf8))
        exit(0)
    }

    static func keep() -> Never {
        CamLog.line("qa keep begin")
        var present = 0
        for item in Keep.builtinCatalog() {
            let exists = FileManager.default.fileExists(atPath: item.url.path)
            if exists { present += 1 }
            CamLog.line("qa keep \(item.name) exists=\(exists) \(item.url.path)")
        }
        CamLog.line("qa keep extras=\(Keep.extraPaths.count) present=\(present)")
        FileHandle.standardOutput.write(Data("qa-keep ok present=\(present)\n".utf8))
        exit(0)
    }

    static func artifacts() -> Never {
        CamLog.line("qa artifacts begin")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old14 = now.addingTimeInterval(-15 * 86_400)
        let old30 = now.addingTimeInterval(-31 * 86_400)
        let old2 = now.addingTimeInterval(-3 * 86_400)
        let recent = now.addingTimeInterval(-86_400)

        let cases: [(String, ArtifactScanner.Match?, ArtifactScanner.Match?)] = [
            ("old screenshot", ArtifactScanner.classify(name: "Screenshot 2025-01-01 at 10.00.00.png", modified: old14, origins: [], isDownloads: false, now: now), .screenshot),
            ("recent screenshot", ArtifactScanner.classify(name: "Снимок экрана 2026-01-01.png", modified: recent, origins: [], isDownloads: false, now: now), nil),
            ("chatgpt origin", ArtifactScanner.classify(name: "image.png", modified: old14, origins: ["https://chatgpt.com/backend-api/files/1"], isDownloads: true, now: now), .aiOutput),
            ("claude filename", ArtifactScanner.classify(name: "Claude export.pdf", modified: old14, origins: [], isDownloads: true, now: now), .aiOutput),
            ("gemini origin", ArtifactScanner.classify(name: "image (2).png", modified: old14, origins: ["https://gemini.google.com/share/1"], isDownloads: true, now: now), .aiOutput),
            ("generic output", ArtifactScanner.classify(name: "output (4).pdf", modified: old30, origins: [], isDownloads: true, now: now), .genericOutput),
            ("source is not output", ArtifactScanner.classify(name: "output.swift", modified: old30, origins: [], isDownloads: true, now: now), nil),
            ("ordinary photo", ArtifactScanner.classify(name: "family holiday.jpg", modified: old30, origins: [], isDownloads: true, now: now), nil),
            ("partial download", ArtifactScanner.classify(name: "archive.zip.crdownload", modified: old2, origins: [], isDownloads: true, now: now), .incompleteDownload),
            ("aria partial", ArtifactScanner.classify(name: "model.bin.aria2", modified: old2, origins: [], isDownloads: true, now: now), .incompleteDownload)
        ]

        var failures: [String] = []
        for (name, actual, expected) in cases where actual != expected {
            failures.append("\(name): got=\(String(describing: actual)) expected=\(String(describing: expected))")
        }

        let partialURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/archive.zip.crdownload")
        let partialCard = JunkItem(
            id: "artifact-file-qa-partial",
            module: .junk,
            title: Line.proper(partialURL.lastPathComponent),
            subtitle: Line.proper("Incomplete download"),
            url: partialURL,
            bytes: 1_048_576,
            selected: false,
            kind: .deleteItem,
            keepsLogins: false
        )
        if !partialCard.isSafePreset || partialCard.cleanupGuide.disposition != .safe {
            failures.append("incomplete download is missing from Safe selection")
        }
        if !partialCard.cleanupGuide.what.ru.localizedCaseInsensitiveContains("недокачан")
            || !partialCard.cleanupGuide.effect.en.localizedCaseInsensitiveContains("unfinished") {
            failures.append("incomplete download has no specific plain-language guide")
        }
        let opaqueURL = URL(fileURLWithPath: "/private/var/folders/qa/T/com.google.Chrome.helper.plugin")
        let opaqueCard = JunkItem(
            id: "darwin-cache-qa-copy",
            module: .junk,
            title: Line(ru: "Системный cache · \(opaqueURL.lastPathComponent)", en: "System cache · \(opaqueURL.lastPathComponent)"),
            subtitle: Line.proper("QA"),
            url: opaqueURL,
            bytes: 1,
            selected: false,
            kind: .deleteItem,
            keepsLogins: true
        )
        if opaqueCard.userFacingTitle.ru.contains(opaqueURL.lastPathComponent)
            || !opaqueCard.userFacingTitle.en.contains("Google Chrome") {
            failures.append("opaque bundle id was not converted to a human title")
        }
        let adviceCard = JunkItem(
            id: "system-audit-qa-copy",
            module: .junk,
            title: Line.proper("System store"),
            subtitle: Line.proper("QA"),
            url: URL(fileURLWithPath: "/private/var/log"),
            bytes: 1,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
        if adviceCard.cleanupGuide.disposition != .readOnly
            || adviceCard.cleanupGuide.what.ru.isEmpty
            || adviceCard.cleanupGuide.effect.en.isEmpty {
            failures.append("read-only card is missing plain-language guidance")
        }
        let manualCard = JunkItem(
            id: "artifact-file-qa-manual",
            module: .junk,
            title: Line.proper("Screenshot to keep.png"),
            subtitle: Line.proper("QA"),
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Desktop/Screenshot to keep.png"),
            bytes: 2,
            selected: true,
            kind: .deleteItem,
            keepsLogins: false
        )
        var selectionFixture = [partialCard, manualCard, adviceCard]
        AppState.applySafeSelection(
            to: &selectionFixture,
            visibleIDs: Set(selectionFixture.map(\.id))
        )
        if selectionFixture[0].selected != true
            || selectionFixture[1].selected != true
            || selectionFixture[2].selected != false {
            failures.append("Safe selection did not add safe items while preserving manual choices")
        }
        let dotCacheURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/codex-runtimes")
        let dotCacheCard = JunkItem(
            id: "dotcache-codex-runtimes",
            module: .junk,
            title: Line.proper("~/.cache/codex-runtimes"),
            subtitle: Line.proper("QA"),
            url: dotCacheURL,
            bytes: 1,
            selected: false,
            kind: .wipeChildren,
            keepsLogins: true
        )
        if dotCacheCard.userFacingTitle.ru.contains("~/.cache")
            || !dotCacheCard.userFacingTitle.en.localizedCaseInsensitiveContains("Codex") {
            failures.append("dot-cache title still exposes a technical path")
        }
        let gitCard = JunkItem(
            id: "hidden-tree-audit-qa-copy",
            module: .junk,
            title: Line(ru: "Скрытые данные · .git", en: "Hidden data · .git"),
            subtitle: Line.proper("QA"),
            url: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Projects/example/.git"),
            bytes: 1,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
        if gitCard.userFacingTitle.ru.contains(".git")
            || !gitCard.cleanupGuide.what.ru.localizedCaseInsensitiveContains("истори") {
            failures.append("hidden source-control data is not explained in plain language")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let broadURL = home.appendingPathComponent("Library/Application Support/Telegram Desktop/tdata/user_data")
        let cacheURL = broadURL.appendingPathComponent("cache")
        let broad = JunkItem(
            id: "tgdesk",
            module: .messengers,
            title: Line.proper("Telegram broad data"),
            subtitle: Line.proper("unsafe"),
            url: broadURL,
            bytes: 1,
            selected: true,
            kind: .wipeChildren,
            keepsLogins: false
        )
        let cache = JunkItem(
            id: "tgdesk-cache-user_data",
            module: .messengers,
            title: Line.proper("Telegram cache"),
            subtitle: Line.proper("safe boundary"),
            url: cacheURL,
            bytes: 1,
            selected: true,
            kind: .wipeChildren,
            keepsLogins: true
        )
        if !Keep.isProtected(broadURL) { failures.append("Telegram tdata must be protected") }
        if Keep.allowsExplicitCard(broad) { failures.append("broad Telegram user_data bypassed protection") }
        if !Keep.allowsExplicitCard(cache) { failures.append("narrow Telegram cache card rejected") }
        if !Janitor.clean(broad).failed { failures.append("janitor accepted broad Telegram user_data") }
        if SessionGuard.ownerName(for: cacheURL) != "Telegram" {
            failures.append("Telegram cache has no owning-app guard")
        }
        let zoomData = home.appendingPathComponent("Library/Application Support/zoom.us/data")
        if !Keep.isProtected(zoomData) || SessionGuard.ownerName(for: zoomData) != "Zoom" {
            failures.append("Zoom session data is not guarded")
        }
        if !Keep.names.contains("key_datas") || !Keep.names.contains("Session Storage") {
            failures.append("session guard names missing")
        }
        let savedState = JunkItem(
            id: "state",
            module: .junk,
            title: Line.proper("Saved Application State"),
            subtitle: Line.proper("off"),
            url: home.appendingPathComponent("Library/Saved Application State"),
            bytes: 1,
            selected: false,
            kind: .wipeChildren,
            keepsLogins: false
        )
        if savedState.isSafePreset {
            failures.append("safe preset re-enabled saved application state")
        }
        let httpStorage = home.appendingPathComponent("Library/HTTPStorages/com.example.app")
        if !Keep.isProtected(httpStorage) {
            failures.append("HTTPStorages cookies/session state must be protected")
        }
        let cloudSession = home.appendingPathComponent("Library/Application Support/CloudDocs/session/temp")
        if !Keep.isProtected(cloudSession) {
            failures.append("iCloud session state must be protected")
        }
        let actualTelegram = Scanner.safeItems(for: .messengers).items
        if actualTelegram.contains(where: { $0.url.standardizedFileURL.path == broadURL.standardizedFileURL.path }) {
            failures.append("messenger scan exposed broad Telegram user_data")
        }
        if actualTelegram.contains(where: {
            $0.id.hasPrefix("tgdesk-")
                && !Keep.isTelegramDesktopCache($0.url)
        }) {
            failures.append("messenger scan exposed a non-cache Telegram Desktop path")
        }
        let numberedCache = home.appendingPathComponent(
            "Library/Application Support/Telegram Desktop/tdata/user_data#2/cache"
        )
        let fakeBroadNumbered = home.appendingPathComponent(
            "Library/Application Support/Telegram Desktop/tdata/user_data#2"
        )
        if !Keep.isTelegramDesktopCache(numberedCache)
            || Keep.isTelegramDesktopCache(fakeBroadNumbered) {
            failures.append("numbered Telegram Desktop cache boundary failed")
        }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("cam98-exact-duplicates-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let edge = Data(repeating: 0x41, count: 64 * 1024)
            let one = edge + Data(repeating: 0x42, count: 64 * 1024) + edge
            let two = edge + Data(repeating: 0x43, count: 64 * 1024) + edge
            let a = temp.appendingPathComponent("a.bin")
            let b = temp.appendingPathComponent("b.bin")
            let copy = temp.appendingPathComponent("copy.bin")
            try one.write(to: a)
            try two.write(to: b)
            try one.write(to: copy)
            let aSig = Scanner.contentSignature(a, size: Int64(one.count))
            let bSig = Scanner.contentSignature(b, size: Int64(two.count))
            let copySig = Scanner.contentSignature(copy, size: Int64(one.count))
            if aSig == bSig { failures.append("duplicate hash ignored different file middle") }
            if aSig != copySig { failures.append("duplicate hash rejected exact copy") }
        } catch {
            failures.append("duplicate hash fixture failed: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-artifacts ok cases=\(cases.count) telegram=protected\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa artifacts FAIL \(failure)") }
        FileHandle.standardError.write(Data("qa-artifacts failed: \(failures.joined(separator: "; "))\n".utf8))
        exit(2)
    }

    static func artifactScan() -> Never {
        let started = Date()
        let rows = ArtifactScanner.items()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        for row in rows.prefix(20) {
            CamLog.line("qa artifact card \(row.id) bytes=\(row.bytes) selected=\(row.selected) path=\(PathFormat.tilde(row.url))")
        }
        FileHandle.standardOutput.write(Data("qa-artifact-scan ok items=\(rows.count) ms=\(ms)\n".utf8))
        exit(0)
    }

    static func junk() -> Never {
        let started = Date()
        let chunk = Scanner.safeItems(for: .junk)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        FileHandle.standardOutput.write(Data("qa-junk ok items=\(chunk.items.count) failed=\(chunk.failed) ms=\(ms)\n".utf8))
        exit(0)
    }

    static func systemDeep() -> Never {
        CamLog.line("qa system-deep begin")
        var failures: [String] = []
        let fm = FileManager.default
        let now = Date()

        guard let cacheRoot = SystemDeepScanner.cacheRootURL,
              let tempRoot = SystemDeepScanner.tempRootURL else {
            FileHandle.standardError.write(Data("qa-system-deep failed: Darwin runtime roots unavailable\n".utf8))
            exit(2)
        }

        func runtimeItem(id: String, url: URL, kind: CleanKind = .deleteItem) -> JunkItem {
            JunkItem(
                id: id,
                module: .junk,
                title: Line.proper("QA runtime"),
                subtitle: Line.proper("QA only"),
                url: url,
                bytes: 1,
                selected: false,
                kind: kind,
                keepsLogins: true
            )
        }

        let cacheChild = cacheRoot.appendingPathComponent("com.example.qa")
        let validShape = runtimeItem(id: "darwin-cache-qa", url: cacheChild)
        if !SystemDeepScanner.isExplicitRuntimeCard(validShape) {
            failures.append("immediate current-user cache child rejected")
        }
        if !Keep.isProtected(cacheChild) || !Keep.allowsExplicitCard(validShape) {
            failures.append("deep runtime boundary is not protected/explicit")
        }
        let rootCard = runtimeItem(id: "darwin-cache-root", url: cacheRoot)
        if SystemDeepScanner.isExplicitRuntimeCard(rootCard) {
            failures.append("Darwin cache root accepted for deletion")
        }
        let nested = runtimeItem(id: "darwin-cache-nested", url: cacheChild.appendingPathComponent("nested"))
        if SystemDeepScanner.isExplicitRuntimeCard(nested) {
            failures.append("nested arbitrary Darwin path accepted")
        }
        let foreign = runtimeItem(id: "darwin-temp-foreign", url: URL(fileURLWithPath: "/tmp/cam98-foreign"))
        if SystemDeepScanner.isExplicitRuntimeCard(foreign) || !Janitor.clean(foreign).failed {
            failures.append("foreign temp path crossed Janitor boundary")
        }
        let devMount = URL(fileURLWithPath: "/dev", isDirectory: true)
        if FileManager.default.fileExists(atPath: devMount.path),
           !SystemDeepScanner.isMountPointForQA(devMount) {
            failures.append("mounted filesystem was not recognized")
        }

        let audit = runtimeItem(
            id: "system-audit-var-log",
            url: URL(fileURLWithPath: "/private/var/log"),
            kind: .advice
        )
        if !Keep.isProtected(audit.url) || !Keep.allowsExplicitCard(audit) || audit.isSafePreset {
            failures.append("read-only system audit invariants failed")
        }
        let fakeAuditDelete = runtimeItem(
            id: "system-audit-var-log",
            url: URL(fileURLWithPath: "/private/var/log"),
            kind: .deleteItem
        )
        if Keep.allowsExplicitCard(fakeAuditDelete) || !Janitor.clean(fakeAuditDelete).failed {
            failures.append("system audit path became writable")
        }

        let fixture = tempRoot.appendingPathComponent("cam98-qa-deep-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: fixture, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: fixture) }
            let payload = fixture.appendingPathComponent("payload.bin")
            try Data([0x43, 0x41, 0x4d]).write(to: payload)
            let old = now.addingTimeInterval(-20 * 86_400)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: payload.path)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: fixture.path)
            if !SystemDeepScanner.isOldSafeTreeForQA(fixture, area: .temporary, now: now) {
                failures.append("old regular temp fixture rejected")
            }

            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            holder.arguments = ["-f", payload.path]
            holder.standardOutput = FileHandle.nullDevice
            holder.standardError = FileHandle.nullDevice
            try holder.run()
            Thread.sleep(forTimeInterval: 0.12)
            let heldItem = runtimeItem(id: "darwin-temp-held", url: fixture)
            if SystemDeepScanner.blockingProcessName(for: heldItem) == nil {
                failures.append("open deep-runtime file was not blocked")
            }
            holder.terminate()
            holder.waitUntilExit()

            let link = fixture.appendingPathComponent("pointer")
            try fm.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/tmp"))
            let validationFuture = now.addingTimeInterval(30 * 86_400)
            if SystemDeepScanner.isOldSafeTreeForQA(fixture, area: .temporary, now: validationFuture) {
                failures.append("symlink-containing tree accepted")
            }
            try fm.removeItem(at: link)
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: payload.lastPathComponent)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: fixture.path)
            if !SystemDeepScanner.isOldSafeTreeForQA(fixture, area: .temporary, now: validationFuture) {
                failures.append("tree with contained symlink rejected")
            }
            try fm.removeItem(at: link)
            try fm.setAttributes([.modificationDate: now], ofItemAtPath: payload.path)
            if SystemDeepScanner.isOldSafeTreeForQA(fixture, area: .temporary, now: now) {
                failures.append("recently modified tree accepted")
            }
        } catch {
            failures.append("runtime fixture failed: \(error.localizedDescription)")
        }

        if let sharedTemp = SystemDeepScanner.sharedTempRootURL {
            let sharedFixture = sharedTemp.appendingPathComponent("cam98-qa-shared-\(UUID().uuidString)")
            do {
                try fm.createDirectory(at: sharedFixture, withIntermediateDirectories: false)
                defer { try? fm.removeItem(at: sharedFixture) }
                let payload = sharedFixture.appendingPathComponent("render.png")
                try Data([0x89, 0x50, 0x4E, 0x47]).write(to: payload)
                let old = now.addingTimeInterval(-2 * 86_400)
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: payload.path)
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: sharedFixture.path)
                let sharedCard = runtimeItem(id: "private-tmp-qa", url: sharedFixture)
                if !SystemDeepScanner.isExplicitRuntimeCard(sharedCard)
                    || !SystemDeepScanner.isOldSafeTreeForQA(
                        sharedFixture,
                        area: .sharedTemporary,
                        now: now
                    )
                    || !Keep.isProtected(sharedFixture)
                    || !Keep.allowsExplicitCard(sharedCard) {
                    failures.append("current-user /private/tmp boundary failed")
                }
                let nested = runtimeItem(
                    id: "private-tmp-nested",
                    url: sharedFixture.appendingPathComponent("nested")
                )
                if SystemDeepScanner.isExplicitRuntimeCard(nested) {
                    failures.append("arbitrary nested /private/tmp target accepted")
                }
            } catch {
                failures.append("shared temp fixture failed: \(error.localizedDescription)")
            }
        }

        let started = Date()
        let rows = SystemDeepScanner.items(now: now)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        for row in rows {
            if row.selected { failures.append("deep card selected by default: \(row.id)") }
            if row.kind == .advice, row.isSafePreset {
                failures.append("advice entered Safe preset: \(row.id)")
            }
            if row.id.hasPrefix("darwin-") && !SystemDeepScanner.isExplicitRuntimeCard(row) {
                failures.append("runtime scan escaped exact child: \(row.url.path)")
            }
            if row.id.hasPrefix("private-tmp-") && !SystemDeepScanner.isExplicitRuntimeCard(row) {
                failures.append("shared runtime scan escaped safe current-user target: \(row.url.path)")
            }
            if row.id.hasPrefix("system-audit-") && !SystemDeepScanner.isSystemAuditCard(row) {
                failures.append("unrecognized audit card: \(row.id)")
            }
            if row.id == "system-audit-storage-ledger", row.reclaimableBytes != 0 {
                failures.append("macOS-managed storage leaked into cleanup total")
            }
            CamLog.line("qa system-deep card \(row.id) bytes=\(row.bytes) kind=\(row.kind) path=\(row.url.path)")
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-system-deep ok items=\(rows.count) ms=\(ms)\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa system-deep FAIL \(failure)") }
        FileHandle.standardError.write(Data("qa-system-deep failed: \(failures.joined(separator: "; "))\n".utf8))
        exit(2)
    }

    static func hiddenCaptures() -> Never {
        CamLog.line("qa hidden-captures begin")
        var failures: [String] = []
        let fm = FileManager.default

        let classifications: [(String, Bool, Bool)] = [
            ("named screenshot", HiddenCaptureScanner.isCaptureForQA(
                name: "Screenshot 2026-08-27 at 12.00.00.png",
                contentType: .png,
                dedicatedRoot: false,
                hasCaptureMetadata: false,
                temporaryPathMarker: false
            ), true),
            ("metadata screenshot", HiddenCaptureScanner.isCaptureForQA(
                name: "random.png",
                contentType: .png,
                dedicatedRoot: false,
                hasCaptureMetadata: true,
                temporaryPathMarker: false
            ), true),
            ("ordinary temp image", HiddenCaptureScanner.isCaptureForQA(
                name: "random.png",
                contentType: .png,
                dedicatedRoot: false,
                hasCaptureMetadata: false,
                temporaryPathMarker: false
            ), false),
            ("uuid recording in dedicated root", HiddenCaptureScanner.isCaptureForQA(
                name: "9B13F20E.mov",
                contentType: .quickTimeMovie,
                dedicatedRoot: true,
                hasCaptureMetadata: false,
                temporaryPathMarker: false
            ), true),
            ("non-media file", HiddenCaptureScanner.isCaptureForQA(
                name: "Screenshot.plist",
                contentType: .propertyList,
                dedicatedRoot: true,
                hasCaptureMetadata: true,
                temporaryPathMarker: true
            ), false)
        ]
        for (name, actual, expected) in classifications where actual != expected {
            failures.append("classification \(name) got=\(actual) expected=\(expected)")
        }

        let pngHeader = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        if !HiddenCaptureScanner.isTelegramTemporaryMediaForQA(
            name: "-1521383608655729046",
            header: pngHeader,
            quarantine: "0081;6a905b85;Telegram;"
        ) {
            failures.append("extensionless Telegram PNG rejected")
        }
        if HiddenCaptureScanner.isTelegramTemporaryMediaForQA(
            name: "-1521383608655729046",
            header: pngHeader,
            quarantine: "0081;6a905b85;Safari;"
        ) {
            failures.append("foreign extensionless temp PNG accepted as Telegram")
        }
        if HiddenCaptureScanner.isTelegramTemporaryMediaForQA(
            name: "ordinary.png",
            header: pngHeader,
            quarantine: "0081;6a905b85;Telegram;"
        ) {
            failures.append("named Telegram image accepted as numeric temp media")
        }

        guard let tempRoot = SystemDeepScanner.tempRootURL else {
            FileHandle.standardError.write(Data("qa-hidden-captures failed: Darwin temp unavailable\n".utf8))
            exit(2)
        }
        let darwinRoots = HiddenCaptureScanner.darwinTemporaryRootsForQA()
        func darwinKey(_ url: URL) -> String {
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            return path.hasPrefix("/private/var/") ? String(path.dropFirst("/private".count)) : path
        }
        let canonicalDarwinRoots = darwinRoots.map(darwinKey)
        let canonicalActiveRoot = darwinKey(tempRoot)
        if canonicalDarwinRoots.first != canonicalActiveRoot
            || Set(canonicalDarwinRoots).count != canonicalDarwinRoots.count
            || canonicalDarwinRoots.contains(where: { !$0.hasPrefix("/var/folders/") }) {
            failures.append("owned Darwin temp-root discovery boundary failed")
        }
        let capture = tempRoot.appendingPathComponent("Screenshot cam98-qa-\(UUID().uuidString).png")
        let ordinary = tempRoot.appendingPathComponent("cam98-qa-ordinary-\(UUID().uuidString).png")
        do {
            try Data(repeating: 0x50, count: 20_000).write(to: capture)
            try Data(repeating: 0x4e, count: 20_000).write(to: ordinary)
            defer {
                try? fm.removeItem(at: capture)
                try? fm.removeItem(at: ordinary)
            }
            let future = Date().addingTimeInterval(3 * 3_600)
            if !HiddenCaptureScanner.isEligibleDarwinFileForQA(capture, now: future) {
                failures.append("old named Darwin screenshot fixture rejected")
            }
            if HiddenCaptureScanner.isEligibleDarwinFileForQA(ordinary, now: future) {
                failures.append("ordinary Darwin temp image accepted")
            }
            if HiddenCaptureScanner.isEligibleDarwinFileForQA(capture, now: Date()) {
                failures.append("fresh screenshot fixture accepted")
            }

            let card = JunkItem(
                id: "hidden-capture-darwin-temp",
                module: .junk,
                title: Line.proper("Hidden capture QA"),
                subtitle: Line.proper("QA"),
                url: tempRoot,
                bytes: 20_000,
                selected: false,
                kind: .deleteCaptureRemnants,
                keepsLogins: false
            )
            if !HiddenCaptureScanner.isExplicitCard(card)
                || !Keep.isProtected(tempRoot)
                || !Keep.allowsExplicitCard(card)
                || card.isSafePreset {
                failures.append("hidden capture card safety boundary failed")
            }
            let nested = JunkItem(
                id: card.id,
                module: card.module,
                title: card.title,
                subtitle: card.subtitle,
                url: capture,
                bytes: card.bytes,
                selected: false,
                kind: card.kind,
                keepsLogins: false
            )
            if HiddenCaptureScanner.isExplicitCard(nested) {
                failures.append("capture card accepted a substituted target")
            }
            if !Janitor.clean(nested).failed {
                failures.append("Janitor accepted a substituted capture target")
            }

            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            holder.arguments = ["-f", capture.path]
            holder.standardOutput = FileHandle.nullDevice
            holder.standardError = FileHandle.nullDevice
            try holder.run()
            Thread.sleep(forTimeInterval: 0.12)
            if HiddenCaptureScanner.blockingProcessName(for: card, now: future) == nil {
                failures.append("open hidden screenshot was not blocked")
            }
            holder.terminate()
            holder.waitUntilExit()
        } catch {
            failures.append("hidden capture fixture failed: \(error.localizedDescription)")
        }

        let started = Date()
        let rows = HiddenCaptureScanner.items()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        for row in rows {
            let expectedSafe = row.id.hasPrefix("hidden-container-temporary-")
            if row.selected || row.isSafePreset != expectedSafe || row.kind != .deleteCaptureRemnants {
                failures.append("unsafe hidden capture defaults: \(row.id)")
            }
            let guide = row.cleanupGuide
            if guide.summary.ru.isEmpty || guide.summary.en.isEmpty
                || guide.what.ru.isEmpty || guide.what.en.isEmpty
                || guide.effect.ru.isEmpty || guide.effect.en.isEmpty
                || (expectedSafe && guide.disposition != .safe)
                || (!expectedSafe && guide.disposition != .choice) {
                failures.append("hidden capture explanation is incomplete: \(row.id)")
            }
            if expectedSafe,
               (!row.subtitle.ru.localizedCaseInsensitiveContains("безопасн")
                    || !row.subtitle.en.localizedCaseInsensitiveContains("safe")) {
                failures.append("Safe TemporaryItems card still describes itself as manual: \(row.id)")
            }
            CamLog.line(
                "qa hidden-captures card \(row.id) bytes=\(row.bytes) "
                    + "subtitle=\(row.subtitle.en) path=\(row.url.path)"
            )
        }
        if let telegram = rows.first(where: { $0.id == "hidden-media-telegram-temp" }) {
            if telegram.selected || !telegram.keepsLogins
                || HiddenCaptureScanner.declaredOwnerName(for: telegram) != "Telegram" {
                failures.append("Telegram temp card lost safe defaults or owner guard")
            }
            CamLog.line("qa hidden-captures Telegram blocker=\(SessionGuard.blockingOwner(for: telegram) ?? "none")")
        }
        if let messagesTemporary = rows.first(where: {
            $0.id.hasPrefix("hidden-container-temporary-")
                && $0.url.path.contains("/Containers/com.apple.MobileSMS/")
        }) {
            if messagesTemporary.selected
                || !messagesTemporary.isSafePreset
                || !messagesTemporary.keepsLogins
                || !HiddenCaptureScanner.isExplicitCard(messagesTemporary)
                || !Keep.allowsExplicitCard(messagesTemporary)
                || HiddenCaptureScanner.declaredOwnerName(for: messagesTemporary) != "Messages"
                || SessionGuard.ownerName(for: messagesTemporary.url) != "Messages" {
                failures.append("Messages TemporaryItems card lost Safe-preset or owner safety boundary")
            }
            CamLog.line(
                "qa hidden-captures Messages TemporaryItems blocker="
                    + (SessionGuard.blockingOwner(for: messagesTemporary) ?? "none")
            )
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-hidden-captures ok items=\(rows.count) cases=\(classifications.count) ms=\(ms)\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa hidden-captures FAIL \(failure)") }
        FileHandle.standardError.write(Data("qa-hidden-captures failed: \(failures.joined(separator: "; "))\n".utf8))
        exit(2)
    }

    static func forensicRemnants() -> Never {
        CamLog.line("qa forensic-remnants begin")
        var failures: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        let contexts: [(String, URL, Bool)] = [
            ("Library", home.appendingPathComponent("Library/unknown/image.png"), true),
            ("home dot tree", home.appendingPathComponent(".unknown/image.png"), true),
            ("nested dot tree", home.appendingPathComponent("Downloads/project/.hidden/image.png"), true),
            ("normal Desktop", home.appendingPathComponent("Desktop/image.png"), false),
            ("Darwin cache", URL(fileURLWithPath: "/private/var/folders/token/C/image.png"), true)
        ]
        for (name, url, expected) in contexts {
            let actual = ForensicRemnantScanner.isResidualContextForQA(url)
            if actual != expected {
                failures.append("residual context \(name) got=\(actual) expected=\(expected)")
            }
        }

        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let mov = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20])
        if !ForensicRemnantScanner.hasMediaMagicForQA(png)
            || !ForensicRemnantScanner.hasMediaMagicForQA(jpeg)
            || !ForensicRemnantScanner.hasMediaMagicForQA(mov)
            || ForensicRemnantScanner.hasMediaMagicForQA(Data("ordinary data".utf8)) {
            failures.append("forensic media signature boundary failed")
        }

        let started = Date()
        let rows = ForensicRemnantScanner.items()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let deniedCoverage = JunkItem(
            id: "forensic-denied-library-coverage",
            module: .junk,
            title: Line.proper("denied"),
            subtitle: Line.proper("denied"),
            url: home.appendingPathComponent("Library"),
            bytes: 0,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
        if !Scanner.shouldIncludeForQA(deniedCoverage, in: .junk) {
            failures.append("zero-byte denied coverage card was filtered out")
        }
        for row in rows {
            if !ForensicRemnantScanner.isExplicitCard(row)
                || row.kind != .advice || row.selected || row.isSafePreset {
                failures.append("unsafe/unrecognized forensic card: \(row.id)")
            }
            CamLog.line(
                "qa forensic-remnants card \(row.id) bytes=\(row.bytes) path=\(row.url.path)"
            )
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data(
                "qa-forensic-remnants ok items=\(rows.count) ms=\(ms)\n".utf8
            ))
            exit(0)
        }
        for failure in failures { CamLog.line("qa forensic-remnants FAIL \(failure)") }
        FileHandle.standardError.write(Data(
            "qa-forensic-remnants failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    static func screenshotProvenance() -> Never {
        CamLog.line("qa screenshot-provenance begin")
        let started = Date()
        let summary = ScreenshotProvenanceScanner.audit()
        var failures: [String] = []
        for row in summary.cards {
            if !ScreenshotProvenanceScanner.isExplicitCard(row)
                || row.kind != .advice || row.selected || row.isSafePreset || !row.keepsLogins {
                failures.append("unsafe/unrecognized screenshot provenance card: \(row.id)")
            }
            CamLog.line(
                "qa screenshot provenance card \(row.id) bytes=\(row.bytes) path=\(PathFormat.tilde(row.url))"
            )
        }
        let output = "sources=\(summary.sourceImages) candidates=\(summary.candidateFiles) "
            + "decoded=\(summary.decodedImages) exact=\(summary.exactMatches) "
            + "visual=\(summary.visualMatches) bytes=\(summary.matchedBytes) "
            + "evidence=\(summary.matchedSources.sorted { $0.key < $1.key }) "
            + "denied=\(summary.denied) timedOut=\(summary.timedOut) "
            + "cards=\(summary.cards.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-screenshot-provenance ok \(output)\n".utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data(
            "qa-screenshot-provenance failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    static func similarCaptures() -> Never {
        CamLog.line("qa similar-captures begin")
        let fixture = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("cam98-similar-captures-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: fixture) }
        var failures: [String] = []

        func image(seed: Int) -> CGImage? {
            let width = 960
            let height = 600
            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.setFillColor(CGColor(red: seed == 1 ? 0.93 : 0.12, green: 0.15, blue: 0.22, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            for index in 0..<1_200 {
                let x = (index * (seed == 1 ? 37 : 53)) % width
                let y = (index * (seed == 1 ? 71 : 29)) % height
                let red = CGFloat((index * 17 + seed * 43) % 255) / 255
                let green = CGFloat((index * 31 + seed * 19) % 255) / 255
                let blue = CGFloat((index * 11 + seed * 83) % 255) / 255
                context.setFillColor(CGColor(red: red, green: green, blue: blue, alpha: 1))
                context.fill(CGRect(x: x, y: y, width: 18 + index % 23, height: 5 + index % 11))
            }
            context.setFillColor(CGColor(gray: seed == 1 ? 0.98 : 0.18, alpha: 1))
            context.fill(CGRect(x: 70, y: 90, width: 820, height: 62))
            context.fill(CGRect(x: 70, y: 185, width: seed == 1 ? 610 : 360, height: 34))
            return context.makeImage()
        }

        func write(_ image: CGImage, to url: URL, type: UTType, quality: Double? = nil) -> Bool {
            guard let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                type.identifier as CFString,
                1,
                nil
            ) else { return false }
            var properties: [CFString: Any] = [:]
            if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            return CGImageDestinationFinalize(destination)
        }

        do {
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
            guard let base = image(seed: 1), let other = image(seed: 2) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let reference = fixture.appendingPathComponent("Screenshot 2026-08-31 at 10.00.00.png")
            let recompressed = fixture.appendingPathComponent("renamed-copy.jpg")
            let unrelated = fixture.appendingPathComponent("same-size-but-different.jpg")
            guard write(base, to: reference, type: .png),
                  write(base, to: recompressed, type: .jpeg, quality: 0.62),
                  write(other, to: unrelated, type: .jpeg, quality: 0.62) else {
                throw CocoaError(.fileWriteUnknown)
            }

            let similar = SimilarCaptureScanner.compareForQA(reference, recompressed)
            let different = SimilarCaptureScanner.compareForQA(reference, unrelated)
            if !similar.passes { failures.append("PNG to recompressed JPEG was not matched") }
            if different.passes { failures.append("different same-size image became a visual duplicate") }
            let rows = SimilarCaptureScanner.itemsForQA(roots: [fixture])
            if !rows.contains(where: {
                $0.url.standardizedFileURL == recompressed.standardizedFileURL
                    && $0.id.hasPrefix("similar-capture-file-")
                    && $0.kind == .deleteItem && !$0.selected && !$0.isSafePreset
            }) {
                failures.append("renamed recompressed capture did not produce a manual-only row")
            }
            if rows.contains(where: { $0.url.standardizedFileURL == unrelated.standardizedFileURL }) {
                failures.append("unrelated image produced a cleanup row")
            }

            ContentFingerprinter.resetForQA()
            let cacheFixture = fixture.appendingPathComponent("fingerprint.bin")
            var payload = Data((0..<1_100_000).map { UInt8(($0 * 31) % 251) })
            try payload.write(to: cacheFixture)
            let first = ContentFingerprinter.fullSignature(cacheFixture, expectedSize: Int64(payload.count))
            let cached = ContentFingerprinter.fullSignature(cacheFixture, expectedSize: Int64(payload.count))
            payload[payload.count / 2] ^= 0x7f
            try payload.write(to: cacheFixture)
            let changed = ContentFingerprinter.fullSignature(cacheFixture, expectedSize: Int64(payload.count))
            if first == nil || first != cached { failures.append("unchanged fingerprint cache was unstable") }
            if changed == nil || changed == first { failures.append("changed file reused a stale fingerprint") }

            CamLog.line(
                "qa similar captures distance-same=\(similar.distance.map(String.init(describing:)) ?? "nil") "
                    + "distance-different=\(different.distance.map(String.init(describing:)) ?? "nil") "
                    + "rows=\(rows.count)"
            )
        } catch {
            failures.append("fixture failed: \(error.localizedDescription)")
        }

        try? FileManager.default.removeItem(at: fixture)
        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-similar-captures ok\n".utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data(
            "qa-similar-captures failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    static func duplicateFolders() -> Never {
        CamLog.line("qa duplicate-folders begin")
        let fm = FileManager.default
        let fixture = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("cam98-duplicate-folders-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: fixture) }
        var failures: [String] = []

        do {
            let first = fixture.appendingPathComponent("Archive A")
            let second = fixture.appendingPathComponent("Archive B")
            let changed = fixture.appendingPathComponent("Archive C")
            let unsafeFirst = fixture.appendingPathComponent("Links A")
            let unsafeSecond = fixture.appendingPathComponent("Links B")
            let hiddenFirst = fixture.appendingPathComponent(".Hidden A")
            let hiddenSecond = fixture.appendingPathComponent(".Hidden B")
            let databaseFirst = fixture.appendingPathComponent(".pg5444")
            let databaseSecond = fixture.appendingPathComponent(".pg5445")
            let folders = [first, second, changed].flatMap {
                [$0, $0.appendingPathComponent("nested")]
            } + [
                unsafeFirst, unsafeSecond, hiddenFirst, hiddenSecond,
                databaseFirst.appendingPathComponent("base/4"),
                databaseSecond.appendingPathComponent("base/4")
            ]
            for folder in folders {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }

            let payload = Data((0..<262_144).map { UInt8(($0 * 37 + 11) % 251) })
            let changedPayload = Data((0..<262_144).map { UInt8(($0 * 37 + 12) % 251) })
            for root in [first, second] {
                try Data("same top-level note\n".utf8)
                    .write(to: root.appendingPathComponent("README.txt"), options: .atomic)
                try payload.write(
                    to: root.appendingPathComponent("nested/payload.bin"),
                    options: .atomic
                )
            }
            try Data("same top-level note\n".utf8)
                .write(to: changed.appendingPathComponent("README.txt"), options: .atomic)
            try changedPayload.write(
                to: changed.appendingPathComponent("nested/payload.bin"),
                options: .atomic
            )
            for root in [unsafeFirst, unsafeSecond] {
                try fm.createSymbolicLink(
                    at: root.appendingPathComponent("outside"),
                    withDestinationURL: first
                )
            }
            for root in [hiddenFirst, hiddenSecond] {
                try Data("hidden duplicate\n".utf8)
                    .write(to: root.appendingPathComponent("secret.dat"), options: .atomic)
            }
            for root in [databaseFirst, databaseSecond] {
                try Data("17\n".utf8).write(
                    to: root.appendingPathComponent("PG_VERSION"),
                    options: .atomic
                )
                try Data("database page\n".utf8).write(
                    to: root.appendingPathComponent("base/4/12345"),
                    options: .atomic
                )
            }

            let summary = DuplicateFolderScanner.auditForQA(roots: [fixture])
            let rows = summary.cards
            let exactRows = rows.filter {
                let path = $0.url.standardizedFileURL.path
                return path == first.standardizedFileURL.path
                    || path == second.standardizedFileURL.path
            }
            if exactRows.count != 1 {
                failures.append("expected one whole-folder row for A/B, got \(exactRows.count)")
            }
            if rows.contains(where: {
                let path = $0.url.standardizedFileURL.path
                return path == changed.standardizedFileURL.path
                    || path.hasPrefix(unsafeFirst.standardizedFileURL.path)
                    || path.hasPrefix(unsafeSecond.standardizedFileURL.path)
            }) {
                failures.append("changed or symlink-containing folder escaped the safety filter")
            }
            let hiddenRows = rows.filter {
                $0.url.standardizedFileURL == hiddenFirst.standardizedFileURL
                    || $0.url.standardizedFileURL == hiddenSecond.standardizedFileURL
            }
            if hiddenRows.count != 1 {
                failures.append("hidden whole-folder duplicate was not discovered")
            }
            if rows.contains(where: {
                $0.url.standardizedFileURL.path.hasPrefix(databaseFirst.standardizedFileURL.path)
                    || $0.url.standardizedFileURL.path.hasPrefix(databaseSecond.standardizedFileURL.path)
            }) {
                failures.append("database pages escaped the sensitive-store boundary")
            }
            if let card = exactRows.first {
                if card.kind != .deleteItem || card.selected || card.isSafePreset
                    || !DuplicateFolderScanner.isExplicitCard(card)
                    || !Keep.allowsExplicitCard(card) {
                    failures.append("whole-folder row was not manual-only or was unrecognized")
                }
                if card.cleanupGuide.disposition != .choice
                    || !card.cleanupGuide.what.ru.contains("SHA-256")
                    || !card.cleanupGuide.effect.ru.contains("заново проверит") {
                    failures.append("whole-folder explanation is incomplete")
                }
                if !DuplicateFolderScanner.isSafeDeletionCandidate(card) {
                    failures.append("unchanged identical trees failed cleanup-time validation")
                }
                let keeper = card.url.standardizedFileURL == first.standardizedFileURL
                    ? second : first
                try Data("changed after scan\n".utf8)
                    .write(to: keeper.appendingPathComponent("late-file.txt"), options: .atomic)
                if DuplicateFolderScanner.isSafeDeletionCandidate(card) {
                    failures.append("post-scan folder mutation did not cancel deletion")
                }
                let refused = Janitor.clean(card)
                if !refused.failed || !fm.fileExists(atPath: card.url.path) {
                    failures.append("janitor did not preserve a folder changed after scanning")
                }
                try fm.removeItem(at: keeper.appendingPathComponent("late-file.txt"))
                let cleaned = Janitor.clean(card)
                if cleaned.failed || fm.fileExists(atPath: card.url.path)
                    || !fm.fileExists(atPath: keeper.path) {
                    failures.append("revalidated fixture duplicate did not complete a safe cleanup")
                }
            }

            let rotation = DuplicateFolderScanner.rotatedIndicesForQA(count: 5, cursor: 3)
            if rotation != [3, 4, 0, 1, 2] {
                failures.append("resume rotation order is wrong: \(rotation)")
            }
            let afterIncomplete = DuplicateFolderScanner.nextCursorForQA(
                count: 5,
                attempted: [3, 4, 0],
                firstIncomplete: 4
            )
            if afterIncomplete != 0 {
                failures.append("resume cursor did not advance past incomplete job")
            }

            let rotationRoot = fixture.appendingPathComponent("rotation-root")
            let huge = rotationRoot.appendingPathComponent("A Huge")
            let tiny = rotationRoot.appendingPathComponent("B Tiny")
            try fm.createDirectory(at: huge, withIntermediateDirectories: true)
            try fm.createDirectory(at: tiny, withIntermediateDirectories: true)
            for index in 0..<6 {
                try Data("\(index)\n".utf8).write(
                    to: huge.appendingPathComponent("\(index).txt"),
                    options: .atomic
                )
            }
            try Data("tiny\n".utf8).write(
                to: tiny.appendingPathComponent("one.txt"),
                options: .atomic
            )
            let limited = DuplicateFolderScanner.auditForQA(
                roots: [rotationRoot],
                maximumJobEntries: 2
            )
            if !limited.timedOut || limited.totalJobs != 2 || limited.completedJobs != 1
                || limited.nextCursor != 1
                || !limited.cards.contains(where: { $0.id == "dup-folder-partial-coverage" }) {
                failures.append(
                    "bounded queue failed: jobs=\(limited.completedJobs)/\(limited.totalJobs) "
                        + "cursor=\(limited.nextCursor) timedOut=\(limited.timedOut)"
                )
            }
            CamLog.line(
                "qa duplicate folders indexed=\(summary.indexedFolders) "
                    + "shapeGroups=\(summary.shapeGroups) exactGroups=\(summary.exactGroups) "
                    + "hashedFiles=\(summary.hashedFiles) cards=\(rows.count) "
                    + "jobs=\(summary.completedJobs)/\(summary.totalJobs)"
            )
        } catch {
            failures.append("fixture failed: \(error.localizedDescription)")
        }

        try? fm.removeItem(at: fixture)
        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-duplicate-folders ok\n".utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data(
            "qa-duplicate-folders failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    static func duplicateFoldersReal() -> Never {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
            .map { home.appendingPathComponent($0) }
        let started = Date()
        let summary = DuplicateFolderScanner.audit(roots: roots)
        var failures: [String] = []
        for card in summary.cards {
            CamLog.line(
                "qa duplicate-folders-real card \(card.id) bytes=\(card.bytes) "
                    + "kind=\(card.kind) path=\(PathFormat.tilde(card.url))"
            )
            if card.selected || card.isSafePreset {
                failures.append("folder result entered automatic selection: \(card.id)")
            }
            if card.id.hasPrefix("dup-folder-")
                && card.id != "dup-folder-partial-coverage"
                && !DuplicateFolderScanner.isExplicitCard(card) {
                failures.append("unregistered folder result: \(card.id)")
            }
            if card.cleanupGuide.summary.ru.isEmpty || card.cleanupGuide.what.ru.isEmpty
                || card.cleanupGuide.effect.ru.isEmpty {
                failures.append("empty folder explanation: \(card.id)")
            }
        }
        let output = "jobs=\(summary.completedJobs)/\(summary.totalJobs) "
            + "cursor=\(summary.nextCursor) indexed=\(summary.indexedFolders) "
            + "shape=\(summary.shapeGroups) exact=\(summary.exactGroups) "
            + "cards=\(summary.cards.count) timedOut=\(summary.timedOut) "
            + "ms=\(Int(Date().timeIntervalSince(started) * 1000))"
        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-duplicate-folders-real ok \(output)\n".utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data(
            "qa-duplicate-folders-real failed: \(failures.joined(separator: "; ")); \(output)\n".utf8
        ))
        exit(2)
    }

    static func trashForensics() -> Never {
        CamLog.line("qa trash-forensics begin")
        var failures: [String] = []
        let chunk = Scanner.safeItems(for: .trash)
        let rows = chunk.items
        let home = FileManager.default.homeDirectoryForCurrentUser
        let userTrash = home.appendingPathComponent(".Trash")
        let cloudTrash = home.appendingPathComponent("Library/Mobile Documents/.Trash")

        if rows.contains(where: { $0.selected || ($0.kind != .emptyTrash && $0.kind != .advice) }) {
            failures.append("trash row became selected or destructive outside emptyTrash")
        }
        if FileManager.default.fileExists(atPath: userTrash.path),
           (try? FileManager.default.contentsOfDirectory(at: userTrash, includingPropertiesForKeys: nil)) == nil,
           !rows.contains(where: { $0.id == "trash-user-denied" && $0.kind == .advice }) {
            failures.append("denied user Trash was silently filtered")
        }
        if let children = try? FileManager.default.contentsOfDirectory(
            at: cloudTrash,
            includingPropertiesForKeys: nil
        ), children.contains(where: { $0.lastPathComponent != ".DS_Store" }),
           !rows.contains(where: { $0.id == "trash-icloud" }) {
            failures.append("non-empty hidden iCloud Trash was not surfaced")
        }
        for row in rows {
            CamLog.line("qa trash-forensics card \(row.id) bytes=\(row.bytes) path=\(row.url.path)")
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-trash-forensics ok items=\(rows.count)\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa trash-forensics FAIL \(failure)") }
        FileHandle.standardError.write(Data(
            "qa-trash-forensics failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    static func deepMediaForensics() -> Never {
        CamLog.line("qa deep-media-forensics begin")
        var failures: [String] = []
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE1])
        let mov = Data([0, 0, 0, 20, 0x66, 0x74, 0x79, 0x70, 0x71, 0x74, 0x20, 0x20])
        let webm = Data([0x1A, 0x45, 0xDF, 0xA3])
        if DeepMediaForensicsScanner.mediaKindForQA(png) != "image"
            || DeepMediaForensicsScanner.mediaKindForQA(jpeg) != "image"
            || DeepMediaForensicsScanner.mediaKindForQA(mov) != "media"
            || DeepMediaForensicsScanner.mediaKindForQA(webm) != "video"
            || DeepMediaForensicsScanner.mediaKindForQA(Data("ordinary".utf8)) != nil {
            failures.append("binary media classification boundary failed")
        }

        let started = Date()
        let rows = DeepMediaForensicsScanner.items()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        for row in rows {
            if !DeepMediaForensicsScanner.isExplicitCard(row)
                || row.kind != .advice || row.selected || row.isSafePreset {
                failures.append("unsafe/unrecognized deep-media card: \(row.id)")
            }
            CamLog.line(
                "qa deep-media card \(row.id) bytes=\(row.bytes) path=\(PathFormat.tilde(row.url)) subtitle=\(row.subtitle.en)"
            )
        }
        if failures.isEmpty {
            FileHandle.standardOutput.write(Data(
                "qa-deep-media-forensics ok items=\(rows.count) ms=\(ms)\n".utf8
            ))
            exit(0)
        }
        for failure in failures { CamLog.line("qa deep-media FAIL \(failure)") }
        FileHandle.standardError.write(Data(
            "qa-deep-media-forensics failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    static func aiStorage() -> Never {
        CamLog.line("qa ai-storage begin")
        var failures: [String] = []
        let fixture = Data(
            """
            {
              "openai.chatgpt-1.2.3-darwin-arm64": true,
              "anthropic.claude-code-2.0.0": false,
              "../escape": true,
              ".hidden": true,
              "nested/path": true
            }
            """.utf8
        )
        let parsed = AIStorageScanner.manifestNamesForQA(fixture)
        if parsed != ["openai.chatgpt-1.2.3-darwin-arm64"] {
            failures.append("obsolete manifest accepted an unsafe or false entry: \(parsed)")
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let databaseURL = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
        )
        if !Keep.isProtected(databaseURL) {
            failures.append("Cursor conversation database is not protected")
        }
        if SessionGuard.ownerName(for: home.appendingPathComponent(".cursor/extensions/example")) != "Cursor" {
            failures.append("~/.cursor has no owning-app guard")
        }
        if SessionGuard.ownerName(for: home.appendingPathComponent(".cache/codex-runtimes/stage")) != "ChatGPT / Codex" {
            failures.append("Codex runtime staging has no owning-app guard")
        }
        if SessionGuard.ownerName(for: home.appendingPathComponent(".local/share/opencode/log")) != "OpenCode" {
            failures.append("OpenCode logs have no owning-app guard")
        }

        let rows = AIStorageScanner.items()
        for row in rows {
            if !AIStorageScanner.isExplicitCard(row) || !Keep.allowsExplicitCard(row) {
                failures.append("unrecognized AI storage card: \(row.id)")
            }
            let expectedOwner: String = {
                if row.id.hasPrefix("ai-codex-") { return "ChatGPT / Codex" }
                if row.id.hasPrefix("ai-claude-") { return "Claude" }
                if row.id.hasPrefix("ai-opencode-") { return "OpenCode" }
                return "Cursor"
            }()
            if SessionGuard.ownerName(for: row.url) != expectedOwner {
                failures.append("AI storage card has no \(expectedOwner) owner: \(row.id)")
            }
            if row.id == "ai-cursor-state-db" {
                if row.kind != .advice || row.selected || row.isSafePreset {
                    failures.append("Cursor database became destructive/selectable")
                }
                let fakeDelete = JunkItem(
                    id: row.id,
                    module: row.module,
                    title: row.title,
                    subtitle: row.subtitle,
                    url: row.url,
                    bytes: row.bytes,
                    selected: true,
                    kind: .deleteItem,
                    keepsLogins: true
                )
                if AIStorageScanner.isExplicitCard(fakeDelete) || !Janitor.clean(fakeDelete).failed {
                    failures.append("Janitor accepted direct Cursor database deletion")
                }
            } else if row.id == "ai-cursor-extension-trash" {
                if !row.selected || !row.isSafePreset {
                    failures.append("Cursor extension trash is not in Safe preset")
                }
            } else if row.id == "ai-opencode-logs" {
                if !row.selected || !row.isSafePreset {
                    failures.append("OpenCode logs are not in Safe preset")
                }
            } else if row.selected || row.isSafePreset {
                failures.append("opt-in AI storage became a default deletion: \(row.id)")
            }
            CamLog.line(
                "qa ai-storage card \(row.id) bytes=\(row.bytes) kind=\(row.kind) path=\(row.url.path)"
            )
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-ai-storage ok items=\(rows.count)\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa ai-storage FAIL \(failure)") }
        FileHandle.standardError.write(Data("qa-ai-storage failed: \(failures.joined(separator: "; "))\n".utf8))
        exit(2)
    }

    static func storageIntelligence() -> Never {
        CamLog.line("qa storage-intelligence begin")
        var failures: [String] = []
        let fm = FileManager.default

        let ephemeralCases: [(String, Bool)] = [
            ("Cache", true), ("GPUCache", true), ("Code Cache", true),
            ("tmp", true), (".trash", true), ("CacheBackup", false),
            ("downloads", false), ("Session Storage", false)
        ]
        for (name, expected) in ephemeralCases {
            let actual = StorageIntelligenceScanner.isStrongEphemeralNameForQA(name)
            if actual != expected { failures.append("ephemeral name \(name) got=\(actual) expected=\(expected)") }
        }

        let hiddenBuildCases: [(String, Bool, Bool)] = [
            (".turbo", false, true),
            (".dart_tool", false, true),
            (".gradle", false, true),
            (".git", false, false),
            (".turbo", true, false)
        ]
        for (name, topLevelHome, expected) in hiddenBuildCases {
            let actual = HiddenTreeScanner.isRebuildableNameForQA(name, topLevelHome: topLevelHome)
            if actual != expected {
                failures.append("hidden tree role \(name) top=\(topLevelHome) got=\(actual) expected=\(expected)")
            }
        }
        if !HiddenTreeScanner.isSensitiveNameForQA("auth-session")
            || HiddenTreeScanner.isSensitiveNameForQA("cache") {
            failures.append("hidden tree sensitive-name boundary failed")
        }

        var png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        png.append(Data(repeating: 0, count: 24))
        if !StorageIntelligenceScanner.hasMediaMagicForQA(png) {
            failures.append("PNG magic was not recognized")
        }
        if StorageIntelligenceScanner.hasMediaMagicForQA(Data("ordinary text payload".utf8)) {
            failures.append("ordinary data was classified as media")
        }

        let coverage = JunkItem(
            id: StorageIntelligenceScanner.coverageIDForQA,
            module: .junk,
            title: Line.proper("QA coverage"),
            subtitle: Line.proper("QA"),
            url: fm.homeDirectoryForCurrentUser,
            bytes: 0,
            selected: false,
            kind: .advice,
            keepsLogins: true
        )
        if !StorageIntelligenceScanner.isExplicitCard(coverage)
            || !Keep.allowsExplicitCard(coverage)
            || StorageIntelligenceScanner.isSafeDeletionCandidate(coverage) {
            failures.append("partial coverage audit boundary failed")
        }

        let fixture = fm.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/cam98-qa-intel-\(UUID().uuidString)")
        let cache = fixture.appendingPathComponent("Cache")
        do {
            try fm.createDirectory(at: cache, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: fixture) }
            let one = cache.appendingPathComponent("one.bin")
            let two = cache.appendingPathComponent("two.bin")
            let different = cache.appendingPathComponent("different.bin")
            let edge = Data(repeating: 0x43, count: 64 * 1024)
            let payload = edge + Data(repeating: 0x41, count: 96 * 1024) + edge
            let changed = edge + Data(repeating: 0x42, count: 96 * 1024) + edge
            try payload.write(to: one)
            try payload.write(to: two)
            try changed.write(to: different)
            let size = Int64(payload.count)
            let sigOne = StorageIntelligenceScanner.quickSignatureForQA(one, size: size)
            let sigTwo = StorageIntelligenceScanner.quickSignatureForQA(two, size: size)
            let sigDifferent = StorageIntelligenceScanner.quickSignatureForQA(different, size: size)
            if sigOne != sigTwo || sigOne == sigDifferent {
                failures.append("sample signature failed exact/middle-change fixture")
            }

            let card = JunkItem(
                id: StorageIntelligenceScanner.ephemeralIDForQA(cache),
                module: .junk,
                title: Line.proper("QA discovered cache"),
                subtitle: Line.proper("QA"),
                url: cache,
                bytes: Int64(payload.count * 3),
                selected: true,
                kind: .wipeChildren,
                keepsLogins: true
            )
            if !StorageIntelligenceScanner.isExplicitCard(card)
                || !StorageIntelligenceScanner.isSafeDeletionCandidate(card)
                || !Keep.allowsExplicitCard(card) || !card.isSafePreset
                || AutoClean.isUnattended(card) {
                failures.append("valid discovered cache failed safety boundary")
            }

            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            holder.arguments = ["-f", one.path]
            holder.standardOutput = FileHandle.nullDevice
            holder.standardError = FileHandle.nullDevice
            try holder.run()
            Thread.sleep(forTimeInterval: 0.12)
            if StorageIntelligenceScanner.blockingProcessName(for: card) == nil {
                failures.append("open file in discovered cache was not blocked")
            }
            holder.terminate()
            holder.waitUntilExit()

            let session = cache.appendingPathComponent("Session Storage")
            try fm.createDirectory(at: session, withIntermediateDirectories: false)
            try Data([1]).write(to: session.appendingPathComponent("state"))
            if StorageIntelligenceScanner.isSafeDeletionCandidate(card) {
                failures.append("session-adjacent discovered cache was accepted")
            }
            try fm.removeItem(at: session)

            let pointer = cache.appendingPathComponent("pointer")
            try fm.createSymbolicLink(at: pointer, withDestinationURL: URL(fileURLWithPath: "/tmp"))
            if StorageIntelligenceScanner.isSafeDeletionCandidate(card) {
                failures.append("symlink-containing discovered cache was accepted")
            }
        } catch {
            failures.append("fixture failed: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-storage-intelligence ok cases=\(ephemeralCases.count)\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa storage-intelligence FAIL \(failure)") }
        FileHandle.standardError.write(
            Data("qa-storage-intelligence failed: \(failures.joined(separator: "; "))\n".utf8)
        )
        exit(2)
    }

    static func storageAccounting() -> Never {
        CamLog.line("qa storage-accounting begin")
        var failures: [String] = []
        let fm = FileManager.default
        let fixture = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/CAM98-QA-storage-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: fixture, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: fixture) }
            let original = fixture.appendingPathComponent("00-original.bin")
            let ordinary = fixture.appendingPathComponent("01-ordinary-copy.bin")
            let hardLink = fixture.appendingPathComponent("02-hard-link.bin")
            let clone = fixture.appendingPathComponent("03-apfs-clone.bin")
            let different = fixture.appendingPathComponent("04-same-size-different.bin")
            let payload = Data(repeating: 0x6A, count: 2 * 1_048_576)
            try payload.write(to: original)
            try payload.write(to: ordinary)
            var changed = payload
            changed.replaceSubrange(900_000..<900_128, with: Data(repeating: 0x2B, count: 128))
            try changed.write(to: different)
            guard Darwin.link(original.path, hardLink.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            let cloneSupported = Darwin.clonefile(original.path, clone.path, 0) == 0

            guard let originalFacts = FileStorageFacts.read(original),
                  let hardFacts = FileStorageFacts.read(hardLink),
                  let ordinaryFacts = FileStorageFacts.read(ordinary) else {
                throw CocoaError(.fileReadUnknown)
            }
            if originalFacts.inodeKey != hardFacts.inodeKey
                || !originalFacts.isHardLinked || !hardFacts.isHardLinked
                || hardFacts.conservativeReclaimableBytes(contentIdentifierPopulation: 1) != 0 {
                failures.append("hard-link physical identity/reclaim estimate failed")
            }
            if ordinaryFacts.allocatedBytes <= 0
                || ordinaryFacts.conservativeReclaimableBytes(contentIdentifierPopulation: 1) <= 0 {
                failures.append("ordinary copy lost its physical reclaim estimate")
            }
            if cloneSupported {
                guard let cloneFacts = FileStorageFacts.read(clone) else {
                    throw CocoaError(.fileReadUnknown)
                }
                if cloneFacts.inodeKey == originalFacts.inodeKey
                    || cloneFacts.contentIdentifier != originalFacts.contentIdentifier
                    || !cloneFacts.mayShareFileContent
                    || cloneFacts.conservativeReclaimableBytes(contentIdentifierPopulation: 2) != 0 {
                    failures.append("APFS clone identity/reclaim estimate failed")
                }
            }

            let rows = Scanner.duplicatesForQA(roots: [fixture])
            let ordinaryRows = rows.filter {
                $0.kind == .deleteItem && $0.id.hasPrefix("dup-")
                    && !$0.id.hasPrefix("dup-clone-") && !$0.id.hasPrefix("dup-hardlink-")
            }
            if ordinaryRows.isEmpty || ordinaryRows.contains(where: { $0.bytes <= 0 }) {
                failures.append("ordinary exact copy was not offered with physical bytes")
            }
            if !rows.contains(where: {
                $0.id.hasPrefix("dup-hardlink-") && $0.kind == .advice
                    && $0.bytes == 0 && $0.reclaimableBytes == 0
            }) {
                failures.append("hard link was not converted to a zero-byte audit row")
            }
            if cloneSupported, !rows.contains(where: {
                $0.id.hasPrefix("dup-clone-") && $0.kind == .advice
                    && $0.bytes == 0 && $0.reclaimableBytes == 0
            }) {
                failures.append("APFS clone was not converted to a zero-byte audit row")
            }
            if rows.contains(where: { $0.url.standardizedFileURL == different.standardizedFileURL }) {
                failures.append("same-size file with different middle bytes became a duplicate")
            }

            let audit = JunkItem(
                id: "system-audit-qa-ledger",
                module: .junk,
                title: Line.proper("QA"),
                subtitle: Line.proper("QA"),
                url: fixture,
                bytes: 1_073_741_824,
                selected: false,
                kind: .advice,
                keepsLogins: true
            )
            if audit.reclaimableBytes != 0 || !audit.hasVisibleFinding {
                failures.append("audit bytes leaked into cleanup promise")
            }
            CamLog.line(
                "qa storage-accounting rows=\(rows.count) clone=\(cloneSupported) "
                    + "ordinary=\(ordinaryFacts.allocatedBytes)"
            )
        } catch {
            failures.append("fixture failed: \(error.localizedDescription)")
        }

        if failures.isEmpty {
            FileHandle.standardOutput.write(Data("qa-storage-accounting ok\n".utf8))
            exit(0)
        }
        for failure in failures { CamLog.line("qa storage-accounting FAIL \(failure)") }
        FileHandle.standardError.write(
            Data("qa-storage-accounting failed: \(failures.joined(separator: "; "))\n".utf8)
        )
        exit(2)
    }

    static func storageIntelligenceScan() -> Never {
        let started = Date()
        let rows = StorageIntelligenceScanner.items()
        for row in rows {
            CamLog.line(
                "qa intelligence card \(row.id) bytes=\(row.bytes) selected=\(row.selected) "
                    + "kind=\(row.kind) path=\(PathFormat.tilde(row.url))"
            )
        }
        FileHandle.standardOutput.write(
            Data("qa-storage-intelligence-scan ok items=\(rows.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))\n".utf8)
        )
        exit(0)
    }

    static func hiddenTrees() -> Never {
        CamLog.line("qa hidden-trees begin")
        let started = Date()
        let rows = HiddenTreeScanner.items()
        var failures: [String] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        for row in rows {
            if !HiddenTreeScanner.isExplicitCard(row) || !Keep.allowsExplicitCard(row) {
                failures.append("unrecognized hidden tree card: \(row.id)")
            }
            if row.url.standardizedFileURL.path == home {
                failures.append("broad home card escaped")
            }
            if row.kind == .advice, row.isSafePreset {
                failures.append("audit hidden tree entered Safe preset: \(row.id)")
            }
            if row.id.hasPrefix("hidden-tree-cache-") {
                if row.selected || row.kind != .wipeChildren
                    || !HiddenTreeScanner.isSafeDeletionCandidate(row) {
                    failures.append("rebuildable hidden tree failed safety boundary: \(row.id)")
                }
            }
            CamLog.line(
                "qa hidden-tree card \(row.id) bytes=\(row.bytes) selected=\(row.selected) "
                    + "kind=\(row.kind) path=\(PathFormat.tilde(row.url))"
            )
        }
        if failures.isEmpty {
            FileHandle.standardOutput.write(
                Data("qa-hidden-trees ok items=\(rows.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))\n".utf8)
            )
            exit(0)
        }
        for failure in failures { CamLog.line("qa hidden-trees FAIL \(failure)") }
        FileHandle.standardError.write(
            Data("qa-hidden-trees failed: \(failures.joined(separator: "; "))\n".utf8)
        )
        exit(2)
    }

    static func cancellation() -> Never {
        CamLog.line("qa cancellation begin")
        var failures: [String] = []

        let preCancelled = ScanCancellation()
        preCancelled.cancel()
        let scanStarted = Date()
        let chunk = Scanner.safeItems(for: .junk, cancellation: preCancelled)
        let scanElapsed = Date().timeIntervalSince(scanStarted)
        if !chunk.items.isEmpty { failures.append("pre-cancelled scan returned items") }
        if scanElapsed > 1 { failures.append("pre-cancelled scan took \(scanElapsed)s") }

        let processCancellation = ScanCancellation()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.12) {
            processCancellation.cancel()
        }
        let processStarted = Date()
        let process = CamProcess.run(
            path: "/bin/sleep",
            arguments: ["10"],
            timeout: 5,
            cancellation: processCancellation
        )
        let processElapsed = Date().timeIntervalSince(processStarted)
        if process.timedOut { failures.append("cancelled process reported timeout") }
        if processElapsed > 1.5 { failures.append("process cancellation took \(processElapsed)s") }

        let activeCancellation = ScanCancellation()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
            activeCancellation.cancel()
        }
        let activeStarted = Date()
        // The long-running forensic phases live in Deep search now (Junk is fast), so that's the
        // stage a mid-flight Stop has to interrupt.
        let activeChunk = Scanner.safeItems(for: .deepSearch, cancellation: activeCancellation)
        let activeElapsed = Date().timeIntervalSince(activeStarted)
        if !activeChunk.items.isEmpty { failures.append("active cancelled scan returned items") }
        if activeElapsed > 12 { failures.append("active scan cancellation took \(activeElapsed)s") }

        if failures.isEmpty {
            let message =
                "qa-cancellation ok scan_ms=\(Int(scanElapsed * 1000)) "
                    + "process_ms=\(Int(processElapsed * 1000)) "
                    + "active_ms=\(Int(activeElapsed * 1000))\n"
            FileHandle.standardOutput.write(Data(message.utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data(
            "qa-cancellation failed: \(failures.joined(separator: "; "))\n".utf8
        ))
        exit(2)
    }

    /// Validates every card a Smart scan produces (leaks, sessions, logins, risky defaults, titles,
    /// guides — exits 2 on any problem) and profiles it the way the app runs it: Smart's light stages
    /// concurrently (real wall time, cold), then each stage — light first, then the deep on-demand
    /// ones (skip those with CAM98_QA_LIGHT=1). `--qa-smart-stage=<module>` runs one layer only.
    static func smart() -> Never {
        CamLog.line("qa smart begin")
        let t0 = Date()
        var total = 0
        var forbidden = 0
        let requestedName = CommandLine.arguments
            .first { $0.hasPrefix("--qa-smart-stage=") }
            .map { String($0.dropFirst("--qa-smart-stage=".count)) }
        let light = Scanner.ScanStage.stages(for: .smart)
        let deep = ProcessInfo.processInfo.environment["CAM98_QA_LIGHT"] == nil
            ? Scanner.ScanStage.allCases.filter(\.isDeep) : []
        let stages = requestedName.map { name in
            Scanner.ScanStage.allCases.filter { $0.module.rawValue == name }
        } ?? (light + deep)
        if let requestedName, stages.isEmpty {
            FileHandle.standardError.write(Data("qa-smart failed: unknown stage \(requestedName)\n".utf8))
            exit(2)
        }

        var blockedBytes: Int64 = 0
        var blockedApps = Set<String>()
        var report = ""
        if requestedName == nil {
            let wallMs = parallelWallMs(light)
            SizeCache.shared.clear()   // per-stage timings below shouldn't ride the parallel run's cache
            report += "\nSMART — light stages, parallel wall time as in the app: \(wallMs) ms\n"
            report += "  (+ the live Protection/Performance/Startup checks Smart runs after)\n"
            CamLog.line("qa smart wall=\(wallMs)")
        }
        report += "\nstage         items      bytes        sel-bytes     ms\n"
        report += "-----------------------------------------------------------\n"

        for stage in stages {
            if requestedName == nil, Date().timeIntervalSince(t0) > 480 {
                CamLog.line("qa smart abort remaining after 480s at \(stage.module.rawValue)")
                report += "(aborted after 480s)\n"
                break
            }
            let started = Date()
            let chunk = Scanner.safeItems(for: stage)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            total += chunk.items.count
            for item in chunk.items {
                let guide = item.cleanupGuide
                let visibleTitle = item.userFacingTitle
                if Keep.isProtected(item.url), !Keep.allowsExplicitCard(item) {
                    forbidden += 1
                    CamLog.line("qa smart LEAK \(stage.module.rawValue) \(item.id) \(item.url.path)")
                }
                if item.url.path.contains("/Library/HTTPStorages") {
                    forbidden += 1
                    CamLog.line("qa smart SESSION \(stage.module.rawValue) \(item.id) \(item.url.path)")
                }
                if Keep.names.contains(item.url.lastPathComponent) {
                    forbidden += 1
                    CamLog.line("qa smart LOGIN \(stage.module.rawValue) \(item.id) \(item.url.lastPathComponent)")
                }
                if item.selected && !item.isSafePreset {
                    forbidden += 1
                    CamLog.line("qa smart DEFAULT-RISK \(stage.module.rawValue) \(item.id)")
                }
                if visibleTitle.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || visibleTitle.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    forbidden += 1
                    CamLog.line("qa smart EMPTY-TITLE \(stage.module.rawValue) \(item.id)")
                }
                if guide.summary.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || guide.summary.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || guide.what.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || guide.what.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || guide.effect.ru.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    || guide.effect.en.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    forbidden += 1
                    CamLog.line("qa smart EMPTY-GUIDE \(stage.module.rawValue) \(item.id)")
                }
                let expectedDisposition: CleanupDisposition = item.kind == .advice
                    ? .readOnly
                    : (item.isSafePreset ? .safe : .choice)
                if guide.disposition != expectedDisposition {
                    forbidden += 1
                    CamLog.line(
                        "qa smart WRONG-GUIDE \(stage.module.rawValue) \(item.id) "
                            + "actual=\(guide.disposition) expected=\(expectedDisposition)"
                    )
                }
            }
            CamLog.line("qa smart \(stage.module.rawValue) items=\(chunk.items.count) failed=\(chunk.failed) ms=\(ms)")
            for item in chunk.items.prefix(5) {
                CamLog.line(
                    "qa smart card \(item.id) bytes=\(item.bytes) sel=\(item.selected) "
                        + "path=\(PathFormat.tilde(item.url))"
                )
            }
            let bytes = chunk.items.reduce(Int64(0)) { $0 + $1.bytes }
            let selBytes = chunk.items.filter(\.selected).reduce(Int64(0)) { $0 + $1.bytes }
            for item in chunk.items where item.selected {
                if let app = SessionGuard.blockingOwner(for: item) {
                    blockedBytes += item.bytes
                    blockedApps.insert(app)
                }
            }
            let name = "\(stage)\(stage.isDeep ? "*" : "")".padding(toLength: 12, withPad: " ", startingAt: 0)
            let count = String(chunk.items.count).padding(toLength: 6, withPad: " ", startingAt: 0)
            let b = ByteFormat.string(bytes, .en).padding(toLength: 11, withPad: " ", startingAt: 0)
            let sb = ByteFormat.string(selBytes, .en).padding(toLength: 12, withPad: " ", startingAt: 0)
            report += "\(name)  \(count)  \(b)  \(sb)  \(ms)\(chunk.failed ? "  FAILED" : "")\n"
        }
        report += "-----------------------------------------------------------\n"
        report += "* deep stage: runs when its layer is opened, not in Smart\n"
        report += "selected but held by open apps (Clean refuses them until they quit): \(ByteFormat.string(blockedBytes, .en))\(blockedApps.isEmpty ? "" : " — " + blockedApps.sorted().joined(separator: ", "))\n"
        CamLog.line("qa smart done items=\(total) leaks=\(forbidden) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data(report.utf8))
        if forbidden == 0 {
            FileHandle.standardOutput.write(Data("qa-smart ok items=\(total) leaks=0\n".utf8))
            exit(0)
        }
        FileHandle.standardError.write(Data("qa-smart failed items=\(total) problems=\(forbidden)\n".utf8))
        exit(2)
    }

    private final class WallBox: @unchecked Sendable { var ms = 0 }

    /// Runs `stages` through the same bounded-concurrency coordinator the app uses; returns wall ms.
    private static func parallelWallMs(_ stages: [Scanner.ScanStage]) -> Int {
        let done = DispatchSemaphore(value: 0)
        let box = WallBox()
        Task.detached(priority: .utility) {
            let start = Date()
            for await _ in ScanCoordinator.stream(stages, work: { Scanner.safeItems(for: $0) }) {}
            box.ms = Int(Date().timeIntervalSince(start) * 1000)
            done.signal()
        }
        done.wait()
        return box.ms
    }
}
