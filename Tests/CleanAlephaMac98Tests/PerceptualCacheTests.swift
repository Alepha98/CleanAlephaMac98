import XCTest
@testable import CleanAlephaMac98

final class PerceptualCacheTests: XCTestCase {
    private var tree: FixtureTree!
    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    func testReusesHashWhileFileUnchangedAndRecomputesOnChange() {
        let url = tree.write("a.bin", Data("one".utf8))
        let cache = PerceptualCache()
        var calls = 0

        XCTAssertEqual(cache.hash(for: url) { _ in calls += 1; return 42 }, 42)
        XCTAssertEqual(calls, 1)

        // Unchanged file → cache hit, no recompute.
        XCTAssertEqual(cache.hash(for: url) { _ in calls += 1; return 99 }, 42)
        XCTAssertEqual(calls, 1, "unchanged file must not recompute")

        // Different size (and mtime) → invalidated, recompute.
        try? Data("changed!!".utf8).write(to: url)
        XCTAssertEqual(cache.hash(for: url) { _ in calls += 1; return 7 }, 7)
        XCTAssertEqual(calls, 2, "a changed file must recompute")
    }

    func testMissingFileFallsBackToComputeAndIsNotCached() {
        let cache = PerceptualCache()
        let missing = tree.root.appendingPathComponent("nope.bin")
        var calls = 0
        XCTAssertEqual(cache.hash(for: missing) { _ in calls += 1; return 9 }, 9)
        XCTAssertEqual(cache.hash(for: missing) { _ in calls += 1; return 9 }, 9)
        XCTAssertEqual(calls, 2, "a file we can't stat is recomputed each time, never cached")
    }
}
