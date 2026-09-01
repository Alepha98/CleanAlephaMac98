import XCTest
@testable import CleanAlephaMac98

private final class ConcCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var high = 0
    func enter() { lock.lock(); current += 1; high = max(high, current); lock.unlock() }
    func leave() { lock.lock(); current -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return high }
}

final class ScanCoordinatorTests: XCTestCase {
    /// Every input is processed exactly once (order is completion-based, so compare as a set).
    func testStreamsEveryResult() async {
        let inputs = Array(0..<25)
        var out: [Int] = []
        for await v in ScanCoordinator.stream(inputs, maxConcurrency: 4, work: { $0 * 2 }) {
            out.append(v)
        }
        XCTAssertEqual(out.count, inputs.count)
        XCTAssertEqual(Set(out), Set(inputs.map { $0 * 2 }))
    }

    /// Never more than `maxConcurrency` work items run at once.
    func testRespectsConcurrencyCap() async {
        let gate = ConcCounter()
        let cap = 3
        let inputs = Array(0..<20)
        var count = 0
        for await _ in ScanCoordinator.stream(inputs, maxConcurrency: cap, work: { i -> Int in
            gate.enter()
            Thread.sleep(forTimeInterval: 0.01)
            gate.leave()
            return i
        }) {
            count += 1
        }
        XCTAssertEqual(count, inputs.count)
        XCTAssertLessThanOrEqual(gate.peak, cap, "must never exceed the concurrency cap")
    }

    /// Breaking out early terminates the stream without hanging.
    func testEarlyBreakDoesNotHang() async {
        let inputs = Array(0..<200)
        var seen = 0
        for await _ in ScanCoordinator.stream(inputs, maxConcurrency: 2, work: { i -> Int in
            Thread.sleep(forTimeInterval: 0.003)
            return i
        }) {
            seen += 1
            if seen >= 3 { break }
        }
        XCTAssertEqual(seen, 3)
    }
}
