import XCTest
@testable import CleanAlephaMac98

/// Every refused or partial clean must say why in the log ("failed 22" alone was useless).
final class CleanReasonTests: XCTestCase {
    private var tree: FixtureTree!

    override func setUp() {
        super.setUp()
        tree = FixtureTree()
    }

    override func tearDown() {
        tree.tearDown()
        super.tearDown()
    }

    private func card(_ url: URL, kind: CleanKind = .wipeChildren) -> JunkItem {
        JunkItem(
            id: "reason-test-\(url.lastPathComponent)",
            module: .junk,
            title: Line.proper(url.lastPathComponent),
            subtitle: Line.proper("fixture"),
            url: url,
            bytes: 0,
            selected: true,
            kind: kind,
            keepsLogins: false
        )
    }

    func testProtectedNameIsNamed() {
        let cookies = tree.root.appendingPathComponent("Cookies", isDirectory: true)
        tree.write("Cookies/keep.bin", FixtureTree.bytes(4_096))
        let outcome = Janitor.clean(card(cookies))
        XCTAssertTrue(outcome.failed)
        XCTAssertEqual(outcome.reason, "protected-name")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cookies.appendingPathComponent("keep.bin").path))
    }

    func testPartialWipeNamesFirstFailureAndCause() throws {
        let cache = tree.root.appendingPathComponent("SomeCache", isDirectory: true)
        tree.write("SomeCache/gone.bin", FixtureTree.bytes(40_000))
        tree.write("SomeCache/locked/stuck.bin", FixtureTree.bytes(40_000))
        let locked = cache.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let outcome = Janitor.clean(card(cache))
        XCTAssertTrue(outcome.failed)
        let reason = try XCTUnwrap(outcome.reason)
        XCTAssertTrue(reason.hasPrefix("partial: 1 not removed, first locked: "), reason)
        XCTAssertTrue(reason.contains("Permission denied"), reason)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cache.appendingPathComponent("gone.bin").path))
    }

    func testCleanJobHasNoReason() {
        let cache = tree.root.appendingPathComponent("FineCache", isDirectory: true)
        tree.write("FineCache/a.bin", FixtureTree.bytes(40_000))
        let outcome = Janitor.clean(card(cache))
        XCTAssertFalse(outcome.failed)
        XCTAssertNil(outcome.reason)
    }

    func testLogLineCarriesReasonSizeAndPath() {
        let url = tree.root.appendingPathComponent("X")
        let line = Janitor.logLine(
            "auto skip",
            card(url),
            .refused(leftover: 2_000_000, blockedApp: "Google Chrome", reason: "open-app: Google Chrome")
        )
        XCTAssertTrue(line.hasPrefix("auto skip open-app: Google Chrome | "), line)
        XCTAssertTrue(line.hasSuffix("| " + PathFormat.tilde(url)), line)
    }

    func testOwnLogSurvivesTheUserLogsCard() {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        XCTAssertTrue(Keep.isProtected(logs.appendingPathComponent("CleanAlephaMac98.log")))
        XCTAssertFalse(Keep.isProtected(logs.appendingPathComponent("SomeOtherApp.log")))
        XCTAssertFalse(Keep.isProtected(logs))
    }
}
