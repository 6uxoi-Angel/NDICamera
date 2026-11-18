import Foundation
import UIKit

/// Простой кольцевой логгер: пишет в память и в файл Documents/log.txt.
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var lines: [LogLine] = []

    private let lock = NSLock()
    private let maxLines = 500
    private var fileHandle: FileHandle?

    struct LogLine: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let level: String
        let message: String
    }

    private init() {
        if let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            let url = dir.appendingPathComponent("log.txt")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = try? FileHandle(forWritingTo: url)
        }
    }

    func log(_ level: String = "INFO", _ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = LogLine(date: Date(), level: level, message: message)
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        let text = "\(ISO8601DateFormatter().string(from: line.date)) [\(level)] \(message)\n"
        if let data = text.data(using: .utf8) {
            try? fileHandle?.seekToEnd()
            try? fileHandle?.write(contentsOf: data)
        }
    }

    static func info(_ m: String) { shared.log("INFO", m) }
    static func warn(_ m: String) { shared.log("WARN", m) }
    static func error(_ m: String) { shared.log("ERROR", m) }
}
