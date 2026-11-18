import Foundation
import UIKit
import Darwin

/// Кольцевой логгер: память + файл Documents/log.txt (переживает перезапуск),
/// плюс crash.log с дампами исключений и сигналов.
final class AppLogger: ObservableObject {
    static let shared = AppLogger()

    @Published private(set) var lines: [LogLine] = []

    private let lock = NSLock()
    private let maxLines = 500
    private var fileHandle: FileHandle?
    private static let crashPath = (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory()))
        .appendingPathComponent("crash.log").path

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
        loadFromDisk()
        installCrashHandlers()
    }

    /// Восстановление истории лога после перезапуска
    private func loadFromDisk() {
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let url = dir.appendingPathComponent("log.txt")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return }
        let parsed = text.components(separatedBy: "\n").compactMap { line -> LogLine? in
            guard line.hasPrefix("["), let dateEnd = line.firstIndex(of: "]") else { return nil }
            let dateStr = String(line[line.index(after: line.startIndex)..<dateEnd])
            let rest = String(line[line.index(after: dateEnd)...])
            let parts = rest.split(separator: "]", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            let level = parts[0].trimmingCharacters(in: .whitespaces)
            let message = parts[1].trimmingCharacters(in: .whitespaces)
            let date = ISO8601DateFormatter().date(from: dateStr) ?? Date()
            return LogLine(date: date, level: level, message: message)
        }
        lines.append(contentsOf: parsed.suffix(maxLines))
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
            try? fileHandle?.synchronize()
        }
    }

    static func info(_ m: String) { shared.log("INFO", m) }
    static func warn(_ m: String) { shared.log("WARN", m) }
    static func error(_ m: String) { shared.log("ERROR", m) }

    // MARK: - Crash-хендлеры

    /// Пишет строку напрямую в crash.log (без Foundation-объектов — безопасно из сигнального хендлера)
    private static func writeRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if let fh = FileHandle(forWritingAtPath: crashPath) {
            try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
            try? fh.close()
        }
    }

    func installCrashHandlers() {
        // Создаём crash.log
        FileManager.default.createFile(atPath: Self.crashPath, contents: nil)

        // ObjC/NSException
        NSSetUncaughtExceptionHandler { exception in
            let msg = "EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "?")\n\(exception.callStackSymbols.joined(separator: "\n"))\n"
            AppLogger.writeRaw(msg)
        }

        // Сигналы
        func install(_ sig: Int32, _ name: String) {
            signal(sig) { _ in
                AppLogger.writeRaw("[CRASH] \(name)\n")
                _exit(128 + sig)
            }
        }
        install(SIGSEGV, "SIGSEGV")
        install(SIGABRT, "SIGABRT")
        install(SIGBUS, "SIGBUS")
        install(SIGILL, "SIGILL")
    }
}
