import Foundation

extension LocalAPIHandlers {
    func handleRecentLogs(request: HTTPRequest) async throws -> HTTPResponse {
        let (limit, offset) = try pagination(from: request.query)
        let requestedLevel = request.query["level"]?.uppercased()
        let sinceDate = request.query["since"].flatMap { iso8601.date(from: $0) }
        let lines = recentLogLines()
            .compactMap(parseLogLine)
            .filter { entry in
                if let requestedLevel, entry.level != requestedLevel {
                    return false
                }
                if let sinceDate, entry.timestamp < sinceDate {
                    return false
                }
                return true
            }
            .sorted { $0.timestamp > $1.timestamp }

        let page = Array(lines.dropFirst(offset).prefix(limit))
        let nextCursor = offset + page.count < lines.count ? encodeCursor(offset + page.count) : nil

        return jsonResponse([
            "items": page.map { entry in
                [
                    "timestamp": iso8601.string(from: entry.timestamp),
                    "level": entry.level.lowercased(),
                    "component": entry.component,
                    "message": entry.message,
                ]
            },
            "nextCursor": nextCursor as Any,
        ], request: request)
    }

    func recentLogLines() -> [String] {
        let logsDirectory = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        let urls = [
            logsDirectory.appendingPathComponent("app.log.1", isDirectory: false),
            logsDirectory.appendingPathComponent("app.log", isDirectory: false),
        ]
        return urls.flatMap { url -> [String] in
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                return []
            }
            return content.split(separator: "\n").map(String.init)
        }
    }

    func parseLogLine(_ line: String) -> ParsedLogLine? {
        let pattern = #"^([^ ]+) \[([A-Z]+)\] \[([^\]]+)\] (.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(location: 0, length: line.utf16.count)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 5 else {
            return nil
        }

        func component(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: line) else {
                return nil
            }
            return String(line[range])
        }

        guard let timestampString = component(1),
              let level = component(2),
              let componentName = component(3),
              let message = component(4),
              let timestamp = iso8601.date(from: timestampString) else {
            return nil
        }

        return ParsedLogLine(timestamp: timestamp, level: level, component: componentName, message: message)
    }
}
