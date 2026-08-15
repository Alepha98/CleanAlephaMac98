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

    static func duSK(_ url: URL, timeout: TimeInterval = 12) -> Int64? {
        let ran = CamProcess.run(path: "/usr/bin/du", arguments: ["-sk", url.path], timeout: timeout)
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
            if Keep.names.contains(fileURL.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if Keep.isProtected(fileURL) {
                enumerator.skipDescendants()
                continue
            }
            n += 1
            if n > 80_000 { break }
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
                  rv.isRegularFile == true else { continue }
            total += Int64(rv.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
