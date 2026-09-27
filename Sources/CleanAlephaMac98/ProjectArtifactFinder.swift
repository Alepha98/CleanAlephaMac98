import Foundation

/// Finds regenerable project artifacts sitting *inside* the user's code folders — node_modules,
/// build/, .next, target, .venv, Pods, __pycache__, … — anywhere under the common project roots,
/// not just at fixed paths. This is the biggest reclaim for a developer machine.
///
/// Safety split: build **output** (rebuilds automatically) is on by default; **dependency**
/// folders (need an explicit `npm install` / `pip install` / `pod install`) are off. Generic
/// names (`build`/`dist`/`target`/`out`) count only when a project marker sits alongside.
enum ProjectArtifactFinder {
    struct Config: Sendable {
        var minFolderBytes: Int64 = 5_242_880   // 5MB
        var maxItems: Int = 300
        var walkCap: Int = 200_000
    }

    /// Which artifacts to report. Build output (rebuilds itself, on by default) is cheap to size and
    /// rides along with Smart; dependency folders (node_modules / .venv / Pods — off by default, the
    /// heaviest trees to size) are only walked when the Developer layer is opened.
    enum Scope: Sendable { case all, outputs, dependencies }

    /// What an artifact folder is, which decides how it may be cleaned. Matches Keep's safety
    /// model: only emptying a regenerable cache in place counts as safe to pre-select — deleting a
    /// user-visible folder is always an explicit choice.
    private enum Role: Sendable {
        /// Regenerates transparently, holds nothing of the user's (__pycache__, .next, DerivedData…):
        /// pre-selected and emptied in place.
        case cache
        /// Generic build output (build/dist/target/out): regenerable, but may hold a deliverable the
        /// user wants (a packaged .app or release binary in dist/) — reviewed, not pre-selected.
        case build
        /// Needs an explicit reinstall (npm/pip/pod install) — reviewed, and only sized on demand.
        case dependency
    }

    private struct Kind: Sendable {
        let sub: Line
        let role: Role
        var onByDefault: Bool { role == .cache }
        /// Generic names count only with a project marker alongside.
        var needsMarker: Bool { role == .build }
        var isDependency: Bool { role == .dependency }
        var cleanKind: CleanKind { role == .cache ? .wipeChildren : .deleteItem }
    }

    private static let catalog: [String: Kind] = {
        func dep(_ ru: String, _ en: String) -> Kind { Kind(sub: Line(ru: ru, en: en), role: .dependency) }
        func cache(_ ru: String, _ en: String) -> Kind { Kind(sub: Line(ru: ru, en: en), role: .cache) }
        func build(_ ru: String, _ en: String) -> Kind { Kind(sub: Line(ru: ru, en: en), role: .build) }
        return [
            "node_modules": dep("Зависимости — вернутся npm install", "Deps — npm install to restore"),
            ".venv": dep("Python venv — pip install заново", "Python venv — reinstall via pip"),
            "venv": dep("Python venv — pip install заново", "Python venv — reinstall via pip"),
            "Pods": dep("CocoaPods — pod install заново", "CocoaPods — pod install again"),
            "__pycache__": cache("Кэш Python — пересоздаётся", "Python cache — regenerates"),
            ".pytest_cache": cache("Кэш pytest", "pytest cache"),
            ".mypy_cache": cache("Кэш mypy", "mypy cache"),
            ".ruff_cache": cache("Кэш ruff", "ruff cache"),
            ".dart_tool": cache("Flutter/Dart — пересоберётся", "Flutter/Dart — rebuilds"),
            ".next": cache("Сборка Next.js — пересоберётся", "Next.js build — rebuilds"),
            ".nuxt": cache("Сборка Nuxt — пересоберётся", "Nuxt build — rebuilds"),
            ".turbo": cache("Кэш Turborepo", "Turborepo cache"),
            ".parcel-cache": cache("Кэш Parcel", "Parcel cache"),
            ".angular": cache("Кэш Angular", "Angular cache"),
            "DerivedData": cache("Xcode DerivedData — пересоберётся", "Xcode DerivedData — rebuilds"),
            "build": build("Вывод сборки — проверь, нет ли там нужного", "Build output — check nothing you need is inside"),
            "dist": build("Вывод сборки — проверь, нет ли там нужного", "Build output — check nothing you need is inside"),
            "target": build("Вывод сборки (Rust/JVM) — проверь", "Build output (Rust/JVM) — check first"),
            "out": build("Вывод сборки — проверь, нет ли там нужного", "Build output — check nothing you need is inside")
        ]
    }()

    private static let markers: Set<String> = [
        "package.json", "cargo.toml", "build.gradle", "build.gradle.kts", "pom.xml",
        "pubspec.yaml", "go.mod", "package.swift", "cmakelists.txt", "tsconfig.json"
    ]

