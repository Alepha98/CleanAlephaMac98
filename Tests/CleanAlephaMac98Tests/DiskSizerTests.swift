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

    /// The fts walker must agree with the per-file allocated sizes the old enumerator summed.
    func testMatchesSumOfPerFileAllocatedSizes() {
        tree.write("m/a.bin", FixtureTree.bytes(mb))
        tree.write("m/b/c.bin", FixtureTree.bytes(3 * mb / 2, seed: 3))
        tree.write("m/b/.d.bin", FixtureTree.bytes(700_000, seed: 9))
        tree.write("m/b/e/f.txt", Data("small".utf8))
        let dir = tree.root.appendingPathComponent("m")

        var expected: Int64 = 0
        let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])!
        for case let url as URL in en {
            let rv = try? url.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey])
            if rv?.isRegularFile == true { expected += Int64(rv?.totalFileAllocatedSize ?? 0) }
        }
        XCTAssertEqual(DiskSizer.walk(dir), expected)
    }

    /// A hard-linked file frees its blocks once — it must be counted once.
    func testHardLinkCountedOnce() throws {
        let a = tree.write("h/a.bin", FixtureTree.bytes(2 * mb))
        let single = DiskSizer.walk(tree.root.appendingPathComponent("h"))
        try FileManager.default.linkItem(at: a, to: tree.root.appendingPathComponent("h/b.bin"))
        XCTAssertEqual(DiskSizer.walk(tree.root.appendingPathComponent("h")), single)
    }

    /// Symlinks are never followed (a link to something big elsewhere isn't this folder's size).
    func testSymlinkNotFollowed() throws {
        let big = tree.write("elsewhere/big.bin", FixtureTree.bytes(4 * mb))
        tree.write("s/own.bin", FixtureTree.bytes(mb))
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("s/link.bin"), withDestinationURL: big)
        try FileManager.default.createSymbolicLink(
            at: tree.root.appendingPathComponent("s/linkdir"), withDestinationURL: big.deletingLastPathComponent())
        XCTAssertLessThan(DiskSizer.walk(tree.root.appendingPathComponent("s")), Int64(2 * mb))
    }

    /// Credential / login-data names (Keep.names) are never counted, file or folder.
    func testCredentialNamesAreNotCounted() {
        tree.write("k/plain.bin", FixtureTree.bytes(mb))
        tree.write("k/Cookies", FixtureTree.bytes(3 * mb))
        tree.write("k/Local Storage/leveldb.bin", FixtureTree.bytes(3 * mb))
        XCTAssertLessThan(DiskSizer.walk(tree.root.appendingPathComponent("k")), Int64(2 * mb))
    }

    /// Package contents count — a wipe of the parent frees them too.
    func testPackageContentsAreCounted() {
        tree.write("p/Updater.app/Contents/MacOS/Updater", FixtureTree.bytes(2 * mb))
        XCTAssertGreaterThan(DiskSizer.walk(tree.root.appendingPathComponent("p")), Int64(mb))
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
