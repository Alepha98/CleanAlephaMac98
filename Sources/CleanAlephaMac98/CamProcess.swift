import Darwin
import Foundation

/// Run a helper without the classic pipe deadlock (`waitUntilExit` while stdout fills).
enum CamProcess {
    static func run(
        path: String,
        arguments: [String],
        timeout: TimeInterval = 8
    ) -> (out: String, err: String, status: Int32, timedOut: Bool) {
        let task = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = arguments
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return ("", "\(error)", -1, false)
        }

        let outSink = DataSink()
        let errSink = DataSink()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outSink.data = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errSink.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.03)
        }
        var timedOut = false
        if task.isRunning {
            timedOut = true
            task.terminate()
            Thread.sleep(forTimeInterval: 0.12)
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }
        _ = group.wait(timeout: .now() + 2)
        return (
            String(data: outSink.data, encoding: .utf8) ?? "",
            String(data: errSink.data, encoding: .utf8) ?? "",
            task.terminationStatus,
            timedOut
        )
    }
}

private final class DataSink: @unchecked Sendable {
    var data = Data()
}
