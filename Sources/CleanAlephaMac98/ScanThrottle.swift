import Darwin
import Foundation

/// Soft caps for scans: prefer a slower pass over melting the Mac (CMM often hits ~100% CPU / 1GB+).
enum ScanThrottle {
    static let paceNanos: UInt64 = 12_000_000
    static let heavyPaceNanos: UInt64 = 28_000_000
    /// Soft RSS ceiling – we yield and drain when crossed; not a hard jetsam limit.
    static let ramSoftBytes: UInt64 = 800 * 1_024 * 1_024

    static func beginWorker() {
        pthread_set_qos_class_self_np(QOS_CLASS_UTILITY, 0)
    }

    static func pace(heavy: Bool = false) async {
        let n = heavy ? heavyPaceNanos : paceNanos
        try? await Task.sleep(nanoseconds: n)
    }

    /// Call from long `du` / enumerator loops (sync).
    static func tickSync(every n: Int, counter: inout Int) {
        counter += 1
        guard counter % n == 0 else { return }
        Thread.sleep(forTimeInterval: 0.002)
        if currentRSS() > ramSoftBytes {
            Thread.sleep(forTimeInterval: 0.05)
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    static func currentRSS() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }

    static func reliefIfNeeded() {
        if currentRSS() > ramSoftBytes {
            malloc_zone_pressure_relief(nil, 0)
            Thread.sleep(forTimeInterval: 0.04)
        }
    }
}
