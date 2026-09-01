import XCTest
@testable import CleanAlephaMac98

final class ImageHashTests: XCTestCase {
    private var tree: FixtureTree!
    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    /// A resized copy of the same scene hashes close; a different scene hashes far.
    func testResizeIsNearAndDifferentSceneIsFar() {
        let a = tree.writeScene("a.png", width: 320, height: 240, seed: 1)
        let b = tree.writeScene("b.png", width: 160, height: 120, seed: 1)   // same scene, smaller
        let c = tree.writeScene("c.png", width: 320, height: 240, seed: 777) // different scene

        guard let ha = ImageHash.dHash(a), let hb = ImageHash.dHash(b), let hc = ImageHash.dHash(c) else {
            return XCTFail("images should decode")
        }
        XCTAssertLessThanOrEqual(ImageHash.distance(ha, hb), 10, "resized copy should be near")
        XCTAssertGreaterThan(ImageHash.distance(ha, hc), ImageHash.distance(ha, hb),
                             "a different scene must be farther than a resize")
    }

    func testNonImageReturnsNil() {
        let txt = tree.write("not-an-image.txt", Data("hello".utf8))
        XCTAssertNil(ImageHash.dHash(txt))
    }
}

final class SimilarImageFinderTests: XCTestCase {
    private var tree: FixtureTree!
    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    /// Similar copies group (keeping one), a distinct image is left alone.
    func testGroupsSimilarKeepsOneLeavesDistinct() {
        tree.writeScene("dup/big.png", width: 480, height: 360, seed: 5)
        tree.writeScene("dup/small.png", width: 240, height: 180, seed: 5)  // similar to big
        tree.writeScene("other.png", width: 480, height: 360, seed: 42)     // distinct

        let cfg = SimilarImageFinder.Config(minFileBytes: 0, maxDistance: 12)
        let items = SimilarImageFinder.find(in: [tree.root], config: cfg)
        let flagged = Set(items.map { $0.url.lastPathComponent })

        XCTAssertEqual(items.count, 1, "one of the similar pair is offered, the other kept")
        XCTAssertTrue(flagged.isSubset(of: ["big.png", "small.png"]))
        XCTAssertFalse(flagged.contains("other.png"), "a distinct image must not be flagged")
        XCTAssertTrue(items.allSatisfy { $0.module == .duplicates && $0.selected == false })
    }

    func testNoFalsePairsAmongDistinctImages() {
        for i in 0..<5 {
            tree.writeScene("img\(i).png", width: 300, height: 200, seed: UInt64(1000 + i * 131))
        }
        let cfg = SimilarImageFinder.Config(minFileBytes: 0)
        XCTAssertTrue(SimilarImageFinder.find(in: [tree.root], config: cfg).isEmpty,
                      "distinct scenes should not be grouped")
    }
}
