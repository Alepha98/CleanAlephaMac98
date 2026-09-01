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

    private struct Kind: Sendable {
        let sub: Line
        let onByDefault: Bool
        let needsMarker: Bool
    }

    private static let catalog: [String: Kind] = {
        func dep(_ ru: String, _ en: String) -> Kind { Kind(sub: Line(ru: ru, en: en), onByDefault: false, needsMarker: false) }
        func out(_ ru: String, _ en: String, marker: Bool = false) -> Kind { Kind(sub: Line(ru: ru, en: en), onByDefault: true, needsMarker: marker) }
        return [
            "node_modules": dep("Зависимости — вернутся npm install", "Deps — npm install to restore"),
            ".venv": dep("Python venv — pip install заново", "Python venv — reinstall via pip"),
            "venv": dep("Python venv — pip install заново", "Python venv — reinstall via pip"),
            "Pods": dep("CocoaPods — pod install заново", "CocoaPods — pod install again"),
            "__pycache__": out("Кэш Python — пересоздаётся", "Python cache — regenerates"),
            ".pytest_cache": out("Кэш pytest", "pytest cache"),
            ".mypy_cache": out("Кэш mypy", "mypy cache"),
            ".ruff_cache": out("Кэш ruff", "ruff cache"),
            ".dart_tool": out("Flutter/Dart — пересоберётся", "Flutter/Dart — rebuilds"),
            ".next": out("Сборка Next.js — пересоберётся", "Next.js build — rebuilds"),
            ".nuxt": out("Сборка Nuxt — пересоберётся", "Nuxt build — rebuilds"),
            ".turbo": out("Кэш Turborepo", "Turborepo cache"),
            ".parcel-cache": out("Кэш Parcel", "Parcel cache"),
            ".angular": out("Кэш Angular", "Angular cache"),
            "DerivedData": out("Xcode DerivedData — пересоберётся", "Xcode DerivedData — rebuilds"),
            "build": out("Вывод сборки — пересоберётся", "Build output — rebuilds", marker: true),
            "dist": out("Вывод сборки — пересоберётся", "Build output — rebuilds", marker: true),
            "target": out("Вывод сборки (Rust/JVM)", "Build output (Rust/JVM)", marker: true),
            "out": out("Вывод сборки — пересоберётся", "Build output — rebuilds", marker: true)
        ]
    }()

    private static let markers: Set<String> = [
        "package.json", "cargo.toml", "build.gradle", "build.gradle.kts", "pom.xml",
        "pubspec.yaml", "go.mod", "package.swift", "cmakelists.txt", "tsconfig.json"
    ]

    static func find(in roots: [URL], config: Config = Config()) -> [JunkItem] {
        let fm = FileManager.default
        var items: [JunkItem] = []
        var seen = Set<String>()
        var n = 0
        for root in roots {
            guard let en = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]   // keep hidden (.venv/.next); skip .app internals
            ) else { continue }
            for case let dir as URL in en {
                ScanThrottle.tickSync(every: 400, counter: &n)
                if n > config.walkCap { break }
                let name = dir.lastPathComponent
                if name == ".git" { en.skipDescendants(); continue }
                if Keep.isProtected(dir) { en.skipDescendants(); continue }
                guard let kind = catalog[name] else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                en.skipDescendants() // never walk inside an artifact folder

                if kind.needsMarker, !hasProjectMarker(dir.deletingLastPathComponent()) { continue }
                let bytes = DiskSizer.bytes(at: dir)
                guard bytes >= config.minFolderBytes else { continue }
                let key = dir.standardizedFileURL.path
                guard seen.insert(key).inserted else { continue }

                items.append(JunkItem(
                    id: "art-\(StableID.of(key))",
                    module: .dev,
                    title: Line.proper("\(name) · \(PathFormat.tilde(dir.deletingLastPathComponent()))"),
                    subtitle: kind.sub,
                    url: dir,
                    bytes: bytes,
                    selected: kind.onByDefault,
                    kind: .deleteItem,
                    keepsLogins: false
                ))
            }
        }
        return Array(items.sorted { $0.bytes > $1.bytes }.prefix(config.maxItems))
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
