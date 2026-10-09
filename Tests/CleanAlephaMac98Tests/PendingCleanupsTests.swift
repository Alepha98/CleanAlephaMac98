import XCTest
@testable import CleanAlephaMac98

/// Refused-because-open cache jobs wait in a queue and are cleaned when their app quits.
final class PendingCleanupsTests: XCTestCase {
    private func item(_ id: String, kind: CleanKind = .wipeChildren) -> JunkItem {
        JunkItem(id: id, module: .junk, title: Line.proper(id), subtitle: Line.proper("t"),
                 url: URL(fileURLWithPath: "/Users/x/Library/Caches/\(id)"), bytes: 1_000,
                 selected: true, kind: kind, keepsLogins: false)
    }

    func testOnlyCacheWipesAreDeferred() {
        XCTAssertNotNil(PendingCleanups.entry(for: item("a"), owner: "Google Chrome"))
        XCTAssertNotNil(PendingCleanups.entry(for: item("b", kind: .safariNetworkCache), owner: "Safari"))
        XCTAssertNil(PendingCleanups.entry(for: item("c", kind: .deleteItem), owner: "Cursor"))
        XCTAssertNil(PendingCleanups.entry(for: item("d", kind: .emptyTrash), owner: "Finder"))
    }

    func testEntryRoundTripsToTheSameJob() throws {
        let original = item("chrome-cache")
        let entry = try XCTUnwrap(PendingCleanups.entry(for: original, owner: "Google Chrome"))
        let rebuilt = try XCTUnwrap(PendingCleanups.item(from: entry))
        XCTAssertEqual(rebuilt.id, original.id)
        XCTAssertEqual(rebuilt.url, original.url)
        XCTAssertEqual(rebuilt.kind, original.kind)
        XCTAssertEqual(rebuilt.module, original.module)
    }

    func testMergeUpsertsForgetsAndExpires() throws {
        let now = Date()
        let old = try XCTUnwrap(PendingCleanups.entry(for: item("old"), owner: "X", now: now.addingTimeInterval(-4 * 86_400)))
        let kept = try XCTUnwrap(PendingCleanups.entry(for: item("kept"), owner: "X", now: now))
        let done = try XCTUnwrap(PendingCleanups.entry(for: item("done"), owner: "X", now: now))
        let new = try XCTUnwrap(PendingCleanups.entry(for: item("new"), owner: "Y", now: now))
        let merged = PendingCleanups.merge([old, kept, done], refused: [new], finished: ["done"], now: now)
        XCTAssertEqual(merged.map(\.id), ["kept", "new"])
    }

    func testDrainKeepsJobsWhoseAppIsStillOpen() throws {
        let entries = try ["open", "gone", "denied"].map { try XCTUnwrap(PendingCleanups.entry(for: item($0), owner: "X")) }
        let result = PendingCleanups.drain(entries) { job in
            switch job.id {
            case "open": return .refused(leftover: 1_000, blockedApp: "X", reason: "open-app: X")
            case "denied": return .refused(leftover: 1_000, reason: "error: Operation not permitted")
            default: return CleanOutcome(freed: 1_000, failed: false, leftover: 0)
            }
        }
        XCTAssertEqual(result.left.map(\.id), ["open"])
        XCTAssertEqual(result.cleaned, 1)
        XCTAssertEqual(result.freed, 1_000)
        XCTAssertEqual(result.failures.map { $0.0.id }, ["denied"])
    }

    func testStoreRoundTrip() throws {
        let tree = FixtureTree(); defer { tree.tearDown() }
        let url = tree.root.appendingPathComponent("pending.json")
        let e = try XCTUnwrap(PendingCleanups.entry(for: item("z"), owner: "Claude"))
        PendingCleanups.save([e], to: url)
        XCTAssertEqual(PendingCleanups.load(from: url).map(\.id), ["z"])
        PendingCleanups.save([], to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
