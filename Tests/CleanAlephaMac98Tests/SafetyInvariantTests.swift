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
        XCTAssertFalse(Keep.isProtected(home.appendingPathComponent("Downloads/cam98-unprotected")))
        XCTAssertFalse(Keep.isProtected(FixtureTree.base.appendingPathComponent("x")))
    }

    /// System temp/cache areas are never writable through the normal cleaner — only
    /// SystemDeepScanner's narrow opt-in cards may cross that line. Holds for both the canonical
    /// /private path and the /var, /tmp symlinks, and for the fast path-based form the walkers use.
    func testSystemTempRootsAreProtected() {
        for path in ["/private/var/folders/ab/cd/T/x", "/var/folders/ab/cd/C/y", "/private/tmp/z", "/tmp/z",
                     "/private/var/log/system.log", "/Library/Caches/com.apple.x"] {
            XCTAssertTrue(Keep.isProtected(URL(fileURLWithPath: path)), "\(path) must be protected")
        }
        XCTAssertTrue(Keep.isProtected(path: "/private/var/folders/ab/cd/T/x", extras: []))
        XCTAssertFalse(Keep.isProtected(path: "/private/variable/x", extras: []), "prefix match is by path component")
    }

    /// The fast path-based check the fts walkers use must agree with the URL form.
    func testPathFormAgreesWithURLForm() {
        let paths = [
            home.appendingPathComponent(".gradle/caches").path,
            home.appendingPathComponent("Downloads/a").path,
            home.appendingPathComponent("Library/Developer/CoreSimulator/Devices").path,
            "/private/var/folders/x", "/Library/Logs/y", "/Users/Shared/z"
        ]
        let extras = Keep.extraPaths
        for p in paths {
            XCTAssertEqual(Keep.isProtected(path: p, extras: extras), Keep.isProtected(URL(fileURLWithPath: p)), p)
        }
    }

    func testRootsCannotBeExcluded() {
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/")))
        XCTAssertFalse(Keep.canExclude(home))
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/System")))
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/System/Library")))
        XCTAssertFalse(Keep.canExclude(URL(fileURLWithPath: "/Library")))
        XCTAssertTrue(Keep.canExclude(home.appendingPathComponent("Downloads/proj")))
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
