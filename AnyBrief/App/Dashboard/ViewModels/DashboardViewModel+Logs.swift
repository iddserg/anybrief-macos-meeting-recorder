
import Foundation

extension DashboardViewModel {
    func clearLogs() {
        Task {
            let logURLs = [
                logsDirectoryURL.appendingPathComponent("app.log.1", isDirectory: false),
                logsDirectoryURL.appendingPathComponent("app.log", isDirectory: false),
            ] + recentJobLogURLs()
            for url in logURLs where fileManager.fileExists(atPath: url.path) {
                try? "".write(to: url, atomically: true, encoding: .utf8)
            }
            await loggingService.log("Logs cleared by user.", level: .info, component: "Dashboard")
            await MainActor.run {
                activityLog = ""
                errorLog = ""
            }
        }
    }

    func loadLogs() async -> (activity: String, errors: String) {
        let appLogURLs = [
            logsDirectoryURL.appendingPathComponent("app.log.1", isDirectory: false),
            logsDirectoryURL.appendingPathComponent("app.log", isDirectory: false),
        ]

        let appLines = appLogURLs.flatMap(logLines)
        let jobLines = recentJobLogURLs().flatMap(logLines)
        let errorLines = Array((appLines + jobLines).filter(Self.isWarningOrErrorLogLine).suffix(100))
        return (
            Array(appLines.suffix(200)).joined(separator: "\n"),
            errorLines.joined(separator: "\n")
        )
    }

    private var logsDirectoryURL: URL {
        storageService.meetingsDirectoryURL
            .deletingLastPathComponent()
            .appendingPathComponent("logs", isDirectory: true)
    }

    private func recentJobLogURLs(limit: Int = 20) -> [URL] {
        let jobsDirectoryURL = logsDirectoryURL.appendingPathComponent("jobs", isDirectory: true)
        guard let urls = try? fileManager.contentsOfDirectory(
            at: jobsDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return Array(
            urls
                .filter { url in
                    url.pathExtension == "log" &&
                        ((try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true)
                }
                .sorted { lhs, rhs in
                    let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    return lhsDate < rhsDate
                }
                .suffix(limit)
        )
    }

    private func logLines(from url: URL) -> [String] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return content.split(separator: "\n").map(String.init)
    }

    private static func isWarningOrErrorLogLine(_ line: String) -> Bool {
        line.contains("[ERROR]") ||
            line.contains("[WARN]") ||
            line.hasPrefix("ERROR:") ||
            line.hasPrefix("WARN:")
    }
}
