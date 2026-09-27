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
    /// files. One level of parallelism keeps memory flat while using the machine. Direct children are
    /// `lstat`-ed (no URL objects / resource values), and protection uses one exclusions snapshot —
    /// this runs for every card we size, many of which are flat folders full of small files.
    private static func parallelSize(_ dir: URL) -> Int64 {
        let root = dir.standardizedFileURL.path
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return 0 }
        let extras = Keep.extraPaths

        var subdirs: [URL] = []
        var fileTotal: Int64 = 0
        var st = stat()
        for name in names {
            if Keep.names.contains(name) { continue }
            let path = root.hasSuffix("/") ? root + name : root + "/" + name
            guard lstat(path, &st) == 0 else { continue }
            let type = st.st_mode & S_IFMT
            guard type == S_IFDIR || type == S_IFREG else { continue }  // symlinks & specials: never followed
            if Keep.isProtected(path: path, extras: extras) { continue }
            if type == S_IFDIR {
                subdirs.append(URL(fileURLWithPath: path, isDirectory: true))
            } else {
                fileTotal += Int64(st.st_blocks) * 512
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

    /// Recursive sizer for one subtree, on `fts(3)` — the traversal `du` uses. Stat data arrives with
    /// each entry, so there is no per-file URL object or resource-value lookup; the old Foundation
    /// enumerator also ran the full `Keep.isProtected` (path standardization + UserDefaults read) on
    /// every *file*, and was ~3× slower than `du` on node_modules-sized trees.
    ///
    /// Counts hidden files and package contents (what a wipe actually frees), never follows symlinks
    /// or crosses volumes, counts a hard-linked file once, and prunes `Keep`-protected / credential-
    /// named subtrees at the directory — protection is checked per directory, not per file.
    static func walk(_ url: URL) -> Int64 {
        let root = url.standardizedFileURL.path
        let extras = Keep.extraPaths            // one UserDefaults read per walk, not per file
        let extraFiles = Set(extras)
        if Keep.isProtected(path: root, extras: extras) { return 0 }

        guard let cRoot = strdup(root) else { return 0 }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        // FTS_NOCHDIR is required: we walk from several threads and chdir is process-wide.
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
        defer { fts_close(fts) }

        var total: Int64 = 0
        var linked = Set<InodeKey>()
        var n = 0
        while let ent = fts_read(fts) {
            ScanThrottle.tickSync(every: 2_000, counter: &n)
            switch Int32(ent.pointee.fts_info) {
            case FTS_D:
                if ent.pointee.fts_level > 0, isKeptName(ent) {
                    _ = fts_set(fts, ent, FTS_SKIP)
                    continue
                }
                let dir = String(cString: ent.pointee.fts_path)
                // Protected if the directory itself matches, or if every path inside it would
                // (a fragment like "/Parallels/" only matches once a child is appended).
                if Keep.isProtected(path: dir, extras: extras) || Keep.isProtected(path: dir + "/", extras: extras) {
                    _ = fts_set(fts, ent, FTS_SKIP)
                }
            case FTS_F:
                if isKeptName(ent) { continue }
                if !extraFiles.isEmpty, extraFiles.contains(String(cString: ent.pointee.fts_path)) { continue }
                guard let st = ent.pointee.fts_statp?.pointee else { continue }
                if st.st_nlink > 1, !linked.insert(InodeKey(dev: st.st_dev, ino: st.st_ino)).inserted {
                    continue
                }
                total += Int64(st.st_blocks) * 512
            default:
                continue // post-order dirs, symlinks, unreadable / unstat-able entries
            }
        }
        return total
    }

    private struct InodeKey: Hashable {
        let dev: Int32
        let ino: UInt64
    }

    /// Lengths of `Keep.names` — lets the walker reject almost every entry without building a String.
    private static let keptNameLengths = Set(Keep.names.map(\.utf8.count))

    /// Is this entry's own name a credential / login-data name we never count or touch?
    private static func isKeptName(_ ent: UnsafeMutablePointer<FTSENT>) -> Bool {
        let len = Int(ent.pointee.fts_namelen)
        guard keptNameLengths.contains(len) else { return false }
        let name = String(cString: ent.pointee.fts_path + (Int(ent.pointee.fts_pathlen) - len))
        return Keep.names.contains(name)
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
