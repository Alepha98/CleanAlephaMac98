import AppKit
import Darwin
import Foundation

struct CleanOutcome: Sendable {
    var freed: Int64
    var failed: Bool
    /// Bytes still on disk after a partial or refused clean; 0 if the item is gone.
    var leftover: Int64
    /// An owning app was open, so cleanup was intentionally refused to preserve its session.
    var blockedApp: String? = nil

    static func refused(leftover: Int64 = 0, blockedApp: String? = nil) -> CleanOutcome {
        CleanOutcome(freed: 0, failed: true, leftover: leftover, blockedApp: blockedApp)
    }

    static func alreadyGone(counted bytes: Int64) -> CleanOutcome {
        CleanOutcome(freed: bytes, failed: false, leftover: 0)
    }
}

enum Janitor {
    /// Skip Keep path checks for tab closes – URL is a website, not a folder we wipe.
    static func clean(_ item: JunkItem) -> CleanOutcome {
        if item.kind == .closeTab {
            return closeTab(item)
        }
        switch item.kind {
        case .deleteItem, .deleteCaptureRemnants, .wipeChildren, .safariNetworkCache:
            guard isSafeUserTarget(item) else {
                return .refused(leftover: remainingBytes(for: item))
            }
        default:
            break
        }
        if Keep.isExtraProtected(item.url) {
            return .refused(leftover: remainingBytes(for: item))
        }
        if Keep.isProtected(item.url), !Keep.allowsExplicitCard(item) {
            return .refused(leftover: remainingBytes(for: item))
        }
        if Keep.names.contains(item.url.lastPathComponent) {
            return .refused(leftover: remainingBytes(for: item))
        }
        if let app = SessionGuard.blockingOwner(for: item) {
            return .refused(
                leftover: remainingBytes(for: item),
                blockedApp: app
            )
        }
        switch item.kind {
        case .emptyTrash:
            return emptyTrash(item.url)
        case .deleteItem:
            return deleteItem(item)
        case .deleteCaptureRemnants:
            return deleteCaptureRemnants(item)
        case .safariNetworkCache:
            return safariCaches(item.url)
        case .wipeChildren:
            return wipeChildren(item)
        case .advice:
            return .alreadyGone(counted: 0)
        case .closeTab:
            return closeTab(item)
        case .removeAgent:
            return removeAgent(item)
        case .removeLoginItem:
            return removeLoginItem(item)
        }
    }

    /// Normal direct jobs stay under home. A deep runtime card may cross that boundary
    /// only after SystemDeepScanner re-validates its exact root, age, and contents.
    private static func isSafeUserTarget(_ item: JunkItem) -> Bool {
        if DuplicateFolderScanner.isExplicitCard(item) {
            return DuplicateFolderScanner.isSafeDeletionCandidate(item)
        }
        if StorageIntelligenceScanner.isExplicitCard(item) {
            return StorageIntelligenceScanner.isSafeDeletionCandidate(item)
        }
        if HiddenTreeScanner.isExplicitCard(item) {
            return HiddenTreeScanner.isSafeDeletionCandidate(item)
        }
        if AIStorageScanner.isExplicitCard(item) {
            return AIStorageScanner.isSafeDeletionCandidate(item)
        }
        if HiddenCaptureScanner.isExplicitCard(item) {
            return HiddenCaptureScanner.isSafeDeletionCandidate(item)
        }
        if SystemDeepScanner.isExplicitRuntimeCard(item) {
            return SystemDeepScanner.isSafeDeletionCandidate(item)
        }
        let url = item.url
        let path = url.standardizedFileURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        guard path != home, path.hasPrefix(home + "/") else { return false }
        let broadRoots = ["Library", "Documents", "Desktop", "Downloads", "Pictures", "Movies"]
            .map { home + "/" + $0 }
        guard !broadRoots.contains(path), path != home + "/Library/Application Support" else {
            return false
        }
        return true
    }

    private static func remainingBytes(for item: JunkItem) -> Int64 {
        if item.kind == .deleteCaptureRemnants {
            return max(item.bytes, HiddenCaptureScanner.currentBytes(for: item))
        }
        if Keep.allowsExplicitCard(item) {
            return max(item.bytes, DiskSizer.duSK(item.url, timeout: 8) ?? 0)
        }
        return max(item.bytes, DiskSizer.bytes(at: item.url))
    }

    private static func deleteCaptureRemnants(_ item: JunkItem) -> CleanOutcome {
        let result = HiddenCaptureScanner.removeEligibleRemnants(for: item)
        if result.before == 0 {
            return .alreadyGone(counted: 0)
        }
        return CleanOutcome(
            freed: max(0, result.before - result.after),
            failed: result.failed || result.after > 16_384,
            leftover: result.after
        )
    }

    private static func closeTab(_ item: JunkItem) -> CleanOutcome {
        let ok = LiveProbe.closeTab(item: item)
        if ok {
            return CleanOutcome(freed: item.bytes, failed: false, leftover: 0)
        }
        return .refused(leftover: item.bytes)
    }

