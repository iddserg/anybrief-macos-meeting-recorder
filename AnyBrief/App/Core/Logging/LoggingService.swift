import Foundation

actor LoggingService {
    static let shared = LoggingService()

    enum LogLevel: String {
        case debug = "DEBUG"
        case info = "INFO"
        case warn = "WARN"
        case error = "ERROR"
    }

    private let fileManager = FileManager.default
    private let maximumFileSize = 5 * 1024 * 1024
    private let logFileName = "app.log"
    private let rotatedLogFileName = "app.log.1"
    private let logsDirectoryURL: URL
    private var loggedKeys = Set<String>()
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()

    init(logsDirectoryURL: URL? = nil) {
        self.logsDirectoryURL = logsDirectoryURL ?? Self.defaultLogsDirectoryURL()
    }

    func log(_ message: String, level: LogLevel, component: String) {
        let line = "\(timestampFormatter.string(from: Date())) [\(level.rawValue)] [\(component)] \(sanitize(message))\n"

        do {
            let logsDirectory = try ensureLogsDirectory()
            let logFileURL = logsDirectory.appendingPathComponent(logFileName, isDirectory: false)

            try rotateLogFileIfNeeded(at: logFileURL, incomingDataSize: line.utf8.count)
            try appendLine(line, to: logFileURL)
        } catch {
            fputs("LoggingService error: \(error)\n", stderr)
        }
    }

    func logOnce(_ message: String, level: LogLevel, component: String, key: String) {
        guard loggedKeys.insert(key).inserted else {
            return
        }

        log(message, level: level, component: component)
    }

    private func ensureLogsDirectory() throws -> URL {
        try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
        return logsDirectoryURL
    }

    private static func defaultLogsDirectoryURL() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("anybrief-tests", isDirectory: true)
                .appendingPathComponent("logs", isDirectory: true)
        }

        return FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
    }

    private func rotateLogFileIfNeeded(at logFileURL: URL, incomingDataSize: Int) throws {
        guard fileManager.fileExists(atPath: logFileURL.path) else {
            return
        }

        let attributes = try fileManager.attributesOfItem(atPath: logFileURL.path)
        let fileSize = attributes[.size] as? Int ?? 0

        guard fileSize + incomingDataSize > maximumFileSize else {
            return
        }

        let rotatedLogFileURL = logFileURL.deletingLastPathComponent()
            .appendingPathComponent(rotatedLogFileName, isDirectory: false)

        if fileManager.fileExists(atPath: rotatedLogFileURL.path) {
            try fileManager.removeItem(at: rotatedLogFileURL)
        }

        try fileManager.moveItem(at: logFileURL, to: rotatedLogFileURL)
    }

    private func appendLine(_ line: String, to logFileURL: URL) throws {
        let data = Data(line.utf8)

        if fileManager.fileExists(atPath: logFileURL.path) {
            try data.append(to: logFileURL)
        } else {
            try data.write(to: logFileURL, options: .atomic)
        }
    }

    private func sanitize(_ message: String) -> String {
        message.replacingOccurrences(
            of: #"(?i)(X-API-Key\s*[:=]\s*)([^\s,;]+)"#,
            with: "$1***",
            options: .regularExpression
        )
    }
}

private extension Data {
    func append(to url: URL) throws {
        if let handle = FileHandle(forWritingAtPath: url.path) {
            defer {
                try? handle.close()
            }
            try handle.seekToEnd()
            try handle.write(contentsOf: self)
            return
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
