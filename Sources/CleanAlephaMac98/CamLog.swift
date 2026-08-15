import Foundation

enum CamLog {
    static func line(_ message: String) {
        let url = AutoAgent.logURL
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let row = "\(fmt.string(from: Date())) \(message)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        if let data = row.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
        try? handle.synchronize()
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--qa") }) {
            FileHandle.standardError.write(Data(row.utf8))
        }
    }
}
