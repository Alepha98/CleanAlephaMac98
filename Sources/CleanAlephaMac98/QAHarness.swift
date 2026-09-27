import Foundation

enum QAHarness {
    static func pulse() -> Never {
        CamLog.line("qa pulse begin")
        let t0 = Date()
        let mem = LiveProbe.pulseMemory()
        CamLog.line("qa pulse mem used=\(mem.used) total=\(mem.total) swap=\(mem.swap) cpu=\(Int(mem.cpuBusy)) load=\(String(format: "%.2f", mem.loadAvg)) pressure=\(mem.pressure.rawValue) apps=\(mem.apps.count)")
        for app in mem.apps.prefix(8) {
            CamLog.line("qa pulse app \(app.name) bytes=\(app.bytes) cpu=\(String(format: "%.1f", app.cpu)) kids=\(app.children.count)")
        }
        let cards = LiveProbe.junk(fromMemory: mem)
        CamLog.line("qa pulse ram-cards=\(cards.count)")
        let tabs = LiveProbe.pulseTabs(into: mem)
        CamLog.line("qa pulse tabs=\(tabs.tabs.count) note=\(tabs.tabAccess?.en ?? "none")")
        CamLog.line("qa pulse ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-pulse ok apps=\(mem.apps.count) tabs=\(tabs.tabs.count) cards=\(cards.count)\n".utf8))
        exit(0)
    }

    static func protect() -> Never {
        CamLog.line("qa protect begin")
        let t0 = Date()
        let rows = LiveProbe.junkProtect()
        CamLog.line("qa protect items=\(rows.count)")
        for row in rows.prefix(12) {
            CamLog.line("qa protect \(row.id) bytes=\(row.bytes) kind-sel=\(row.selected)")
        }
        CamLog.line("qa protect ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-protect ok items=\(rows.count)\n".utf8))
        exit(0)
    }

    static func startup() -> Never {
        CamLog.line("qa startup begin")
        let t0 = Date()
        let rows = LiveProbe.junkStartup()
        CamLog.line("qa startup items=\(rows.count)")
        for row in rows.prefix(20) {
            CamLog.line("qa startup \(row.title.ru) kind-advice=\(row.kind == .advice)")
        }
        CamLog.line("qa startup ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-startup ok items=\(rows.count)\n".utf8))
        exit(0)
    }

    static func keep() -> Never {
        CamLog.line("qa keep begin")
        var present = 0
        for item in Keep.builtinCatalog() {
            let exists = FileManager.default.fileExists(atPath: item.url.path)
            if exists { present += 1 }
            CamLog.line("qa keep \(item.name) exists=\(exists) \(item.url.path)")
        }
        CamLog.line("qa keep extras=\(Keep.extraPaths.count) present=\(present)")
        FileHandle.standardOutput.write(Data("qa-keep ok present=\(present)\n".utf8))
        exit(0)
    }

    /// Profiles a Smart scan the way the app runs it: Smart's light stages concurrently (real wall
    /// time, measured cold first), then a per-stage table, then the deep on-demand stages
    /// (skip them with CAM98_QA_LIGHT=1).
    static func smart() -> Never {
        CamLog.line("qa smart begin")
        let t0 = Date()
        let light = Scanner.ScanStage.stages(for: .smart)
        let deep = Scanner.ScanStage.allCases.filter(\.isDeep)

        let wallMs = parallelWallMs(light)
        SizeCache.shared.clear()   // per-stage timings below shouldn't ride the parallel run's cache

        var total = 0
        var forbidden = 0
        var out = "\nSMART — light stages, parallel wall time as in the app: \(wallMs) ms\n"
        out += "  (+ the live Protection/Performance/Startup checks Smart runs after)\n"

        func table(_ title: String, _ stages: [Scanner.ScanStage]) {
            out += "\n\(title)\nstage         items      bytes        sel-bytes     ms\n"
            out += "-----------------------------------------------------------\n"
            var sumBytes: Int64 = 0
            var sumSel: Int64 = 0
            var sumMs = 0
            for stage in stages {
                if Date().timeIntervalSince(t0) > 300 {
                    CamLog.line("qa smart abort remaining after 300s at \(stage.module.rawValue)")
                    out += "(aborted after 300s)\n"
                    break
                }
                let started = Date()
                let chunk = Scanner.safeItems(for: stage)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                total += chunk.items.count
                let bytes = chunk.items.reduce(Int64(0)) { $0 + $1.bytes }
                let selBytes = chunk.items.filter(\.selected).reduce(Int64(0)) { $0 + $1.bytes }
                sumBytes += bytes
                sumSel += selBytes
                sumMs += ms
                for item in chunk.items {
                    if Keep.isProtected(item.url), !Keep.allowsExplicitCard(item) {
                        forbidden += 1
                        CamLog.line("qa smart LEAK \(stage.module.rawValue) \(item.id) \(item.url.path)")
                    }
                    if Keep.names.contains(item.url.lastPathComponent) {
                        forbidden += 1
                        CamLog.line("qa smart LOGIN \(stage.module.rawValue) \(item.id) \(item.url.lastPathComponent)")
                    }
                }
                CamLog.line("qa smart \(stage) items=\(chunk.items.count) bytes=\(bytes) failed=\(chunk.failed) ms=\(ms)")
                let name = "\(stage)".padding(toLength: 12, withPad: " ", startingAt: 0)
                let items = String(chunk.items.count).padding(toLength: 6, withPad: " ", startingAt: 0)
                let b = ByteFormat.string(bytes, .en).padding(toLength: 11, withPad: " ", startingAt: 0)
                let sb = ByteFormat.string(selBytes, .en).padding(toLength: 12, withPad: " ", startingAt: 0)
                out += "\(name)  \(items)  \(b)  \(sb)  \(ms)\(chunk.failed ? "  FAILED" : "")\n"
            }
            out += "-----------------------------------------------------------\n"
            out += "sum           found \(ByteFormat.string(sumBytes, .en)) · selected \(ByteFormat.string(sumSel, .en)) · sequential \(sumMs) ms\n"
        }

        table("SMART per stage (sequential)", light)
        if ProcessInfo.processInfo.environment["CAM98_QA_LIGHT"] == nil {
            table("DEEP — on demand, runs when the layer is opened", deep)
        }

        let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
        CamLog.line("qa smart done items=\(total) leaks=\(forbidden) ms=\(totalMs) wall=\(wallMs)")
        FileHandle.standardOutput.write(Data(out.utf8))
        FileHandle.standardOutput.write(Data("qa-smart ok items=\(total) leaks=\(forbidden) smart-wall=\(wallMs)ms\n".utf8))
        exit(0)
    }

    private final class WallBox: @unchecked Sendable { var ms = 0 }

    /// Runs `stages` through the same bounded-concurrency coordinator the app uses; returns wall ms.
    private static func parallelWallMs(_ stages: [Scanner.ScanStage]) -> Int {
        let done = DispatchSemaphore(value: 0)
        let box = WallBox()
        Task.detached(priority: .utility) {
            let start = Date()
            for await _ in ScanCoordinator.stream(stages, work: { Scanner.safeItems(for: $0) }) {}
            box.ms = Int(Date().timeIntervalSince(start) * 1000)
            done.signal()
        }
        done.wait()
        return box.ms
    }
}
