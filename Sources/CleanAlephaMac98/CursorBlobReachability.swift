import Foundation
import SQLite3

/// Read-only counterpart of Cursor's `developer.gcAgentKvBlobs` reachability pass.
///
/// Cursor stores recent conversations as protobuf graphs in `cursorDiskKV`. Blob IDs are
/// SHA-256 values, embedded as 32-byte protobuf fields (and occasionally as hexadecimal
/// strings). This audit starts from the same four root families as Cursor's own GC and
/// follows content-addressed references without mutating the database. The result remains
/// advice-only: Cursor's private protobuf walker is authoritative at deletion time.
enum CursorBlobReachability {
    struct Result {
        let totalBlobs: Int
        let reachableBlobs: Int
        let candidateBlobs: Int
        let candidateLogicalBytes: Int64
        let rootStates: Int
        let inspectedLogicalBytes: Int64
        let errors: Int
        let complete: Bool
        let elapsedMilliseconds: Int
    }

    private struct Digest: Hashable {
        let a: UInt64
        let b: UInt64
        let c: UInt64
        let d: UInt64

        init?(hex: String) {
            guard hex.utf8.count == 64 else { return nil }
            let bytes = Array(hex.utf8)
            var words = [UInt64](repeating: 0, count: 4)
            for index in 0..<32 {
                guard let high = Self.nibble(bytes[index * 2]),
                      let low = Self.nibble(bytes[index * 2 + 1]) else { return nil }
                let byte = UInt64(high << 4 | low)
                words[index / 8] = (words[index / 8] << 8) | byte
            }
            a = words[0]
            b = words[1]
            c = words[2]
            d = words[3]
        }

        init(bytes: UnsafeRawBufferPointer, offset: Int) {
            func word(_ start: Int) -> UInt64 {
                var value: UInt64 = 0
                for index in 0..<8 {
                    value = (value << 8) | UInt64(bytes[offset + start + index])
                }
                return value
            }
            a = word(0)
            b = word(8)
            c = word(16)
            d = word(24)
        }

        var hex: String {
            let digits = Array("0123456789abcdef".utf8)
            var output = [UInt8]()
            output.reserveCapacity(64)
            for word in [a, b, c, d] {
                for shift in stride(from: 56, through: 0, by: -8) {
                    let byte = UInt8((word >> UInt64(shift)) & 0xff)
                    output.append(digits[Int(byte >> 4)])
                    output.append(digits[Int(byte & 0x0f)])
                }
            }
            return String(decoding: output, as: UTF8.self)
        }

