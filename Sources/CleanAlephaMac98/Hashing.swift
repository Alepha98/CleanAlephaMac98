import Foundation

/// Deterministic, process-stable id source.
///
/// `String.hashValue` is seeded per launch (SipHash), so it must never feed a persisted id —
/// doing so silently breaks `Keep.dismissedIds` (a hidden card reappears after relaunch).
/// FNV-1a over UTF-8 is small, allocation-free, and stable across runs and machines.
enum StableID {
    static func of(_ s: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 36)
    }
}