    static func find(in roots: [URL], scope: Scope = .all, config: Config = Config()) -> [JunkItem] {
        let extras = Keep.extraPaths   // one UserDefaults read, not one per entry
        var candidates: [(url: URL, kind: Kind)] = []
        var seen = Set<String>()
        var walked = 0
        for root in roots where walked <= config.walkCap {
            for (dir, kind) in discover(root, extras: extras, walked: &walked, cap: config.walkCap) {
                if scope == .outputs, kind.isDependency { continue }
                if scope == .dependencies, !kind.isDependency { continue }
                if kind.needsMarker, !hasProjectMarker(dir.deletingLastPathComponent()) { continue }
                guard seen.insert(dir.path).inserted else { continue }
                candidates.append((dir, kind))
            }
        }

        // Size the candidates concurrently: most are small folders (__pycache__, build/) where the
        // cost is syscall latency, not bandwidth — keeping several in flight is what `du` can't do.
        let work = candidates
        let sink = ItemSink()
        DispatchQueue.concurrentPerform(iterations: work.count) { i in
            let (dir, kind) = work[i]
            let bytes = DiskSizer.bytes(at: dir)
            guard bytes >= config.minFolderBytes else { return }
            sink.add(JunkItem(
                id: "art-\(StableID.of(dir.path))",
                module: .dev,
                title: Line.proper("\(dir.lastPathComponent) · \(PathFormat.tilde(dir.deletingLastPathComponent()))"),
                subtitle: kind.sub,
                url: dir,
                bytes: bytes,
                selected: kind.onByDefault,
                kind: kind.cleanKind,
                keepsLogins: false
            ))
        }
        return Array(sink.all.sorted { ($0.bytes, $0.id) > ($1.bytes, $1.id) }.prefix(config.maxItems))
    }

    /// Package extensions we never walk into (what Foundation's `.skipsPackageDescendants` did).
    private static let bundleExtensions: Set<String> = [
        "app", "framework", "bundle", "plugin", "appex", "kext", "xpc", "dsym",
        "xcodeproj", "xcworkspace", "xcarchive", "playground",
        "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "logicx", "band",
        "rtfd", "pages", "numbers", "key", "sketch"
    ]

    /// Every artifact directory under `root`, via fts with FTS_NOSTAT: directories are known from
    /// readdir's d_type and files are never stat-ed or turned into URLs. Never descends into an
    /// artifact, `.git`, a bundle, or a `Keep`-protected directory — protection is checked before an
    /// artifact is ever reported.
    private static func discover(
        _ root: URL, extras: [String], walked: inout Int, cap: Int
    ) -> [(URL, Kind)] {
        guard let cRoot = strdup(root.standardizedFileURL.path) else { return [] }
        defer { free(cRoot) }
        var argv: [UnsafeMutablePointer<CChar>?] = [cRoot, nil]
        guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV | FTS_NOSTAT, nil) else {
            return []
        }
        defer { fts_close(fts) }

        var out: [(URL, Kind)] = []
        while let ent = fts_read(fts) {
            ScanThrottle.tickSync(every: 400, counter: &walked)
            if walked > cap { break }
            guard Int32(ent.pointee.fts_info) == FTS_D else { continue }
            let path = String(cString: ent.pointee.fts_path)
            if Keep.isProtected(path: path, extras: extras) || Keep.isProtected(path: path + "/", extras: extras) {
                _ = fts_set(fts, ent, FTS_SKIP)
                continue
            }
            guard ent.pointee.fts_level > 0 else { continue }
            let nameLen = Int(ent.pointee.fts_namelen)
            let name = String(cString: ent.pointee.fts_path + (Int(ent.pointee.fts_pathlen) - nameLen))
            if name == ".git" {
                _ = fts_set(fts, ent, FTS_SKIP)
            } else if let kind = catalog[name] {
                _ = fts_set(fts, ent, FTS_SKIP)   // never walk inside an artifact folder
                out.append((URL(fileURLWithPath: path, isDirectory: true), kind))
            } else if let dot = name.lastIndex(of: "."), dot != name.startIndex,
                      bundleExtensions.contains(name[name.index(after: dot)...].lowercased()) {
                _ = fts_set(fts, ent, FTS_SKIP)
            }
        }
        return out
    }

    private final class ItemSink: @unchecked Sendable {
        private let lock = NSLock()
        private var xs: [JunkItem] = []
        func add(_ x: JunkItem) { lock.lock(); xs.append(x); lock.unlock() }
        var all: [JunkItem] { lock.lock(); defer { lock.unlock() }; return xs }
    }

    private static func hasProjectMarker(_ projectDir: URL) -> Bool {
        guard let kids = try? FileManager.default.contentsOfDirectory(atPath: projectDir.path) else {
            return false
        }
        for kid in kids {
            let low = kid.lowercased()
            if markers.contains(low) { return true }
            if low.hasSuffix(".xcodeproj") || low.hasPrefix("vite.config.") || low.hasPrefix("next.config.") {
                return true
            }
        }
        return false
    }

    /// Common project parents that exist on this Mac.
    static func defaultRoots() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ["Desktop", "Documents", "Downloads", "Projects", "Developer", "Code", "dev", "src", "repos", "work"]
            .map { home.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
