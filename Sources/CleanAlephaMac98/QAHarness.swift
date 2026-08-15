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

    static func smart() -> Never {
        CamLog.line("qa smart begin")
        let t0 = Date()
        var total = 0
        var forbidden = 0
        for stage in Scanner.ScanStage.allCases {
            if Date().timeIntervalSince(t0) > 180 {
                CamLog.line("qa smart abort remaining after 180s at \(stage.module.rawValue)")
                break
            }
            let started = Date()
            let chunk = Scanner.safeItems(for: stage)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            total += chunk.items.count
            for item in chunk.items {
                if Keep.isProtected(item.url) {
                    forbidden += 1
                    CamLog.line("qa smart LEAK \(stage.module.rawValue) \(item.id) \(item.url.path)")
                }
                if Keep.names.contains(item.url.lastPathComponent) {
                    forbidden += 1
                    CamLog.line("qa smart LOGIN \(stage.module.rawValue) \(item.id) \(item.url.lastPathComponent)")
                }
            }
            CamLog.line("qa smart \(stage.module.rawValue) items=\(chunk.items.count) failed=\(chunk.failed) ms=\(ms)")
            for item in chunk.items.prefix(5) {
                CamLog.line("qa smart card \(item.id) bytes=\(item.bytes) sel=\(item.selected)")
            }
        }
        CamLog.line("qa smart done items=\(total) leaks=\(forbidden) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
        FileHandle.standardOutput.write(Data("qa-smart ok items=\(total) leaks=\(forbidden)\n".utf8))
        exit(0)
    }
}
