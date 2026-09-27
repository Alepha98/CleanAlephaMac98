import Darwin
import Foundation

/// Run a helper without the classic pipe deadlock (`waitUntilExit` while stdout fills).
enum CamProcess {
    static func run(
        path: String,
        arguments: [String],
        timeout: TimeInterval = 8,
        cancellation: ScanCancellation? = nil
    ) -> (out: String, err: String, status: Int32, timedOut: Bool) {
        let result = runData(
            path: path,
            arguments: arguments,
            timeout: timeout,
            cancellation: cancellation
        )
        return (
            String(decoding: result.out, as: UTF8.self),
            String(decoding: result.err, as: UTF8.self),
            result.status,
            result.timedOut
        )
    }

    /// Binary-safe variant for NUL-delimited filesystem output. File names are arbitrary
    /// bytes, so converting the whole stream to UTF-8 before splitting could erase every
    /// result because of a single unusual name.
    static func runData(
        path: String,
        arguments: [String],
        timeout: TimeInterval = 8,
        cancellation: ScanCancellation? = nil
    ) -> (out: Data, err: Data, status: Int32, timedOut: Bool) {
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
            return (Data(), Data("\(error)".utf8), -1, false)
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
        while task.isRunning, Date() < deadline, cancellation?.isCancelled != true {
            Thread.sleep(forTimeInterval: 0.03)
        }
        var timedOut = false
        if task.isRunning {
            timedOut = Date() >= deadline
            task.terminate()
            Thread.sleep(forTimeInterval: 0.12)
            if task.isRunning {
                kill(task.processIdentifier, SIGKILL)
            }
        }
        _ = group.wait(timeout: .now() + 2)
        return (
            outSink.data,
            errSink.data,
            task.terminationStatus,
            timedOut
        )
    }
}

private final class DataSink: @unchecked Sendable {
    var data = Data()
}
