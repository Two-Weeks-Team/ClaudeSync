import Foundation
import os

/// Lightweight wrapper around `os.Logger` that fans events out to both the
/// unified logging system and a rolling file at `~/.claudesync/logs/claudesync.log`.
///
/// File logging is intentionally simple: a single 10 MB rolling log file with
/// one rotated backup. This is sufficient for Phase 1 diagnostics and avoids
/// pulling in any third-party logging dependency.
public struct AppLogger: Sendable {
    public enum Level: Int, Sendable, Comparable {
        case debug = 0
        case info = 1
        case warning = 2
        case error = 3
        case critical = 4

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        var label: String {
            switch self {
            case .debug:    return "DEBUG"
            case .info:     return "INFO "
            case .warning:  return "WARN "
            case .error:    return "ERROR"
            case .critical: return "CRIT "
            }
        }

        var osLogType: OSLogType {
            switch self {
            case .debug:    return .debug
            case .info:     return .info
            case .warning:  return .default
            case .error:    return .error
            case .critical: return .fault
            }
        }
    }

    public static let subsystem = "com.claudesync.app"
    public static let shared = AppLogger()

    private let fileSink: FileLogSink

    public init() {
        self.fileSink = FileLogSink()
    }

    public func debug(_ message: @autoclosure () -> String, category: String = "general") {
        log(message(), level: .debug, category: category)
    }

    public func info(_ message: @autoclosure () -> String, category: String = "general") {
        log(message(), level: .info, category: category)
    }

    public func warning(_ message: @autoclosure () -> String, category: String = "general") {
        log(message(), level: .warning, category: category)
    }

    public func error(_ message: @autoclosure () -> String, category: String = "general") {
        log(message(), level: .error, category: category)
    }

    public func critical(_ message: @autoclosure () -> String, category: String = "general") {
        log(message(), level: .critical, category: category)
    }

    public func log(_ message: String, level: Level, category: String) {
        let osLogger = Logger(subsystem: Self.subsystem, category: category)
        osLogger.log(level: level.osLogType, "\(message, privacy: .public)")
        fileSink.append(level: level, category: category, message: message)
    }
}

/// Append-only rolling file logger. One active file plus one rotated backup.
final class FileLogSink: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.claudesync.logger.file", qos: .utility)
    private let maxBytes: Int = 10 * 1024 * 1024  // 10 MB
    private let dateFormatter: ISO8601DateFormatter

    init() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.dateFormatter = formatter
    }

    func append(level: AppLogger.Level, category: String, message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) [\(level.label)] [\(category)] \(message)\n"
        queue.async { [weak self] in
            self?.write(line: line)
        }
    }

    private func write(line: String) {
        guard let data = line.data(using: .utf8) else { return }
        guard let logURL = ensureLogFile() else { return }

        rotateIfNeeded(at: logURL)

        if let handle = try? FileHandle(forWritingTo: logURL) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
            } catch {
                // Swallow: logging must never crash the host.
            }
        }
    }

    private func ensureLogFile() -> URL? {
        let fm = FileManager.default
        let logsDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claudesync/logs", isDirectory: true)
        do {
            try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let url = logsDir.appendingPathComponent("claudesync.log")
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        return url
    }

    private func rotateIfNeeded(at url: URL) {
        let fm = FileManager.default
        guard
            let attrs = try? fm.attributesOfItem(atPath: url.path),
            let size = attrs[.size] as? Int,
            size >= maxBytes
        else { return }

        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("claudesync.log.1")
        if fm.fileExists(atPath: backup.path) {
            try? fm.removeItem(at: backup)
        }
        try? fm.moveItem(at: url, to: backup)
        fm.createFile(atPath: url.path, contents: nil)
    }
}
