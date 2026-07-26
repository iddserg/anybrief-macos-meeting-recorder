import Foundation

struct PostProcessingExportResult: Equatable {
    enum Status: Equatable {
        case exported
        case skipped
        case failed
    }

    let ruleID: String?
    let ruleTitle: String?
    let status: Status
    let sourceURL: URL
    let destinationURL: URL?
    let message: String
}

actor PostProcessingService {
    private let fileManager: FileManager
    private let logger: @Sendable (String, LoggingService.LogLevel) async -> Void

    init(
        fileManager: FileManager = .default,
        logger: @escaping @Sendable (String, LoggingService.LogLevel) async -> Void = { _, _ in }
    ) {
        self.fileManager = fileManager
        self.logger = logger
    }

    func exportSummaryIfNeeded(
        from meetingFolderURL: URL,
        settings: PostProcessingSettings,
        calendarEvent: CalendarEvent?
    ) async -> PostProcessingExportResult {
        guard settings.enabled else {
            return skipped(source: meetingFolderURL, message: "Post-processing is disabled.")
        }
        let summaryURL = meetingFolderURL.appendingPathComponent("summary.md", isDirectory: false)
        guard fileManager.fileExists(atPath: summaryURL.path) else {
            return skipped(source: summaryURL, message: "summary.md does not exist.")
        }

        let loadedCalendarEvent = calendarEvent ?? Self.loadStoredCalendarEvent(from: meetingFolderURL)
        let title = loadedCalendarEvent?.title ?? Self.fallbackTitle(from: meetingFolderURL)
        guard let rule = settings.rules.first(where: { $0.enabled && Self.matches(title: title, rule: $0) }) else {
            return skipped(source: summaryURL, message: "No enabled post-processing rule matched \(title).")
        }

        return await exportSummary(from: summaryURL, meetingFolderURL: meetingFolderURL, calendarEvent: loadedCalendarEvent, rule: rule)
    }

    func exportSummary(
        from meetingFolderURL: URL,
        settings: PostProcessingSettings,
        ruleID: String
    ) async -> PostProcessingExportResult {
        let summaryURL = meetingFolderURL.appendingPathComponent("summary.md", isDirectory: false)
        guard let rule = settings.rules.first(where: { $0.id == ruleID }) else {
            return failed(source: summaryURL, message: "Post-processing rule was not found.")
        }
        return await exportSummary(
            from: summaryURL,
            meetingFolderURL: meetingFolderURL,
            calendarEvent: Self.loadStoredCalendarEvent(from: meetingFolderURL),
            rule: rule
        )
    }

    private func exportSummary(
        from summaryURL: URL,
        meetingFolderURL: URL,
        calendarEvent: CalendarEvent?,
        rule: PostProcessingRuleConfiguration
    ) async -> PostProcessingExportResult {
        guard fileManager.fileExists(atPath: summaryURL.path) else {
            return failed(source: summaryURL, rule: rule, message: "summary.md does not exist.")
        }

        let destinationFolderURL = URL(fileURLWithPath: rule.destinationFolderPath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destinationFolderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            let message = "Destination folder does not exist: \(destinationFolderURL.path)"
            await logger(message, .warn)
            return failed(source: summaryURL, rule: rule, message: message)
        }

        let summaryContent: String
        do {
            summaryContent = try String(contentsOf: summaryURL, encoding: .utf8)
        } catch {
            return failed(source: summaryURL, rule: rule, message: error.localizedDescription)
        }
        if Self.frontmatterValue("status", in: summaryContent) == "partial_success" {
            return PostProcessingExportResult(
                ruleID: rule.id,
                ruleTitle: rule.title,
                status: .skipped,
                sourceURL: summaryURL,
                destinationURL: nil,
                message: "Partial success summary was not exported."
            )
        }

        let filename = Self.renderFilename(
            template: rule.filenameTemplate,
            meetingFolderURL: meetingFolderURL,
            calendarEvent: calendarEvent,
            summaryContent: summaryContent
        )
        let destinationURL = availableDestinationURL(
            destinationFolderURL.appendingPathComponent(filename, isDirectory: false),
            behavior: rule.conflictBehavior
        )

        guard let destinationURL else {
            let existingURL = destinationFolderURL.appendingPathComponent(filename, isDirectory: false)
            return PostProcessingExportResult(
                ruleID: rule.id,
                ruleTitle: rule.title,
                status: .skipped,
                sourceURL: summaryURL,
                destinationURL: existingURL,
                message: "Destination file already exists."
            )
        }

        do {
            if rule.conflictBehavior == .overwrite, fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: summaryURL, to: destinationURL)
            await logger("Exported summary to \(destinationURL.path)", .info)
            return PostProcessingExportResult(
                ruleID: rule.id,
                ruleTitle: rule.title,
                status: .exported,
                sourceURL: summaryURL,
                destinationURL: destinationURL,
                message: "Exported."
            )
        } catch {
            await logger("Summary export failed for \(summaryURL.path): \(error.localizedDescription)", .warn)
            return failed(source: summaryURL, rule: rule, destination: destinationURL, message: error.localizedDescription)
        }
    }

    private func availableDestinationURL(_ url: URL, behavior: PostProcessingRuleConfiguration.ConflictBehavior) -> URL? {
        guard fileManager.fileExists(atPath: url.path) else {
            return url
        }
        switch behavior {
        case .skip:
            return nil
        case .overwrite:
            return url
        case .addSuffix:
            let directory = url.deletingLastPathComponent()
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension
            for suffix in 2...999 {
                let candidate = directory.appendingPathComponent("\(base) \(suffix).\(ext)", isDirectory: false)
                if !fileManager.fileExists(atPath: candidate.path) {
                    return candidate
                }
            }
            return nil
        }
    }

    private func skipped(source: URL, message: String) -> PostProcessingExportResult {
        PostProcessingExportResult(
            ruleID: nil,
            ruleTitle: nil,
            status: .skipped,
            sourceURL: source,
            destinationURL: nil,
            message: message
        )
    }

    private func failed(
        source: URL,
        rule: PostProcessingRuleConfiguration? = nil,
        destination: URL? = nil,
        message: String
    ) -> PostProcessingExportResult {
        PostProcessingExportResult(
            ruleID: rule?.id,
            ruleTitle: rule?.title,
            status: .failed,
            sourceURL: source,
            destinationURL: destination,
            message: message
        )
    }
}

