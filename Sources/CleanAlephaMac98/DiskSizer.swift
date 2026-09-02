import Foundation

enum DiskSizer {
    /// Directory size, native and parallel: sum `totalFileAllocatedSize` over the tree, fanning
    /// out across top-level children, memoized in `SizeCache`. Hidden files are counted (they were
    /// silently dropped before), and there is no fixed file-count cap. Protected paths return 0.
    static func bytes(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if Keep.isProtected(url) { return 0 }
        if !isDir.boolValue { return fileSize(url) }
        if let cached = SizeCache.shared.lookup(url) { return cached }
        let total = parallelSize(url)
        SizeCache.shared.store(url, bytes: total)
        return total
    }

    /// Trash bins often hold packages (.app, .dmg mounts). Prefer `du`, then a walk that does not
    /// skip package descendants or hidden names inside the bin.
    static func trashBytes(at url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            return 0
        }
        if let du = duSK(url, timeout: 20), du > 0 { return du }
        return trashWalk(url)
    }

    /// Kernel-side `du -sk`. Kept for callers that want a fast, timeout-bounded estimate
    /// (protected-root ring, Space Lens) without populating the cache.
    static func duSK(_ url: URL, timeout: TimeInterval = 12) -> Int64? {
        ScanThrottle.beginWorker()
        let ran = CamProcess.run(path: "/usr/bin/du", arguments: ["-sk", url.path], timeout: timeout)
        ScanThrottle.reliefIfNeeded()
        guard !ran.timedOut, ran.status == 0 else { return nil }
        let kb = Int64(ran.out.split(whereSeparator: { $0.isWhitespace }).first.flatMap { Int64($0) } ?? 0)
        return kb * 1024
    }

    // MARK: - Native sizer

    /// Fan the top-level subdirectories out across cores, sum their walked sizes plus the direct
    /// files. One level of parallelism keeps memory flat while using the machine.
    private static func parallelSize(_ dir: URL) -> Int64 {
        let fm = FileManager.default
        guard let kids = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey],
            options: []
        ) else { return 0 }

        var subdirs: [URL] = []
        var fileTotal: Int64 = 0
        for kid in kids {
            if Keep.names.contains(kid.lastPathComponent) { continue }
            if Keep.isProtected(kid) { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: kid.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                subdirs.append(kid)
            } else {
                fileTotal += fileSize(kid)
            }
        }
        guard !subdirs.isEmpty else { return fileTotal }

        let acc = Accumulator()
        acc.add(fileTotal)
        DispatchQueue.concurrentPerform(iterations: subdirs.count) { i in
            acc.add(walk(subdirs[i]))
        }
        return acc.value
    }

    /// Recursive sizer for one subtree. Includes hidden files; skips package descendants and any
    /// `Keep`-protected / credential-named node. No hard file-count cap — cooperative yields only.
    static func walk(_ url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey],
            options: [.skipsPackageDescendants]
        ) else { return 0 }
        var total: Int64 = 0
        var n = 0
        for case let fileURL as URL in enumerator {
            ScanThrottle.tickSync(every: 2_000, counter: &n)
            let name = fileURL.lastPathComponent
            if Keep.names.contains(name) || Keep.isProtected(fileURL) {
                enumerator.skipDescendants()
                continue
            }
            guard let rv = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey]),
                  rv.isRegularFile == true else { continue }
            total += Int64(rv.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func fileSize(_ url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        guard let rv = try? url.resourceValues(forKeys: keys) else { return 0 }
        return Int64(rv.totalFileAllocatedSize ?? rv.fileAllocatedSize ?? rv.fileSize ?? 0)
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

    /// Lock-guarded Int64 accumulator for the parallel fan-out.
    private final class Accumulator: @unchecked Sendable {
        private let lock = NSLock()
        private var v: Int64 = 0
        func add(_ x: Int64) { lock.lock(); v += x; lock.unlock() }
        var value: Int64 { lock.lock(); defer { lock.unlock() }; return v }
    }
}
