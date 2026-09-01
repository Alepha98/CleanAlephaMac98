import XCTest
@testable import CleanAlephaMac98

/// The `Keep` guard is the last line of defense before deletion — pin its invariants.
final class KeepInvariantTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser

    func testAlwaysProtectedRoots() {
        let protectedSuffixes = [
            ".colima",
            "Parallels/Windows 11.pvm",
            ".gradle/caches/x",
            "Library/Developer/CoreSimulator/Devices",
            "Library/Application Support/Claude/vm_bundles/x",
            "Pictures/Photos Library.photoslibrary",
            "Library/Mobile Documents/com~apple~CloudDocs/Personal/x"
        ]
        for suffix in protectedSuffixes {
            XCTAssertTrue(Keep.isProtected(home.appendingPathComponent(suffix)),
                          "\(suffix) must be protected")
        }
    }

    func testOrdinaryPathIsNotProtected() {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cam98-unprotected")
        XCTAssertFalse(Keep.isProtected(tmp))
    }

    func testRootsCannotBeExcluded() {
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/")))
        XCTAssertFalse(Keep.canExclude(home))
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/System")))
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/System/Library")))
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/Library")))
        XCTAssertTrue(Keep.canExclude(FileManager.default.temporaryDirectory.appendingPathComponent("proj")))
    }
}

final class ByteFormatTests: XCTestCase {
    private let nbsp = "\u{00A0}"

    func testUnits() {
        XCTAssertEqual(ByteFormat.string(0, .en), "0\(nbsp)B")
        XCTAssertEqual(ByteFormat.string(1_048_576, .en), "1\(nbsp)MB")
        XCTAssertEqual(ByteFormat.string(1_073_741_824, .en), "1.00\(nbsp)GB")
        XCTAssertTrue(ByteFormat.string(1_073_741_824, .ru).contains("ГБ"))
    }

    func testNegativeClampsToZero() {
        XCTAssertEqual(ByteFormat.string(-42, .en), "0\(nbsp)B")
    }
}
