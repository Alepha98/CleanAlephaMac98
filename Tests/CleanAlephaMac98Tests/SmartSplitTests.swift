import XCTest
@testable import CleanAlephaMac98

/// Smart is a fast, safe pass; the heavy review stages (Large, Duplicates, Developer's project walk)
/// run only when their layer is opened.
final class ScanStagePartitionTests: XCTestCase {
    // Module-qualified: in a test target Foundation's own `Scanner` (NSScanner) is also in scope.
    private typealias Stage = CleanAlephaMac98.Scanner.ScanStage

    func testSmartNeverRunsADeepStage() {
        let smart = Stage.stages(for: .smart)
        XCTAssertFalse(smart.isEmpty)
        XCTAssertTrue(smart.allSatisfy { !$0.isDeep }, "Smart must stay light: \(smart.filter(\.isDeep))")
        for heavy in [Stage.large, .duplicates, .projects, .deepSearch] {
            XCTAssertFalse(smart.contains(heavy), "\(heavy) is on demand, not part of Smart")
        }
    }

    func testEveryStageHasExactlyOnePath() {
        let smart = Set(Stage.stages(for: .smart))
        let deep = Set(Stage.allCases.filter(\.isDeep))
        XCTAssertTrue(smart.isDisjoint(with: deep))
        XCTAssertEqual(smart.union(deep), Set(Stage.allCases), "a stage that runs nowhere would be dead code")
    }

    func testLayersStillRunAllTheirOwnStages() {
        let dev: [Stage] = Stage.stages(for: Module.dev)
        let large: [Stage] = Stage.stages(for: Module.large)
        let duplicates: [Stage] = Stage.stages(for: Module.duplicates)
        let junk: [Stage] = Stage.stages(for: Module.junk)
        let deepSearch: [Stage] = Stage.stages(for: Module.deepSearch)
        XCTAssertEqual(dev, [Stage.dev, Stage.projects], "opening Developer runs both halves")
        XCTAssertEqual(large, [Stage.large])
        XCTAssertEqual(duplicates, [Stage.duplicates])
        XCTAssertEqual(junk, [Stage.junk], "the forensic hunts moved out of Junk")
        XCTAssertEqual(deepSearch, [Stage.deepSearch])
    }

    func testModuleClassification() {
        XCTAssertTrue(Module.large.isDeepOnly)
        XCTAssertTrue(Module.duplicates.isDeepOnly)
        XCTAssertTrue(Module.deepSearch.isDeepOnly, "Deep search only runs when opened")
        XCTAssertTrue(Module.dev.hasDeepStages)
        XCTAssertFalse(Module.dev.isDeepOnly, "Developer's caches still ride along with Smart")
        for light in [Module.junk, .trash, .leftovers, .browsers, .messengers, .privacy, .mail] {
            XCTAssertFalse(light.hasDeepStages, "\(light) is fully covered by Smart")
        }
        // Non-scan layers have no stages at all.
        XCTAssertFalse(Module.uninstaller.hasDeepStages)
        XCTAssertFalse(Module.uninstaller.isDeepOnly)
    }
}

@MainActor
final class DeepLayerStateTests: XCTestCase {
    func testSmartResultsDoNotCoverDeepLayers() {
        let state = AppState()
        state.scannedModules = [.smart]
        XCTAssertTrue(state.hasScanned(.junk), "light layers borrow Smart's results")
        XCTAssertTrue(state.hasScanned(.browsers))
        XCTAssertFalse(state.hasScanned(.large), "Large wasn't scanned by Smart — opening it scans")
        XCTAssertFalse(state.hasScanned(.duplicates))
        XCTAssertFalse(state.hasScanned(.deepSearch), "the forensic hunts never ride along with Smart")
        XCTAssertFalse(state.hasScanned(.dev), "Developer's project walk still has to run")
    }

    func testDeepLayerCountsOnlyAfterItsOwnScan() {
        let state = AppState()
        state.scannedModules = [.smart, .large]
        XCTAssertTrue(state.hasScanned(.large))
        XCTAssertFalse(state.hasScanned(.duplicates))
    }

    func testSentBackToOrbIsNotScanned() {
        let state = AppState()
        state.scannedModules = [.smart, .large]
        state.resultsDismissed = [.large]
        XCTAssertFalse(state.hasScanned(.large), "«Scan again» waits for the user's own Scan press")
    }
}
