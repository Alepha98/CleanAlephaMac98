import XCTest
@testable import CleanAlephaMac98

final class HashingTests: XCTestCase {
    private var tree: FixtureTree!
    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    func testStableIDIsDeterministicAndDistinct() {
        XCTAssertEqual(StableID.of("/Users/a/Library/Caches/foo"),
                       StableID.of("/Users/a/Library/Caches/foo"))
        XCTAssertNotEqual(StableID.of("/a/b"), StableID.of("/a/c"))
        XCTAssertFalse(StableID.of("").isEmpty)
    }

    func testFullHashMatchesForIdenticalContentAndDiffersOtherwise() {
        let a = tree.write("a.bin", FixtureTree.bytes(300 * 1024))
        let b = tree.write("b.bin", FixtureTree.bytes(300 * 1024))
        var otherData = FixtureTree.bytes(300 * 1024)
        otherData[123] ^= 0x01
        let c = tree.write("c.bin", otherData)

        XCTAssertEqual(ContentHash.full(a), ContentHash.full(b))
        XCTAssertNotEqual(ContentHash.full(a), ContentHash.full(c))
    }

    func testPartialReturnsNilForMissingFile() {
        let missing = tree.root.appendingPathComponent("nope.bin")
        XCTAssertNil(ContentHash.full(missing))
        XCTAssertNil(ContentHash.partial(missing, size: 1024))
    }
}
