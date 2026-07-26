
import AppKit

extension DashboardViewModel {
    func openMeetingsFolder() {
        workspace.open(storageService.meetingsDirectoryURL)
    }

    func copyPrimaryMeetingDocument(_ meeting: RecentMeeting) {
        let documentURL: URL
        let copiedMessage: String
        let transform: (String) -> String
        if let summaryURL = meeting.summaryURL {
            documentURL = summaryURL
            copiedMessage = String(localized: "Summary copied.")
            transform = Self.markdownWithoutFrontmatter
        } else {
            documentURL = meeting.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
            copiedMessage = String(localized: "Transcript copied.")
            transform = { $0 }
        }

        do {
            let content = try String(contentsOf: documentURL, encoding: .utf8)
            copyToPasteboard(transform(content))
            summaryActionMessage = copiedMessage
            summaryActionMessageIsError = false
        } catch {
            summaryActionMessage = String(
                format: String(localized: "Could not copy document: %@"),
                error.localizedDescription
            )
            summaryActionMessageIsError = true
        }
    }

    func canCopyPrimaryMeetingDocument(_ meeting: RecentMeeting) -> Bool {
        canOpenPrimaryMeetingDocument(meeting)
    }

    static func markdownWithoutFrontmatter(_ content: String) -> String {
        guard content.hasPrefix("---") else {
            return content
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return content
        }

        let bodyLines = lines.dropFirst(closingIndex + 1)
        return bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func showInFinder(_ meeting: RecentMeeting) {
        workspace.activateFileViewerSelecting([meeting.folderURL])
    }

    func openPrimaryMeetingDocument(_ meeting: RecentMeeting) {
        if let summaryURL = meeting.summaryURL {
            workspace.open(summaryURL)
            return
        }
        openTranscript(meeting)
    }

    func openTranscript(_ meeting: RecentMeeting) {
        let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        guard fileManager.fileExists(atPath: transcriptURL.path) else {
            summaryActionMessage = String(localized: "Transcript file is missing.")
            summaryActionMessageIsError = true
            return
        }
        workspace.open(transcriptURL)
        summaryActionMessage = nil
        summaryActionMessageIsError = false
    }

    func canOpenPrimaryMeetingDocument(_ meeting: RecentMeeting) -> Bool {
        if meeting.summaryURL != nil {
            return true
        }
        let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        return fileManager.fileExists(atPath: transcriptURL.path)
    }

    func canOpenTranscript(_ meeting: RecentMeeting) -> Bool {
        let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        return fileManager.fileExists(atPath: transcriptURL.path)
    }

    func renameMeeting(_ meeting: RecentMeeting, title: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            return
        }

        Task {
            do {
                let renamedFolderURL: URL
                if shouldRenameFolderImmediately(meeting) {
                    renamedFolderURL = try renameCompletedMeetingFolder(meeting.folderURL, title: trimmedTitle)
                } else {
                    renamedFolderURL = meeting.folderURL
                }
                try trimmedTitle.write(
                    to: Self.titleOverrideURL(for: renamedFolderURL),
                    atomically: true,
                    encoding: .utf8
                )
                await loggingService.log(
                    "Renamed meeting \(meeting.folderURL.lastPathComponent) to \(renamedFolderURL.lastPathComponent).",
                    level: .info,
                    component: "Dashboard"
                )
                await refresh()
            } catch {
                await loggingService.log(
                    "Failed to rename meeting \(meeting.folderURL.lastPathComponent): \(error.localizedDescription)",
                    level: .error,
                    component: "Dashboard"
                )
            }
        }
    }

