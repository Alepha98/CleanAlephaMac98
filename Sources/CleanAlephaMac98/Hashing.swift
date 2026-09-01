import CryptoKit
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

/// Content fingerprints for duplicate detection.
///
/// `partial` is a cheap prefilter; `full` is the authoritative check. Because the Duplicates
/// module *deletes* files, only a matching **full** SHA-256 is ever treated as identical —
/// head/tail sampling alone can collide on same-size files with different middles.
enum ContentHash {
    private static let chunk = 256 * 1024
    private static let sample = 16 * 1024

    /// Size + head/middle/tail sample, folded into SHA-256. Returns `nil` on read failure so the
    /// file is left in its own bucket (never grouped on incomplete data).
    static func partial(_ url: URL, size: Int64) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        withUnsafeBytes(of: size.littleEndian) { hasher.update(data: Data($0)) }
        do {
            if size <= Int64(sample) * 3 {
                if let all = try fh.readToEnd() { hasher.update(data: all) }
            } else {
                if let head = try fh.read(upToCount: sample) { hasher.update(data: head) }
                try fh.seek(toOffset: UInt64(size / 2))
                if let mid = try fh.read(upToCount: sample) { hasher.update(data: mid) }
                try fh.seek(toOffset: UInt64(size - Int64(sample)))
                if let tail = try fh.read(upToCount: sample) { hasher.update(data: tail) }
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// Full streaming SHA-256 over fixed-size chunks — flat memory even on multi-GB files.
    /// Returns `nil` if any read fails mid-stream, so a truncated digest can never masquerade
    /// as a match.
    static func full(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        do {
            while let data = try fh.read(upToCount: chunk), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
