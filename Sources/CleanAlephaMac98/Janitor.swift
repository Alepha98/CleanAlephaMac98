import Foundation

struct CleanOutcome: Sendable {
    var freed: Int64
    var failed: Bool
    /// Bytes still on disk after a partial or refused clean; 0 if the item is gone.
    var leftover: Int64

    static func refused(leftover: Int64 = 0) -> CleanOutcome {
        CleanOutcome(freed: 0, failed: true, leftover: leftover)
    }

    static func alreadyGone(counted bytes: Int64) -> CleanOutcome {
        CleanOutcome(freed: bytes, failed: false, leftover: 0)
    }
}

enum Janitor {
    static func clean(_ item: JunkItem) -> CleanOutcome {
        if Keep.isProtected(item.url) {
            return .refused(leftover: max(item.bytes, DiskSizer.bytes(at: item.url)))
        }
        if Keep.names.contains(item.url.lastPathComponent) {
            return .refused(leftover: max(item.bytes, DiskSizer.bytes(at: item.url)))
        }
        switch item.kind {
        case .emptyTrash:
            return emptyTrash(item.url)
        case .deleteItem:
            return deleteItem(item)
        case .safariNetworkCache:
            return safariCaches(item.url)
        case .wipeChildren:
            return wipeChildren(item.url)
        }
    }

    private static func deleteItem(_ item: JunkItem) -> CleanOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: item.url.path) else {
            return .alreadyGone(counted: 0)
        }
        do {
            try fm.removeItem(at: item.url)
        } catch {
            return .refused(leftover: DiskSizer.bytes(at: item.url))
        }
        if fm.fileExists(atPath: item.url.path) {
            return .refused(leftover: DiskSizer.bytes(at: item.url))
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

    private static func wipeChildren(_ url: URL) -> CleanOutcome {
        if Keep.names.contains(url.lastPathComponent) || Keep.isProtected(url) {
            return .refused(leftover: DiskSizer.bytes(at: url))
        }
        let fm = FileManager.default
        let before = DiskSizer.bytes(at: url)
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
        for k in kids {
            if Keep.names.contains(k.lastPathComponent) || Keep.isProtected(k) { continue }
            do { try fm.removeItem(at: k) } catch { anyFail = true }
        }
        let after = DiskSizer.bytes(at: url)
        let freed = max(0, before - after)
        return CleanOutcome(freed: freed, failed: anyFail && after > 16_384, leftover: after)
    }
}
