import XCTest
@testable import CleanAlephaMac98

final class DiskSizerTests: XCTestCase {
    private var tree: FixtureTree!
    private let mb = 1024 * 1024

    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    /// Hidden files were dropped by the old `.skipsHiddenFiles` walk; they must now be counted.
    func testHiddenFilesAreCounted() {
        let visibleOnly = tree.root.appendingPathComponent("a", isDirectory: true)
        tree.write("a/visible.bin", FixtureTree.bytes(mb))
        let base = DiskSizer.bytes(at: visibleOnly)

        tree.write("a/.hidden.bin", FixtureTree.bytes(mb))
        let withHidden = DiskSizer.bytes(at: visibleOnly)

        XCTAssertGreaterThan(withHidden, base, "hidden files must contribute to the size")
    }

    /// Nested files roll up into the parent size.
    func testNestedFilesAreSummed() {
        tree.write("proj/keep.bin", FixtureTree.bytes(mb))
        tree.write("proj/deep/more.bin", FixtureTree.bytes(mb))
        let total = DiskSizer.bytes(at: tree.root.appendingPathComponent("proj"))
        XCTAssertGreaterThan(total, Int64(mb), "should include the nested file")
    }

    /// A `Keep`-protected subtree (path fragment ".gradle") is skipped during the walk.
    func testProtectedSubtreeIsSkipped() {
        tree.write("proj/keep.bin", FixtureTree.bytes(mb))
        tree.write("proj/.gradle/big.bin", FixtureTree.bytes(3 * mb))
        let total = DiskSizer.bytes(at: tree.root.appendingPathComponent("proj"))
        XCTAssertLessThan(total, Int64(2 * mb), "the .gradle subtree must not be counted")
        XCTAssertGreaterThan(total, Int64(mb) / 2, "keep.bin should still count")
    }

    func testCacheReturnsStoredValueThenInvalidatesOnChange() {
        let dir = tree.root.appendingPathComponent("c", isDirectory: true)
        tree.write("c/a.bin", FixtureTree.bytes(mb))

        SizeCache.shared.store(dir, bytes: 4242)
        XCTAssertEqual(SizeCache.shared.lookup(dir), 4242, "same mtime → cache hit")

        // Adding a child bumps the directory mtime → the entry is stale.
        tree.write("c/b.bin", FixtureTree.bytes(mb))
        XCTAssertNil(SizeCache.shared.lookup(dir), "changed mtime → cache miss")
    }
}
