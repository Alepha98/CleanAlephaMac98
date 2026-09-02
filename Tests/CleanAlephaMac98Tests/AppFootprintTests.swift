import XCTest
@testable import CleanAlephaMac98

final class AppFootprintTests: XCTestCase {
    private var tree: FixtureTree!
    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    // MARK: belongs — precise, conservative attribution

    func testBelongsMatchesExactChildAndParentIDs() {
        XCTAssertTrue(AppFootprint.belongs(stem: "com.google.Chrome", bundleID: "com.google.Chrome", name: "Google Chrome"))
        // helper child id belongs to the parent app…
        XCTAssertTrue(AppFootprint.belongs(stem: "com.google.Chrome.helper", bundleID: "com.google.Chrome", name: "Google Chrome"))
        // …and a parent id belongs when the app *is* the child (com.google.Chrome ⊂ com.google.Chrome.helper).
        XCTAssertTrue(AppFootprint.belongs(stem: "com.google.Chrome", bundleID: "com.google.Chrome.helper", name: "x"))
    }

    func testBelongsMatchesTeamPrefixedGroupByName() {
        XCTAssertTrue(AppFootprint.belongs(stem: "UBF8T346G9.Spotify", bundleID: "", name: "Spotify"))
    }

    func testBelongsRejectsUnrelatedAndTooShort() {
        XCTAssertFalse(AppFootprint.belongs(stem: "com.other.app", bundleID: "com.keep.me", name: "KeepMe"))
        XCTAssertFalse(AppFootprint.belongs(stem: "ab", bundleID: "", name: "ab"), "2-char names are too ambiguous to match")
    }

    // MARK: footprint — the uninstaller primitive

    func testFootprintCollectsResidueAcrossLocationsAndIgnoresOtherApps() {
        tree.write("Library/Caches/com.keep.me/data.bin", FixtureTree.bytes(1000))
        tree.write("Library/Preferences/com.keep.me.plist", FixtureTree.bytes(1000))
        tree.write("Library/Cookies/com.keep.me.binarycookies", FixtureTree.bytes(1000))
        tree.write("Library/Logs/KeepMe/run.log", FixtureTree.bytes(1000))
        tree.write("Library/Saved Application State/com.keep.me.savedState/window.data", FixtureTree.bytes(1000))
        // A different app's residue must not come back.
        tree.write("Library/Caches/com.other.app/x.bin", FixtureTree.bytes(1000))

        let found = Set(
            AppFootprint.footprint(bundleID: "com.keep.me", name: "KeepMe", home: tree.root)
                .map { $0.lastPathComponent }
        )
        XCTAssertEqual(found, [
            "com.keep.me", "com.keep.me.plist", "com.keep.me.binarycookies",
            "KeepMe", "com.keep.me.savedState"
        ])
        XCTAssertFalse(found.contains("com.other.app"))
    }

    // MARK: orphans — Cookies + per-app Logs of removed apps

    func testOrphansFlagsRemovedAppsOnly() {
        let inv = AppInventory(names: ["keepme"], bundleIDs: ["com.keep.me"])

        // Removed apps → flagged.
        tree.write("Library/Cookies/com.gone.app.binarycookies", FixtureTree.bytes(20_000))
        tree.write("Library/Logs/GoneApp/session.log", FixtureTree.bytes(2_200_000))
        // Installed app → skipped (owned).
        tree.write("Library/Cookies/com.keep.me.binarycookies", FixtureTree.bytes(20_000))
        tree.write("Library/Logs/KeepMe/app.log", FixtureTree.bytes(2_200_000))
        // Apple + system-log denylist → skipped.
        tree.write("Library/Cookies/com.apple.Safari.binarycookies", FixtureTree.bytes(20_000))
        tree.write("Library/Logs/DiagnosticReports/x.ips", FixtureTree.bytes(2_200_000))
        // Below the size floors → skipped.
        tree.write("Library/Cookies/com.tiny.app.binarycookies", FixtureTree.bytes(1_000))
        tree.write("Library/Logs/SmallGone/tiny.log", FixtureTree.bytes(1_000))

        let items = AppFootprint.orphans(inventory: inv, home: tree.root)
        let flagged = Set(items.map { $0.url.lastPathComponent })

        XCTAssertEqual(flagged, ["com.gone.app.binarycookies", "GoneApp"])
        XCTAssertTrue(items.allSatisfy { $0.module == .leftovers && $0.selected == false })
        // Cookies is a single file → deleteItem; a Logs folder → wipeChildren.
        let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.url.lastPathComponent, $0) })
        XCTAssertEqual(byName["com.gone.app.binarycookies"]?.kind, .deleteItem)
        XCTAssertEqual(byName["GoneApp"]?.kind, .wipeChildren)
    }

    func testOrphansEmptyWhenNothingRemoved() {
        let inv = AppInventory(names: ["keepme"], bundleIDs: ["com.keep.me"])
        tree.write("Library/Cookies/com.keep.me.binarycookies", FixtureTree.bytes(20_000))
        XCTAssertTrue(AppFootprint.orphans(inventory: inv, home: tree.root).isEmpty)
    }
}
