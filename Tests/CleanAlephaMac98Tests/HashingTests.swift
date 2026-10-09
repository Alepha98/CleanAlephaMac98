import XCTest
@testable import CleanAlephaMac98

final class HashingTests: XCTestCase {
    func testStableIDIsDeterministicAndDistinct() {
        XCTAssertEqual(StableID.of("/Users/a/Library/Caches/foo"),
                       StableID.of("/Users/a/Library/Caches/foo"))
        XCTAssertNotEqual(StableID.of("/a/b"), StableID.of("/a/c"))
        XCTAssertFalse(StableID.of("").isEmpty)
    }
}
