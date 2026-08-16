import Foundation

enum DiskSizer {
    static func bytes(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if Keep.isProtected(url) { return 0 }
        if let du = duSK(url), du > 0 { return du }
        if !isDir.boolValue { return fileSize(url) }
        return walk(url)
    }

    /// Trash bins often hold packages (.app, .dmg mounts). Prefer `du`, then a walk that
    /// does not skip package descendants or hidden names inside the bin.
    static func trashBytes(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        if let du = duSK(url, timeout: 20), du > 0 { return du }
        return trashWalk(url)
    }

    static func duSK(_ url: URL, timeout: TimeInterval = 12) -> Int64? {
        ScanThrottle.beginWorker()
        let ran = CamProcess.run(path: "/usr/bin/du", arguments: ["-sk", url.path], timeout: timeout)
        ScanThrottle.reliefIfNeeded()
        guard !ran.timedOut, ran.status == 0 else { return nil }
        let kb = Int64(ran.out.split(whereSeparator: { $0.isWhitespace }).first.flatMap { Int64($0) } ?? 0)
        return kb * 1024
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? rv.fileSize ?? 0)
    }

    private static func walk(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let fileURL as URL in enumerator {
            ScanThrottle.tickSync(every: 400, counter: &n)
            if Keep.names.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if Keep.isProtected(fileURL) {
                enumerator.skipDescendants()
                continue
            }
            if n > 80_000 { break }
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
                  rv.isRegularFile == true else { continue }
            total += Int64(rv.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func trashWalk(_ url: URL) -> Int64 {
        guard let kids = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return 0 }
        var total: Int64 = 0
        for kid in kids {
            if kid.lastPathComponent == ".DS_Store" { continue }
            if Keep.isProtected(kid) { continue }
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: kid.path, isDirectory: &isDir), isDir.boolValue {
                if let du = duSK(kid, timeout: 8), du > 0 {
                    total += du
                } else {
                    total += walk(kid)
                }
            } else {
                total += fileSize(kid)
            }
        }
        return total
    }
}
