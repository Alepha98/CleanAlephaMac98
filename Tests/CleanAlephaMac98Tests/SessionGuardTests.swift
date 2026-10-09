import XCTest
@testable import CleanAlephaMac98

/// Who counts as "the open app" that holds a cache. False positives here mean Clean refuses a
/// cache forever (the user presses Clean and nothing goes away); false negatives mean a live
/// session loses files under its feet.
final class SessionGuardTests: XCTestCase {
    private typealias App = SessionGuard.RunningApp

    private let home = FileManager.default.homeDirectoryForCurrentUser
    private func lib(_ rest: String) -> URL { home.appendingPathComponent("Library/" + rest) }

    private let cursorUIService = App(bundleID: "com.apple.TextInputUI.xpc.CursorUIViewService",
                                      name: "CursorUIViewService")

    func testAppleCursorServiceDoesNotHoldCursorEditorCaches() {
        let cache = lib("Application Support/Cursor/CachedData/abc")
        XCTAssertNil(SessionGuard.runningOwner(for: cache, running: [cursorUIService]))
        let editor = App(bundleID: "com.todesktop.230313mzl4w4u92", name: "Cursor")
        XCTAssertEqual(SessionGuard.runningOwner(for: cache, running: [cursorUIService, editor]), "Cursor")
    }

    func testCuratedOwnerIsAuthoritative() {
        // A sibling Google app must not pin Chrome's cache; only Chrome itself does.
        let cache = lib("Application Support/Google/Chrome/Default/Cache")
        let drive = App(bundleID: "com.google.drivefs", name: "Google Drive")
        XCTAssertNil(SessionGuard.runningOwner(for: cache, running: [drive]))
        let chrome = App(bundleID: "com.google.Chrome", name: "Google Chrome")
        XCTAssertEqual(SessionGuard.runningOwner(for: cache, running: [drive, chrome]), "Google Chrome")
    }

    func testUnknownThirdPartyAppStillMatchedByName() {
        let cache = lib("Application Support/Superwhisper/Cache")
        let app = App(bundleID: "com.superduper.superwhisper.desktop", name: "superwhisper")
        XCTAssertEqual(SessionGuard.runningOwner(for: cache, running: [app]), "superwhisper")
    }

    func testAppleServicesNeedAnExactNameMatch() {
        // "viewservice" ⊂ "cursoruiviewservice" is a coincidence, not ownership…
        let partial = lib("Application Support/ViewService/Cache")
        XCTAssertNil(SessionGuard.runningOwner(for: partial, running: [cursorUIService]))
        // …but an Apple app still holds the folder named exactly after it.
        let exact = lib("Application Support/FaceTime/Cache")
        let faceTime = App(bundleID: "com.apple.FaceTime", name: "FaceTime")
        XCTAssertEqual(SessionGuard.runningOwner(for: exact, running: [faceTime]), "FaceTime")
    }

    func testBundleIdCacheFolderMatchesExactly() {
        let cache = lib("Caches/com.example.Tool")
        XCTAssertEqual(
            SessionGuard.runningOwner(for: cache, running: [App(bundleID: "com.example.tool", name: "Tool")]),
            "Tool"
        )
        XCTAssertNil(SessionGuard.runningOwner(for: cache, running: [cursorUIService]))
    }
}