    func deleteMeeting(_ meeting: RecentMeeting) {
        guard meeting.canDelete, confirmDeleteMeeting(meeting) else {
            return
        }

        Task {
            do {
                if fileManager.fileExists(atPath: meeting.folderURL.path) {
                    try fileManager.removeItem(at: meeting.folderURL)
                }
                await removeJob(for: meeting)
                await loggingService.log(
                    "Deleted meeting folder \(meeting.folderURL.lastPathComponent).",
                    level: .warn,
                    component: "Dashboard"
                )
                await refresh()
            } catch {
                await loggingService.log(
                    "Failed to delete meeting \(meeting.folderURL.lastPathComponent): \(error.localizedDescription)",
                    level: .error,
                    component: "Dashboard"
                )
            }
        }
    }
    func loadCurrentActivity() async -> CurrentActivity? {
        let jobs = await jobRepository.load()
        let state = await appStateProvider()
        guard let activity = Self.currentActivity(from: jobs, appState: state, now: Date()) else {
            return nil
        }
        guard activity.jobId != "runtime" else {
            return activity
        }
        let detail = await pipelineActivityProvider(activity.jobId)
        return CurrentActivity(
            jobId: activity.jobId,
            status: activity.status,
            stage: activity.stage,
            startedAt: activity.startedAt,
            duration: activity.duration,
            detail: detail
        )
    }

    static func currentActivity(from jobs: [Job], appState: AppState, now: Date) -> CurrentActivity? {
        let activeJob = jobs
            .filter { !$0.isTerminal }
            .sorted {
                if $0.status == "recording", $1.status != "recording" {
                    return true
                }
                if $0.status != "recording", $1.status == "recording" {
                    return false
                }
                return $0.updatedAt > $1.updatedAt
            }
            .first

        guard let activeJob else {
            guard appState != .idle, appState != .needsPermissions else {
                return nil
            }

            return CurrentActivity(
                jobId: "runtime",
                status: String(describing: appState).capitalized,
                stage: String(describing: appState),
                startedAt: now,
                duration: 0,
                detail: nil
            )
        }

        let stageStartedAt = activeJob.updatedAt
        let endDate = activeJob.completedAt ?? now
        return CurrentActivity(
            jobId: activeJob.id,
            status: activeJob.status,
            stage: activeJob.stage.rawValue,
            startedAt: stageStartedAt,
            duration: max(0, endDate.timeIntervalSince(stageStartedAt)),
            detail: nil
        )
    }

    func loadRecentMeetings() async -> [RecentMeeting] {
        let meetingsDirectoryURL = storageService.meetingsDirectoryURL
        let jobs = await jobRepository.load()
        return await Task.detached(priority: .utility) {
            RecentMeetingsBackgroundLoader.load(
                meetingsDirectoryURL: meetingsDirectoryURL,
                jobs: jobs
            )
        }.value
    }

