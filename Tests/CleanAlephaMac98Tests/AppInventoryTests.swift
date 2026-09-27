import XCTest
@testable import CleanAlephaMac98

final class AppInventoryTests: XCTestCase {
    private let inv = AppInventory(
        names: ["visualstudiocode", "googlechrome", "cursor", "spotify"],
        bundleIDs: ["com.spotify.client", "com.google.chrome", "com.microsoft.vscode"]
    )

    func testBundleIdFolderMatches() {
        XCTAssertTrue(inv.hasOwner("com.spotify.client"))          // exact
        XCTAssertTrue(inv.hasOwner("com.google.Chrome"))           // case-insensitive
        XCTAssertTrue(inv.hasOwner("com.google.Chrome.helper"))    // child of an installed id
    }

    func testPlainNameFolderMatches() {
        XCTAssertTrue(inv.hasOwner("Google"))   // token of googlechrome
        XCTAssertTrue(inv.hasOwner("Cursor"))
        XCTAssertTrue(inv.hasOwner("Spotify"))
    }

    func testAppleAndSelfAlwaysOwned() {
        XCTAssertTrue(inv.hasOwner("com.apple.Safari"))
        XCTAssertTrue(inv.hasOwner("Apple"))
        XCTAssertTrue(inv.hasOwner("CleanAlephaMac98"))
    }

    func testUnknownHasNoOwner() {
        XCTAssertFalse(inv.hasOwner("com.unknown.widget"))
        XCTAssertFalse(inv.hasOwner("SomeRandomVendor"))
    }

    func testTooShortTokenDoesNotMatch() {
        XCTAssertFalse(inv.hasOwner("ab"))
    }
}