    private static func deleteItem(_ item: JunkItem) -> CleanOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.url.path) else {
            return .alreadyGone(counted: 0)
        }
        do {
            try fm.removeItem(at: item.url)
        } catch {
            return .refused(leftover: remainingBytes(for: item))
        }
        if fm.fileExists(atPath: item.url.path) {
            return .refused(leftover: remainingBytes(for: item))
        }
        return CleanOutcome(freed: item.bytes, failed: false, leftover: 0)
    }

    private static func emptyTrash(_ url: URL) -> CleanOutcome {
        let fm = FileManager.default
        let before = DiskSizer.bytes(at: url)
        guard fm.fileExists(atPath: url.path) else {
            return .alreadyGone(counted: before)
        }
        guard let kids = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return .refused(leftover: before)
        }
        var anyFail = false
        for k in kids {
            if Keep.isProtected(k) || Keep.names.contains(k.lastPathComponent) {
                continue
            }
            do { try fm.removeItem(at: k) } catch { anyFail = true }
        }
        let after = DiskSizer.bytes(at: url)
        let freed = max(0, before - after)
        return CleanOutcome(freed: freed, failed: anyFail && after > 16_384, leftover: after)
    }

    private static func safariCaches(_ store: URL) -> CleanOutcome {
        let allowed = Set(["NetworkCache", "CacheStorage", "MediaCache", "JavaScriptCoreDebug", "ResourceMonitorThrottler"])
        let before = DiskSizer.bytes(at: store)
        var anyFail = false
        func scrub(_ dir: URL) {
            guard let kids = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
                anyFail = true
                return
            }
            for k in kids {
                if Keep.names.contains(k.lastPathComponent) { continue }
                if Keep.isProtected(k) { continue }
                if allowed.contains(k.lastPathComponent) {
                    do {
                        try FileManager.default.removeItem(at: k)
                        try FileManager.default.createDirectory(at: k, withIntermediateDirectories: true)
                    } catch {
                        anyFail = true
                    }
                } else if k.lastPathComponent.count >= 20 {
                    scrub(k)
                }
            }
        }
        scrub(store)
        let after = DiskSizer.bytes(at: store)
        let freed = max(0, before - after)
        return CleanOutcome(freed: freed, failed: anyFail && after > 16_384, leftover: after)
    }

    private static func wipeChildren(_ item: JunkItem) -> CleanOutcome {
        let url = item.url
        if Keep.names.contains(url.lastPathComponent)
            || (Keep.isProtected(url) && !Keep.allowsExplicitCard(item)) {
            return .refused(leftover: DiskSizer.bytes(at: url))
        }
        let fm = FileManager.default
        let explicitProtected = Keep.allowsExplicitCard(item) && Keep.isProtected(url)
        let before = explicitProtected
            ? (DiskSizer.duSK(url, timeout: 8) ?? item.bytes)
            : DiskSizer.bytes(at: url)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return .alreadyGone(counted: before)
        }
        if !isDir.boolValue {
            do {
                try fm.removeItem(at: url)
                return CleanOutcome(freed: before, failed: false, leftover: 0)
            } catch {
                return .refused(leftover: before)
            }
        }
        guard let kids = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return .refused(leftover: before)
        }
        var anyFail = false
        let allowsBuiltInProtection = Keep.allowsExplicitCard(item)
        for k in kids {
            if Keep.names.contains(k.lastPathComponent) || Keep.isExtraProtected(k) { continue }
            if Keep.isProtected(k), !allowsBuiltInProtection { continue }
            do { try fm.removeItem(at: k) } catch { anyFail = true }
        }
        let after = explicitProtected
            ? (DiskSizer.duSK(url, timeout: 8) ?? before)
            : DiskSizer.bytes(at: url)
        let freed = max(0, before - after)
        return CleanOutcome(freed: freed, failed: anyFail && after > 16_384, leftover: after)
    }

    private static func removeAgent(_ item: JunkItem) -> CleanOutcome {
        let url = item.url
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = url.standardizedFileURL.path
        guard p.hasPrefix(home), p.contains("/Library/LaunchAgents/"), url.pathExtension == "plist" else {
            return .refused(leftover: item.bytes)
        }
        if url.lastPathComponent.contains("CleanAlephaMac98") {
            return .refused(leftover: item.bytes)
        }
        let label = url.deletingPathExtension().lastPathComponent
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            return .refused(leftover: DiskSizer.bytes(at: url))
        }
        return CleanOutcome(freed: item.bytes, failed: false, leftover: 0)
    }

    private static func removeLoginItem(_ item: JunkItem) -> CleanOutcome {
        let name = item.title.ru.replacingOccurrences(of: "\"", with: "")
        guard !name.isEmpty else { return .refused(leftover: 0) }
        let source = "tell application \"System Events\" to delete login item \"\(name)\""
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return .refused(leftover: 0) }
        _ = script.executeAndReturnError(&error)
        if error != nil { return .refused(leftover: item.bytes) }
        return CleanOutcome(freed: item.bytes, failed: false, leftover: 0)
    }
}