        private static func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 48...57: return byte - 48
            case 65...70: return byte - 55
            case 97...102: return byte - 87
            default: return nil
            }
        }
    }

    private static let blobPrefix = "agentKv:blob:"
    private static let rootPrefixes = ["composerData:", "bubbleId:"]
    private static let checkpointPrefixes = ["agentKv:checkpoint:", "agentKv:bubbleCheckpoint:"]
    static func audit(
        database url: URL,
        deadlineSeconds: TimeInterval = 240,
        cancellation: ScanCancellation? = nil
    ) -> Result? {
        let started = Date()
        let deadline = started.addingTimeInterval(deadlineSeconds)
        var database: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              let database else {
            if database != nil { sqlite3_close_v2(database) }
            return nil
        }
        defer { sqlite3_close_v2(database) }
        sqlite3_busy_timeout(database, 2_000)

        guard let sizes = blobSizes(database: database, cancellation: cancellation),
              !sizes.isEmpty,
              cancellation?.isCancelled != true else { return nil }
        let known = Set(sizes.keys)
        var reachable = Set<Digest>()
        var queue: [Digest] = []
        var errors = 0
        var rootStates = 0
        var inspectedBytes: Int64 = 0
        var processedBlobs = 0
        var timedOut = false

        func add(_ digest: Digest) {
            guard known.contains(digest), reachable.insert(digest).inserted else { return }
            queue.append(digest)
        }

        func scan(_ data: Data, requireProtobuf: Bool) {
            data.withUnsafeBytes { bytes in
                if looksTextual(bytes) {
                    collectASCIIHexReferences(bytes, known: known, add: add)
                }
                let valid = collectProtobufReferences(
                    bytes,
                    range: 0..<bytes.count,
                    depth: 0,
                    known: known,
                    add: add
                )
                if requireProtobuf, !valid { errors += 1 }
            }
        }

        for prefix in rootPrefixes where !timedOut {
            if cancellation?.isCancelled == true { timedOut = true; break }
            // Returning only the tiny root field avoids copying multi-gigabyte bubble JSON
            // through Swift. SQLite still validates every row; a malformed row aborts this
            // audit and therefore can never turn into a deletion recommendation.
            let sql = "SELECT json_extract(value, '$.conversationState') "
                + "FROM cursorDiskKV WHERE key GLOB '\(prefix)*'"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                errors += 1
                continue
            }
            defer { sqlite3_finalize(statement) }
            var step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if Date() >= deadline || cancellation?.isCancelled == true {
                    timedOut = true
                    break
                }
                guard let text = sqlite3_column_text(statement, 0) else {
                    step = sqlite3_step(statement)
                    continue
                }
                let state = String(cString: text)
                guard !state.isEmpty else {
                    step = sqlite3_step(statement)
                    continue
                }
                guard let decoded = decodeConversationState(state), !decoded.isEmpty else {
                    if state != "~" { errors += 1 }
                    step = sqlite3_step(statement)
                    continue
                }
                guard Date() < deadline else {
                    timedOut = true
                    break
                }
                if decoded.count > 64 * 1_048_576 {
                    errors += 1
                    step = sqlite3_step(statement)
                    continue
                }
                rootStates += 1
                scan(decoded, requireProtobuf: true)
                step = sqlite3_step(statement)
            }
            if !timedOut, step != SQLITE_DONE { errors += 1 }
        }

        for prefix in checkpointPrefixes where !timedOut {
            if cancellation?.isCancelled == true { timedOut = true; break }
            var statement: OpaquePointer?
            let sql = "SELECT value FROM cursorDiskKV WHERE key GLOB '\(prefix)*'"
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                errors += 1
                continue
            }
            defer { sqlite3_finalize(statement) }
            while sqlite3_step(statement) == SQLITE_ROW {
                if Date() >= deadline || cancellation?.isCancelled == true {
                    timedOut = true
                    break
                }
                let raw = columnData(statement, index: 0)
                guard let value = String(data: raw, encoding: .utf8),
                      let digest = Digest(hex: value.lowercased()) else {
                    errors += 1
                    continue
                }
                add(digest)
            }
        }

        var readStatement: OpaquePointer?
        if sqlite3_prepare_v2(
            database,
            "SELECT value FROM cursorDiskKV WHERE key = ?1",
            -1,
            &readStatement,
            nil
        ) != SQLITE_OK {
            errors += 1
        }
        if let readStatement {
            defer { sqlite3_finalize(readStatement) }
            var index = 0
            while index < queue.count {
                if Date() >= deadline || cancellation?.isCancelled == true {
                    timedOut = true
                    break
                }
                let digest = queue[index]
                index += 1
                processedBlobs = index
                let key = blobPrefix + digest.hex
                sqlite3_reset(readStatement)
                sqlite3_clear_bindings(readStatement)
                _ = key.withCString { pointer in
                    sqlite3_bind_text(readStatement, 1, pointer, -1, sqliteTransient)
                }
                guard sqlite3_step(readStatement) == SQLITE_ROW else {
                    errors += 1
                    continue
                }
                let count = Int(sqlite3_column_bytes(readStatement, 0))
                inspectedBytes += Int64(count)
                guard count > 0, let pointer = sqlite3_column_blob(readStatement, 0) else { continue }
                let bytes = UnsafeRawBufferPointer(start: pointer, count: count)
                if looksTextual(bytes) {
                    collectASCIIHexReferences(bytes, known: known, add: add)
                }
                _ = collectProtobufReferences(
                    bytes,
                    range: 0..<count,
                    depth: 0,
                    known: known,
                    add: add
                )
            }
        } else {
            timedOut = true
        }

        let complete = !timedOut && errors == 0
        let candidates = known.subtracting(reachable)
        let candidateBytes = candidates.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        CamLog.line(
            "cursor blob graph total=\(known.count) reachable=\(reachable.count) "
                + "candidates=\(candidates.count) bytes=\(candidateBytes) roots=\(rootStates) "
                + "processed=\(processedBlobs)/\(queue.count) inspected=\(inspectedBytes) "
                + "errors=\(errors) timeout=\(timedOut) ms=\(elapsed)"
        )
        return Result(
            totalBlobs: known.count,
            reachableBlobs: reachable.count,
            candidateBlobs: candidates.count,
            candidateLogicalBytes: candidateBytes,
            rootStates: rootStates,
            inspectedLogicalBytes: inspectedBytes,
            errors: errors,
            complete: complete,
            elapsedMilliseconds: elapsed
        )
    }

    private static var sqliteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    private static func blobSizes(
        database: OpaquePointer,
        cancellation: ScanCancellation? = nil
    ) -> [Digest: Int64]? {
        let sql = "SELECT substr(key, \(blobPrefix.count + 1)), length(value) "
            + "FROM cursorDiskKV WHERE key GLOB '\(blobPrefix)*'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        var values: [Digest: Int64] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            if cancellation?.isCancelled == true { return nil }
            guard let text = sqlite3_column_text(statement, 0),
                  let digest = Digest(hex: String(cString: text)) else { continue }
            values[digest] = sqlite3_column_int64(statement, 1)
        }
        return values
    }

    private static func columnData(_ statement: OpaquePointer, index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let pointer = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: pointer, count: count)
    }

    private static func decodeConversationState(_ value: String) -> Data? {
        if value.hasPrefix("~") {
            return Data(base64Encoded: String(value.dropFirst()))
        }
        guard value.utf8.count.isMultiple(of: 2) else { return nil }
        let input = Array(value.utf8)
        var output = Data(capacity: input.count / 2)
        var index = 0
        while index < input.count {
            guard let high = hexNibble(input[index]), let low = hexNibble(input[index + 1]) else { return nil }
            output.append(high << 4 | low)
            index += 2
        }
        return output
    }

    private static func collectASCIIHexReferences(
        _ bytes: UnsafeRawBufferPointer,
        known: Set<Digest>,
        add: (Digest) -> Void
    ) {
        guard bytes.count >= 64 else { return }
        var cursor = 0
        while cursor < bytes.count {
            while cursor < bytes.count, hexNibble(bytes[cursor]) == nil { cursor += 1 }
            let start = cursor
            while cursor < bytes.count, hexNibble(bytes[cursor]) != nil { cursor += 1 }
            if cursor - start == 64 {
                let string = String(decoding: bytes[start..<cursor], as: UTF8.self)
                if let digest = Digest(hex: string), known.contains(digest) { add(digest) }
            }
        }
    }

    private static func looksTextual(_ bytes: UnsafeRawBufferPointer) -> Bool {
        guard !bytes.isEmpty else { return false }
        let sample = min(bytes.count, 4_096)
        var printable = 0
        for index in 0..<sample {
            let byte = bytes[index]
            if byte == 9 || byte == 10 || byte == 13 || (32...126).contains(byte) {
                printable += 1
            }
        }
        return printable * 100 >= sample * 85
    }

    @discardableResult
    private static func collectProtobufReferences(
        _ bytes: UnsafeRawBufferPointer,
        range: Range<Int>,
        depth: Int,
        known: Set<Digest>,
        add: (Digest) -> Void
    ) -> Bool {
        guard !range.isEmpty, depth <= 10 else { return range.isEmpty }
        var cursor = range.lowerBound
        while cursor < range.upperBound {
            guard let tag = readVarint(bytes, cursor: &cursor, limit: range.upperBound), tag > 0 else {
                return false
            }
            switch Int(tag & 7) {
            case 0:
                guard readVarint(bytes, cursor: &cursor, limit: range.upperBound) != nil else { return false }
            case 1:
                guard cursor <= range.upperBound - 8 else { return false }
                cursor += 8
            case 2:
                guard let rawLength = readVarint(bytes, cursor: &cursor, limit: range.upperBound),
                      rawLength <= UInt64(Int.max) else { return false }
                let length = Int(rawLength)
                guard length >= 0, cursor <= range.upperBound - length else { return false }
                let payload = cursor..<(cursor + length)
                if length == 32 {
                    let digest = Digest(bytes: bytes, offset: cursor)
                    if known.contains(digest) { add(digest) }
                }
                if length == 64 {
                    let string = String(decoding: bytes[payload], as: UTF8.self)
                    if let digest = Digest(hex: string), known.contains(digest) { add(digest) }
                }
                if depth < 10, length > 1 {
                    _ = collectProtobufReferences(
                        bytes,
                        range: payload,
                        depth: depth + 1,
                        known: known,
                        add: add
                    )
                }
                cursor += length
            case 5:
                guard cursor <= range.upperBound - 4 else { return false }
                cursor += 4
            default:
                return false
            }
        }
        return cursor == range.upperBound
    }

    private static func readVarint(
        _ bytes: UnsafeRawBufferPointer,
        cursor: inout Int,
        limit: Int
    ) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while cursor < limit, shift < 64 {
            let byte = bytes[cursor]
            cursor += 1
            result |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
        return nil
    }

    private static func hexNibble(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: return byte - 48
        case 65...70: return byte - 55
        case 97...102: return byte - 87
        default: return nil
        }
    }
}