    func shouldHideStaleInProgressFolder(
        _ folderURL: URL,
        hasSummary: Bool,
        job: Job?
    ) -> Bool {
        guard folderURL.lastPathComponent.contains("_inprogress"), !hasSummary else {
            return false
        }
        return job?.isTerminal ?? true
    }
    func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    func meetingTitle(for folderURL: URL, summaryURL: URL?) -> String {
        let titleURL = Self.titleOverrideURL(for: folderURL)
        if let title = try? String(contentsOf: titleURL, encoding: .utf8) {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
        }

        guard let summaryURL,
              let content = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            return folderURL.lastPathComponent
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let bodyLines: ArraySlice<String>
        if lines.first == "---",
           let closingIndex = lines.dropFirst().firstIndex(of: "---") {
            bodyLines = lines.dropFirst(closingIndex + 1)[...]
        } else {
            bodyLines = lines[...]
        }

        return bodyLines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { $0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) }
            ?? folderURL.lastPathComponent
    }

    func removeJob(for meeting: RecentMeeting) async {
        let jobs = await jobRepository.load()
        let filteredJobs = jobs.filter { job in
            if let jobId = meeting.jobId {
                return job.id != jobId
            }
            return !(job.meetingId == meeting.folderURL.lastPathComponent ||
                Self.meetingFolderPrefix(for: job.createdAt) == meeting.folderURL.lastPathComponent.replacingOccurrences(of: "_inprogress", with: ""))
        }
        await jobRepository.save(filteredJobs)
    }

    func shouldRenameFolderImmediately(_ meeting: RecentMeeting) -> Bool {
        meeting.canDelete
    }

    func needsFolderRename(folderURL: URL, title: String, status: String) -> Bool {
        guard status != "recording",
              status != "processing" else {
            return false
        }
        return Self.renamedCompletedFolderName(
            currentName: folderURL.lastPathComponent,
            title: title
        ) != folderURL.lastPathComponent
    }

    func renameCompletedMeetingFolder(_ folderURL: URL, title: String) throws -> URL {
        let parentURL = folderURL.deletingLastPathComponent()
        let targetName = Self.renamedCompletedFolderName(
            currentName: folderURL.lastPathComponent,
            title: title
        )
        var targetURL = parentURL.appendingPathComponent(targetName, isDirectory: true)
        if targetURL == folderURL {
            return folderURL
        }

        if fileManager.fileExists(atPath: targetURL.path) {
            var counter = 2
            repeat {
                targetURL = parentURL.appendingPathComponent("\(targetName)_\(counter)", isDirectory: true)
                counter += 1
            } while fileManager.fileExists(atPath: targetURL.path)
        }

        try fileManager.moveItem(at: folderURL, to: targetURL)
        return targetURL
    }

    func confirmDeleteMeeting(_ meeting: RecentMeeting) -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete this meeting?")
        alert.informativeText = String(localized: "This will permanently delete the meeting folder and remove it from AnyBrief history.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func titleOverrideURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(".anybrief-title", isDirectory: false)
    }

    static func renamedCompletedFolderName(currentName: String, title: String) -> String {
        let sanitizedTitle = sanitizedFolderComponent(title)
        let baseName = currentName.replacingOccurrences(of: "_inprogress", with: "")
        let durationSuffix = baseName.range(
            of: #"_\d+m$"#,
            options: .regularExpression
        ).map { String(baseName[$0]) } ?? ""
        let datePrefix = meetingTimestampPrefix(from: baseName) ?? String(baseName.prefix(16))
        let hasDatePrefix = meetingDateFormatter.date(from: datePrefix) != nil

        if hasDatePrefix, !durationSuffix.isEmpty {
            return "\(datePrefix)_\(sanitizedTitle)\(durationSuffix)"
        }
        if hasDatePrefix {
            return "\(datePrefix)_\(sanitizedTitle)"
        }
        return sanitizedTitle
    }

    static func sanitizedFolderComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let joined = value.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsedWhitespace = joined
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(collapsedWhitespace.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "meeting" : limited
    }
    static func meetingDate(from folderName: String) -> Date? {
        guard let datePrefix = meetingTimestampPrefix(from: folderName) else {
            return nil
        }
        return meetingDateFormatter.date(from: datePrefix)
    }

    func meetingStatus(from summaryURL: URL) -> String? {
        guard let content = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            return nil
        }
        guard let frontmatter = frontmatter(in: content) else {
            return nil
        }
        let statusLine = frontmatter
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("status:") }
        let status = statusLine?
            .split(separator: ":", maxSplits: 1)
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "partial_success" {
            return "partial"
        }
        return status
    }

    func meetingStatus(
        for folderURL: URL,
        hasSummary: Bool,
        summaryStatus: String?,
        job: Job?
    ) -> String {
        if let summaryStatus {
            return summaryStatus
        }
        if let job {
            return job.status == "failed" && job.error?.code == "recording_interrupted"
                ? "interrupted"
                : job.status
        }
        if hasSummary {
            return "completed"
        }
        if folderURL.lastPathComponent.contains("_inprogress") {
            return "interrupted"
        }
        return "processing"
    }

    func job(for folderURL: URL, in jobs: [Job]) -> Job? {
        let folderName = folderURL.lastPathComponent
        let folderPrefix = Self.meetingTimestampPrefix(from: folderName)
        return jobs
            .filter { job in
                job.meetingId == folderName || Self.meetingFolderPrefix(for: job.createdAt) == folderPrefix
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    func frontmatter(in markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else {
            return nil
        }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return nil
        }
        return lines[1..<closingIndex].joined(separator: "\n")
    }

    static let meetingDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    static func meetingFolderPrefix(for date: Date) -> String {
        meetingDateFormatter.string(from: date)
    }

    static func meetingTimestampPrefix(from folderName: String) -> String? {
        let prefix = String(folderName.prefix(16))
        return meetingDateFormatter.date(from: prefix) == nil ? nil : prefix
    }
}

