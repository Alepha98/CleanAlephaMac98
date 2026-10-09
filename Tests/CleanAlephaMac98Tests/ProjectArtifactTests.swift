import XCTest
@testable import CleanAlephaMac98

final class ProjectArtifactTests: XCTestCase {
    private var tree: FixtureTree!
    private let mb = 1024 * 1024

    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    func testFindsArtifactsWithSafeDefaults() {
        tree.write("proj/package.json", Data("{}".utf8))
        tree.write("proj/node_modules/lib/big.bin", FixtureTree.bytes(6 * mb))
        tree.write("proj/build/out.bin", FixtureTree.bytes(6 * mb))
        tree.write("proj/.venv/lib/big.bin", FixtureTree.bytes(6 * mb))
        // A `build/` with no project marker alongside must be ignored.
        tree.write("randomdir/build/thing.bin", FixtureTree.bytes(6 * mb))

        tree.write("proj/.next/cache/chunk.bin", FixtureTree.bytes(6 * mb))
        let items = ProjectArtifactFinder.find(in: [tree.root])
        let byName = Dictionary(grouping: items) { $0.url.lastPathComponent }

        XCTAssertEqual(byName["node_modules"]?.first?.selected, false, "deps off by default")
        XCTAssertEqual(byName[".venv"]?.first?.selected, false, "deps off by default")
        XCTAssertEqual(byName["build"]?.first?.selected, false, "build/ may hold a deliverable — review")
        XCTAssertEqual(byName["build"]?.first?.kind, .deleteItem)
        XCTAssertEqual(byName[".next"]?.first?.selected, true, "a pure cache is pre-selected")
        XCTAssertEqual(byName[".next"]?.first?.kind, .wipeChildren, "a cache is emptied in place")
        XCTAssertEqual(byName["build"]?.count, 1, "unmarked build/ must not be flagged")
        XCTAssertTrue(items.allSatisfy { $0.module == .dev })
    }

    /// Keep's rule (also enforced by the QA harness): a pre-selected card must be safe-preset.
    func testEveryPreselectedArtifactIsSafePreset() {
        tree.write("proj/package.json", Data("{}".utf8))
        for name in ["node_modules", "build", "dist", ".next", ".turbo", "__pycache__", "DerivedData", ".venv"] {
            tree.write("proj/\(name)/blob.bin", FixtureTree.bytes(6 * mb))
        }
        let items = ProjectArtifactFinder.find(in: [tree.root])
        XCTAssertGreaterThanOrEqual(items.count, 8)
        for item in items where item.selected {
            XCTAssertTrue(item.isSafePreset, "\(item.url.lastPathComponent) is pre-selected but not safe-preset")
        }
    }

    /// Smart gets the build output; the Developer layer's deep stage gets the dependency folders.
    func testScopeSplitsOutputsFromDependencies() {
        tree.write("proj/package.json", Data("{}".utf8))
        tree.write("proj/node_modules/lib/big.bin", FixtureTree.bytes(6 * mb))
        tree.write("proj/build/out.bin", FixtureTree.bytes(6 * mb))
        let outputs = Set(ProjectArtifactFinder.find(in: [tree.root], scope: .outputs).map(\.url.lastPathComponent))
        let deps = Set(ProjectArtifactFinder.find(in: [tree.root], scope: .dependencies).map(\.url.lastPathComponent))
        XCTAssertEqual(outputs, ["build"])
        XCTAssertEqual(deps, ["node_modules"])
    }

    func testSkipsTooSmall() {
        tree.write("p/package.json", Data("{}".utf8))
        tree.write("p/node_modules/x.bin", FixtureTree.bytes(mb)) // < 5MB floor
        XCTAssertTrue(ProjectArtifactFinder.find(in: [tree.root]).isEmpty)
    }

    func testDoesNotDescendIntoArtifacts() {
        // A node_modules containing a nested build/ with a package.json must yield only the
        // node_modules card, not the inner build (we skip descendants).
        tree.write("proj/package.json", Data("{}".utf8))
        tree.write("proj/node_modules/pkg/package.json", Data("{}".utf8))
        tree.write("proj/node_modules/pkg/build/x.bin", FixtureTree.bytes(6 * mb))

        let names = Set(ProjectArtifactFinder.find(in: [tree.root]).map { $0.url.lastPathComponent })
        XCTAssertTrue(names.contains("node_modules"))
        XCTAssertFalse(names.contains("build"), "must not walk inside node_modules")
    }
}
