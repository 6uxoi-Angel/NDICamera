import Foundation
import UIKit
import Darwin

// MARK: - Сигнальный crash-хендлер
//
// ВАЖНО: `signal()` требует указатель на C-функцию. Swift-замыкание,
// которое «захватывает» любой контекст (переменные окружающей функции),
// к C-указателю не приводится — это была ошибка сборки
// (Logger.swift: error: a C function pointer cannot be formed from a closure
// that captures context). Поэтому хендлер — глобальная функция БЕЗ захватов.
//
// Внутри хендлера нельзя использовать Foundation/alloc (не async-signal-safe):
// пишем через pre-opened файловый дескриптор и статические строки.

/// fd файла crash.log; открывается один раз при установке хендлеров.
private var ndiCrashLogFD: Int32 = -1

private func ndiCrashWrite(_ s: StaticString) {
    guard ndiCrashLogFD >= 0 else { return }
    s.withUTF8Buffer { buf in
        _ = write(ndiCrashLogFD, buf.baseAddress, buf.count)
    }
}

/// Глобальный хендлер сигналов (не захватывает контекст → валидный C ABI).
func ndiSignalHandler(_ sig: Int32) {
    switch sig {
    case SIGSEGV: ndiCrashWrite("CRASH: SIGSEGV (invalid memory access)\n")
    case SIGABRT: ndiCrashWrite("CRASH: SIGABRT (abort)\n")
    case SIGBUS:  ndiCrashWrite("CRASH: SIGBUS (bus error)\n")
    case SIGILL:  ndiCrashWrite("CRASH: SIGILL (illegal instruction)\n")
    case SIGTRAP: ndiCrashWrite("CRASH: SIGTRAP\n")
    default:      ndiCrashWrite("CRASH: signal\n")
    }
    _ = fsync(ndiCrashLogFD)
    // Возвращаем дефолтный обработчик и переизсылаем сигнал, чтобы iOS
    // всё равно сгенерировал системный .ips-отчёт (Settings → Privacy →
    // Analytics & Improvements). Ранний `_exit()` отчёт терял.
    _ = signal(sig, SIG_DFL)
    raise(sig)
}

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
        log("INFO", "AppLogger готов; log: Documents/log.txt, crash: Documents/crash.log")
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
            // FileHandle, открытый для записи, позиционирован в конец файла;
            // последовательные write() дописывают — seek не нужен.
            try? fileHandle?.write(contentsOf: data)
            try? fileHandle?.synchronize()
        }
        if level == "ERROR" { NSLog("NDICamera ERROR: %@", message) }
    }

    static func info(_ m: String) { shared.log("INFO", m) }
    static func warn(_ m: String) { shared.log("WARN", m) }
    static func error(_ m: String) { shared.log("ERROR", m) }

    // MARK: - Crash-хендлеры

    /// Пишет строку напрямую в crash.log через fd (без Swift-аллокаций внутри
    /// сигнального хендлера).
    fileprivate static func writeRaw(_ text: String) {
        guard ndiCrashLogFD >= 0 else { return }
        text.withCString { ptr in
            _ = write(ndiCrashLogFD, ptr, strlen(ptr))
        }
        _ = fsync(ndiCrashLogFD)
    }

    func installCrashHandlers() {
        // Открываем crash.log один раз; дескриптор используем из хендлера.
        FileManager.default.createFile(atPath: Self.crashPath, contents: nil)
        ndiCrashLogFD = Self.crashPath.withCString { open($0, O_WRONLY | O_APPEND | O_CREAT, 0o644) }
        if ndiCrashLogFD < 0 {
            NSLog("NDICamera: не удалось открыть crash.log")
        }

        // ObjC/NSException — можно через Foundation (вызывается из runloop, не из сигнального контекста)
        NSSetUncaughtExceptionHandler { exception in
            let msg = "EXCEPTION: \(exception.name.rawValue): \(exception.reason ?? "?")\n\(exception.callStackSymbols.joined(separator: "\n"))\n"
            AppLogger.writeRaw(msg)
        }

        // Сигналы — только глобальная функция без захватов (C function pointer)
        _ = signal(SIGSEGV, ndiSignalHandler)
        _ = signal(SIGABRT, ndiSignalHandler)
        _ = signal(SIGBUS, ndiSignalHandler)
        _ = signal(SIGILL, ndiSignalHandler)
        _ = signal(SIGTRAP, ndiSignalHandler)
    }
}