private enum RecentMeetingsBackgroundLoader {
    static func load(
        meetingsDirectoryURL: URL,
        jobs: [Job],
        limit: Int = 100
    ) -> [DashboardViewModel.RecentMeeting] {
        let fileManager = FileManager.default
        let formatter = meetingDateFormatter()
        guard let dayFolders = try? fileManager.contentsOfDirectory(
            at: meetingsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let meetingFolders = dayFolders
            .flatMap { dayURL -> [URL] in
                guard isDirectory(dayURL, fileManager: fileManager) else {
                    return []
                }
                return (try? fileManager.contentsOfDirectory(
                    at: dayURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )) ?? []
            }
            .filter { isDirectory($0, fileManager: fileManager) }
            .filter { folderURL in
                meetingDate(from: folderURL.lastPathComponent, formatter: formatter) != nil
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .prefix(limit)

        return meetingFolders.compactMap { folderURL in
            let summaryURL = folderURL.appendingPathComponent("summary.md", isDirectory: false)
            let summaryContent = try? String(contentsOf: summaryURL, encoding: .utf8)
            let hasSummary = summaryContent != nil
            let title = meetingTitle(
                for: folderURL,
                summaryContent: summaryContent
            )
            let summaryStatus = summaryContent.flatMap(meetingStatus)
            let matchingJob = job(for: folderURL, in: jobs, formatter: formatter)
            if shouldHideStaleInProgressFolder(folderURL, hasSummary: hasSummary, job: matchingJob) {
                return nil
            }
            let status = meetingStatus(
                for: folderURL,
                hasSummary: hasSummary,
                summaryStatus: summaryStatus,
                job: matchingJob
            )
            return DashboardViewModel.RecentMeeting(
                id: folderURL.path,
                title: title,
                timestamp: meetingDate(from: folderURL.lastPathComponent, formatter: formatter),
                status: status,
                folderURL: folderURL,
                summaryURL: hasSummary ? summaryURL : nil,
                jobId: matchingJob?.id,
                needsFolderRename: needsFolderRename(folderURL: folderURL, title: title, status: status)
            )
        }
    }

    private static func isDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func meetingTitle(for folderURL: URL, summaryContent: String?) -> String {
        let titleURL = titleOverrideURL(for: folderURL)
        if let title = try? String(contentsOf: titleURL, encoding: .utf8) {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedTitle.isEmpty {
                return trimmedTitle
            }
        }

        guard let summaryContent else {
            return folderURL.lastPathComponent
        }

        return summaryBodyLines(in: summaryContent)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { $0.replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression) }
            ?? folderURL.lastPathComponent
    }

    private static func meetingStatus(from summaryContent: String) -> String? {
        guard let frontmatter = frontmatter(in: summaryContent) else {
            return nil
        }
        let statusLine = frontmatter
            .split(separator: "\n")
            .map(String.init)
            .first { $0.hasPrefix("status:") }
        let status = statusLine?
            .split(separator: ":", maxSplits: 1)
            .dropFirst()
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if status == "partial_success" {
            return "partial"
        }
        return status
    }

    private static func meetingStatus(
        for folderURL: URL,
        hasSummary: Bool,
        summaryStatus: String?,
        job: Job?
    ) -> String {
        if let summaryStatus {
            return summaryStatus
        }
        if let job {
            return job.status == "failed" && job.error?.code == "recording_interrupted"
                ? "interrupted"
                : job.status
        }
        if hasSummary {
            return "completed"
        }
        if folderURL.lastPathComponent.contains("_inprogress") {
            return "interrupted"
        }
        return "processing"
    }

    private static func job(for folderURL: URL, in jobs: [Job], formatter: DateFormatter) -> Job? {
        let folderName = folderURL.lastPathComponent
        let folderPrefix = meetingTimestampPrefix(from: folderName, formatter: formatter)
        return jobs
            .filter { job in
                job.meetingId == folderName || meetingFolderPrefix(for: job.createdAt, formatter: formatter) == folderPrefix
            }
            .sorted { $0.updatedAt > $1.updatedAt }
            .first
    }

    private static func shouldHideStaleInProgressFolder(
        _ folderURL: URL,
        hasSummary: Bool,
        job: Job?
    ) -> Bool {
        guard folderURL.lastPathComponent.contains("_inprogress"), !hasSummary else {
            return false
        }
        return job?.isTerminal ?? true
    }

    private static func needsFolderRename(folderURL: URL, title: String, status: String) -> Bool {
        guard status != "recording",
              status != "processing" else {
            return false
        }
        return renamedCompletedFolderName(
            currentName: folderURL.lastPathComponent,
            title: title
        ) != folderURL.lastPathComponent
    }

    private static func renamedCompletedFolderName(currentName: String, title: String) -> String {
        let formatter = meetingDateFormatter()
        let sanitizedTitle = sanitizedFolderComponent(title)
        let baseName = currentName.replacingOccurrences(of: "_inprogress", with: "")
        let durationSuffix = baseName.range(
            of: #"_\d+m$"#,
            options: .regularExpression
        ).map { String(baseName[$0]) } ?? ""
        let datePrefix = meetingTimestampPrefix(from: baseName, formatter: formatter) ?? String(baseName.prefix(16))
        let hasDatePrefix = formatter.date(from: datePrefix) != nil

        if hasDatePrefix, !durationSuffix.isEmpty {
            return "\(datePrefix)_\(sanitizedTitle)\(durationSuffix)"
        }
        if hasDatePrefix {
            return "\(datePrefix)_\(sanitizedTitle)"
        }
        return sanitizedTitle
    }

    private static func sanitizedFolderComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let joined = value.components(separatedBy: invalidCharacters).joined(separator: " ")
        let collapsedWhitespace = joined
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(collapsedWhitespace.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "meeting" : limited
    }

    private static func meetingDate(from folderName: String, formatter: DateFormatter) -> Date? {
        guard let datePrefix = meetingTimestampPrefix(from: folderName, formatter: formatter) else {
            return nil
        }
        return formatter.date(from: datePrefix)
    }

    private static func meetingFolderPrefix(for date: Date, formatter: DateFormatter) -> String {
        formatter.string(from: date)
    }

    private static func meetingTimestampPrefix(from folderName: String, formatter: DateFormatter) -> String? {
        let prefix = String(folderName.prefix(16))
        return formatter.date(from: prefix) == nil ? nil : prefix
    }

    private static func frontmatter(in markdown: String) -> String? {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---" else {
            return nil
        }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return nil
        }
        return lines[1..<closingIndex].joined(separator: "\n")
    }

    private static func summaryBodyLines(in markdown: String) -> [String] {
        let lines = markdown.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.first == "---",
           let closingIndex = lines.dropFirst().firstIndex(of: "---") {
            return Array(lines.dropFirst(closingIndex + 1))
        }
        return lines
    }

    private static func titleOverrideURL(for folderURL: URL) -> URL {
        folderURL.appendingPathComponent(".anybrief-title", isDirectory: false)
    }

    private static func meetingDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }
}
