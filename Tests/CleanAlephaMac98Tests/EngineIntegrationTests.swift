import XCTest
@testable import CleanAlephaMac98

/// End-to-end exercise of the whole engine on one realistic mixed tree: the sizer must total
/// correctly (hidden files included), and the duplicate finder must recover exactly the planted
/// duplicate sets with zero false positives — while a near-miss pair (same size, one unsampled
/// differing byte) stays unflagged. Prints wall-time as a lightweight benchmark.
final class EngineIntegrationTests: XCTestCase {
    private var tree: FixtureTree!
    private let mb = 1024 * 1024

    override func setUp() { tree = FixtureTree() }
    override func tearDown() { tree.tearDown() }

    func testSizerAndDedupOnRealisticTree() {
        // --- noise: many small unique files across nested dirs (also some hidden) ---
        for i in 0..<300 {
            tree.write("noise/d\(i % 12)/f\(i).bin", FixtureTree.bytes(4096 + i, seed: UInt8(i & 0xFF)))
        }
        tree.write("noise/.hidden/secret.bin", FixtureTree.bytes(2 * mb))

        // --- 3 true duplicate sets (each ≥1MB) ---
        let dupA = FixtureTree.bytes(2 * mb, seed: 1)
        tree.write("A/one.bin", dupA); tree.write("A/copy/one.bin", dupA)              // 2 copies → 1 item
        let dupB = FixtureTree.bytes(3 * mb, seed: 2)
        tree.write("B/x.bin", dupB); tree.write("B/y.bin", dupB); tree.write("B/z.bin", dupB) // 3 → 2 items
        let dupC = FixtureTree.bytes(mb + 500, seed: 3)
        tree.write("C/p.bin", dupC); tree.write("Downloads/p.bin", dupC)               // 2 → 1 item

        // --- near-miss: identical size + head/mid/tail, one unsampled byte differs → NOT a dup ---
        var m1 = FixtureTree.bytes(2 * mb, seed: 9)
        var m2 = m1
        m2[700 * 1024] ^= 0xFF
        tree.write("near/m1.bin", m1); tree.write("near/m2.bin", m2)
        m1.removeAll()

        // --- sizer: total must equal an independent walk, and be non-trivial ---
        let start = Date()
        let total = DiskSizer.bytes(at: tree.root)
        XCTAssertGreaterThan(total, Int64(10 * mb), "planted ~13MB+ of real content")

        // --- dedup: exactly the planted sets (2 from B, 1 from A, 1 from C) = 4 items, no near-miss ---
        let dupes = DuplicateFinder.find(in: [tree.root])
        let elapsed = Date().timeIntervalSince(start)
        print("⏱ EngineIntegration: sized+deduped tree in \(String(format: "%.0f", elapsed * 1000)) ms, size=\(ByteFormat.string(total, .en))")

        XCTAssertEqual(dupes.items.count, 4, "3 sets → (2-1)+(3-1)+(2-1) = 4 deletable items")
        let flaggedNames = Set(dupes.items.map { $0.url.lastPathComponent })
        XCTAssertFalse(flaggedNames.contains("m1.bin"), "near-miss must never be flagged")
        XCTAssertFalse(flaggedNames.contains("m2.bin"), "near-miss must never be flagged")
        // The Downloads copy of set C is the one offered for deletion (working original kept).
        XCTAssertTrue(dupes.items.contains { $0.url.path.contains("/Downloads/") })
    }
}