extension PostProcessingService {
    static func matches(title: String, rule: PostProcessingRuleConfiguration) -> Bool {
        let pattern = rule.calendarTitlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            return false
        }
        switch rule.matchMode {
        case .exact:
            return title.compare(pattern, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        case .contains:
            return title.range(of: pattern, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || Self.normalizedTitle(title).contains(Self.normalizedTitle(pattern))
        case .regex:
            return title.range(of: pattern, options: [.regularExpression, .caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    static func renderFilename(
        template: String,
        meetingFolderURL: URL,
        calendarEvent: CalendarEvent?,
        summaryContent: String
    ) -> String {
        let date = calendarEvent.map { Self.filenameDateFormatter.string(from: $0.startAt) }
            ?? Self.dateFromFolder(meetingFolderURL)
            ?? Self.filenameDateFormatter.string(from: Date())
        let calendarTitle = calendarEvent?.title ?? Self.fallbackTitle(from: meetingFolderURL)
        let topic = topic(from: summaryContent)
        let replacements = [
            "{date}": sanitizeFilenameComponent(date, maxLength: 10),
            "{calendarTitle}": sanitizeFilenameComponent(calendarTitle, maxLength: 90),
            "{topic}": sanitizeFilenameComponent(topic, maxLength: 90),
        ]
        var filename = template
        for (token, value) in replacements {
            filename = filename.replacingOccurrences(of: token, with: value)
        }
        filename = filename
            .replacingOccurrences(of: #"[\s]+—\s+\.md$"#, with: ".md", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !filename.lowercased().hasSuffix(".md") {
            filename += ".md"
        }
        return sanitizeFilename(filename, maxLength: 180)
    }

    static func loadStoredCalendarEvent(from meetingFolderURL: URL) -> CalendarEvent? {
        let metadataURL = meetingFolderURL.appendingPathComponent(".anybrief-autopilot.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(AutopilotRecordingMetadata.self, from: data) else {
            return nil
        }
        return metadata.calendarEvent
    }

    static func fallbackTitle(from meetingFolderURL: URL) -> String {
        let titleURL = meetingFolderURL.appendingPathComponent(".anybrief-title", isDirectory: false)
        if let title = try? String(contentsOf: titleURL, encoding: .utf8) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        var name = meetingFolderURL.lastPathComponent
        name = name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}_"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^[a-z0-9]{10}_"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"_\d+m$"#, with: "", options: .regularExpression)
        return name.isEmpty ? meetingFolderURL.lastPathComponent : name
    }

    static func topic(from summaryContent: String) -> String {
        let body = summaryContentWithoutFrontmatter(summaryContent)
        if let goal = paragraph(afterHeading: "Цель встречи", in: body) {
            return goal
        }
        if let goal = paragraph(afterHeading: "Purpose", in: body) {
            return goal
        }
        return body
            .split(separator: "\n")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { line in
                !line.isEmpty
                    && !line.hasPrefix(">")
                    && !line.hasPrefix("#")
                    && !line.hasPrefix("**Название:**")
                    && !line.localizedCaseInsensitiveContains("recording warning")
            } ?? ""
    }

    private static func paragraph(afterHeading heading: String, in body: String) -> String? {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let headingIndex = lines.firstIndex(where: {
            $0.replacingOccurrences(of: "#", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .compare(heading, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) else {
            return nil
        }
        for line in lines.dropFirst(headingIndex + 1) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("#") {
                return nil
            }
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    private static func summaryContentWithoutFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---\n"),
              let range = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return content
        }
        return String(content[range.upperBound...])
    }

    private static func frontmatterValue(_ key: String, in content: String) -> String? {
        guard content.hasPrefix("---\n"),
              let range = content.range(of: "\n---", range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex) else {
            return nil
        }
        let frontmatter = content[content.index(content.startIndex, offsetBy: 4)..<range.lowerBound]
        let prefix = "\(key.lowercased()):"
        for line in frontmatter.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix(prefix) else {
                continue
            }
            return trimmed.dropFirst(prefix.count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private static func dateFromFolder(_ folderURL: URL) -> String? {
        let name = folderURL.lastPathComponent
        guard name.count >= 10 else {
            return nil
        }
        let prefix = String(name.prefix(10))
        return filenameDateFormatter.date(from: prefix).map { filenameDateFormatter.string(from: $0) }
    }

    private static func normalizedTitle(_ value: String) -> String {
        value
            .replacingOccurrences(of: "ё", with: "е")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sanitizeFilenameComponent(_ value: String, maxLength: Int) -> String {
        sanitizeFilename(value, maxLength: maxLength)
            .replacingOccurrences(of: ".md", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func sanitizeFilename(_ value: String, maxLength: Int) -> String {
        var result = value
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: " -")
            .replacingOccurrences(of: "\0", with: "")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > maxLength {
            result = String(result.prefix(maxLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static let filenameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
