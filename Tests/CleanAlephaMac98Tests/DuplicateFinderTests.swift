import XCTest
@testable import CleanAlephaMac98

final class DuplicateFinderTests: XCTestCase {
    private var tree: FixtureTree!
    private let mb = 1024 * 1024

    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    /// The safety-critical case: two files with identical size, head, sampled-middle and tail,
    /// but one differing byte the partial sampler never reads. They must NOT be reported —
    /// only the full SHA-256 decides identity.
    func testSameSizeDifferentMiddleIsNotADuplicate() {
        var a = FixtureTree.bytes(2 * mb)
        var b = a
        b[512 * 1024] ^= 0xFF // outside head/mid/tail sample windows
        tree.write("a.bin", a)
        tree.write("b.bin", b)
        a.removeAll()

        let found = DuplicateFinder.find(in: [tree.root])
        XCTAssertTrue(found.items.isEmpty, "different content must never be flagged as a duplicate")
    }

    /// True duplicates: a set of N identical files yields N-1 deletable items (one is kept).
    func testTrueDuplicatesKeepExactlyOne() {
        let data = FixtureTree.bytes(2 * mb, seed: 7)
        tree.write("x/one.bin", data)
        tree.write("y/two.bin", data)
        tree.write("z/three.bin", data)

        let found = DuplicateFinder.find(in: [tree.root])
        XCTAssertEqual(found.items.count, 2, "3 identical files → keep 1, offer 2")
        XCTAssertTrue(found.items.allSatisfy { $0.module == .duplicates && $0.selected == false })
    }

    /// Sub-1MB files are noise and must be ignored even when byte-identical.
    func testTinyFilesAreIgnored() {
        let data = FixtureTree.bytes(500 * 1024)
        tree.write("small1.bin", data)
        tree.write("small2.bin", data)

        let found = DuplicateFinder.find(in: [tree.root])
        XCTAssertTrue(found.items.isEmpty)
    }

    /// A copy that lives in a Downloads folder is the one offered for deletion; the working
    /// original elsewhere is kept.
    func testKeepPrefersNonDownloadsCopy() {
        let data = FixtureTree.bytes(2 * mb, seed: 3)
        let keep = tree.write("Projects/report.bin", data)
        let dup = tree.write("Downloads/report.bin", data)

        let found = DuplicateFinder.find(in: [tree.root])
        XCTAssertEqual(found.items.count, 1)
        XCTAssertEqual(found.items.first?.url.standardizedFileURL, dup.standardizedFileURL,
                       "the Downloads copy should be the deletable one")
        XCTAssertNotEqual(found.items.first?.url.standardizedFileURL, keep.standardizedFileURL)
    }

    /// Ids must be stable across runs so "dismiss" persists.
    func testDuplicateIdsAreStable() {
        let data = FixtureTree.bytes(2 * mb, seed: 11)
        tree.write("a/f.bin", data)
        tree.write("b/f.bin", data)

        let first = DuplicateFinder.find(in: [tree.root]).items.map(\.id).sorted()
        let second = DuplicateFinder.find(in: [tree.root]).items.map(\.id).sorted()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
    }
}
