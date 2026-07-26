import Foundation

protocol StorageServiceProtocol {
    func prepareStorage(using loggingService: LoggingService) async throws
    func createMeetingFolder(jobId: String, startedAt: Date) throws -> MeetingPaths
    func renameMeetingFolder(from paths: MeetingPaths, duration: TimeInterval) throws -> URL
    func findMeetingPaths(jobId: String, createdAt: Date) throws -> MeetingPaths?
    func cleanupTemporaryArtifacts(for paths: MeetingPaths) throws
    var meetingsDirectoryURL: URL { get }
}

/// Meeting workspace paths for the recording pipeline.
struct MeetingPaths {
    let folderURL: URL
    let tmpURL: URL
    let systemWavURL: URL
    let micWavURL: URL
    let jobLogURL: URL
}

/// Prepares the AnyBrief on-disk layout before higher-level services start reading state.
final class StorageService: StorageServiceProtocol {
    private let fileManager: FileManager
    private let appSettingsStore: AppSettingsStoreProtocol
    private let keychainStore: SecretStoreProtocol
    private let rootDirectoryOverride: URL?
    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private let meetingFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    init(
        fileManager: FileManager = .default,
        appSettingsStore: AppSettingsStoreProtocol = AppSettingsStore(),
        keychainStore: SecretStoreProtocol = SecretStoreFactory.makeDefault(),
        rootDirectoryOverride: URL? = nil
    ) {
        self.fileManager = fileManager
        self.appSettingsStore = appSettingsStore
        self.keychainStore = keychainStore
        self.rootDirectoryOverride = rootDirectoryOverride
    }

    func prepareStorage(using loggingService: LoggingService) async throws {
        var createdDirectories: [URL] = []

        for directory in directories {
            if try createDirectoryIfNeeded(at: directory.url) {
                createdDirectories.append(directory.url)
            }
        }

        var settings = await appSettingsStore.load(using: loggingService)
        if settings.automation.localHTTPAPISettings.apiKeyKeychainRef?.isEmpty != false {
            let apiKeyReference = UUID().uuidString.lowercased()
            let apiKey = try generateRandomHex(byteCount: 32)
            try keychainStore.save(key: apiKeyReference, value: apiKey)
            settings.automation.localHTTPAPISettings.apiKeyKeychainRef = apiKeyReference
        }

        try await appSettingsStore.save(settings)

        for directory in createdDirectories {
            await loggingService.log(
                "Created directory \(displayPath(for: directory))",
                level: .info,
                component: "Storage"
            )
        }
    }

    func createMeetingFolder(jobId: String, startedAt: Date) throws -> MeetingPaths {
        let dayFolderURL = meetingsDirectoryURL
            .appendingPathComponent(dayFormatter.string(from: startedAt), isDirectory: true)
        let folderURL = dayFolderURL
            .appendingPathComponent("\(meetingFolderFormatter.string(from: startedAt))_\(jobId)_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)

        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try jobId.write(
            to: folderURL.appendingPathComponent(Self.jobIDFileName, isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        return MeetingPaths(
            folderURL: folderURL,
            tmpURL: tmpURL,
            systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
            micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
            jobLogURL: jobsLogsDirectoryURL.appendingPathComponent("\(jobId).log", isDirectory: false)
        )
    }

    func renameMeetingFolder(from paths: MeetingPaths, duration: TimeInterval) throws -> URL {
        let baseName = finalizedMeetingFolderName(
            from: paths.folderURL.lastPathComponent,
            duration: duration,
            title: customMeetingTitle(in: paths.folderURL)
        )
        let parentURL = paths.folderURL.deletingLastPathComponent()

        // Resolve a unique target name — two short recordings within the same
        // minute would otherwise collide on the same "_1m" suffix.
        var finalFolderURL = parentURL.appendingPathComponent(baseName, isDirectory: true)
        if fileManager.fileExists(atPath: finalFolderURL.path) {
            var counter = 2
            repeat {
                finalFolderURL = parentURL.appendingPathComponent("\(baseName)_\(counter)", isDirectory: true)
                counter += 1
            } while fileManager.fileExists(atPath: finalFolderURL.path)
        }

        guard paths.folderURL != finalFolderURL else {
            return finalFolderURL
        }

        try fileManager.moveItem(at: paths.folderURL, to: finalFolderURL)
        return finalFolderURL
    }

    func findMeetingPaths(jobId: String, createdAt: Date) throws -> MeetingPaths? {
        let dayFolderURL = meetingsDirectoryURL
            .appendingPathComponent(dayFormatter.string(from: createdAt), isDirectory: true)
        guard fileManager.fileExists(atPath: dayFolderURL.path) else {
            return nil
        }

        let folderPrefix = meetingFolderFormatter.string(from: createdAt)
        let meetingFolderURLs = try fileManager.contentsOfDirectory(
            at: dayFolderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix(folderPrefix) &&
            ((try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true)
        }
        .sorted { lhs, rhs in
            if lhs.lastPathComponent.contains("_inprogress") != rhs.lastPathComponent.contains("_inprogress") {
                return lhs.lastPathComponent.contains("_inprogress")
            }
            return lhs.lastPathComponent > rhs.lastPathComponent
        }

        let meetingFolderURL = meetingFolderURLs.first { folderURL in
            storedJobID(in: folderURL) == jobId
        } ?? meetingFolderURLs.first

        guard let folderURL = meetingFolderURL else {
            return nil
        }

        return meetingPaths(for: folderURL, jobId: jobId)
    }

    func cleanupTemporaryArtifacts(for paths: MeetingPaths) throws {
        let transientURLs = [
            paths.tmpURL,
            paths.folderURL.appendingPathComponent("system_audio.mp3", isDirectory: false),
            paths.folderURL.appendingPathComponent("microphone_audio.mp3", isDirectory: false),
            paths.folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false),
        ]

        for url in transientURLs where fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    private var rootDirectoryURL: URL {
        (rootDirectoryOverride ?? fileManager.homeDirectoryForCurrentUser)
            .appendingPathComponent("anybrief", isDirectory: true)
    }

    private static let jobIDFileName = ".anybrief-job-id"

    var meetingsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("meetings", isDirectory: true)
    }

    private var logsDirectoryURL: URL {
        rootDirectoryURL.appendingPathComponent("logs", isDirectory: true)
    }

    private var jobsLogsDirectoryURL: URL {
        logsDirectoryURL.appendingPathComponent("jobs", isDirectory: true)
    }

    private var directories: [(name: String, url: URL)] {
        let config = rootDirectoryURL.appendingPathComponent("config", isDirectory: true)
        let state = rootDirectoryURL.appendingPathComponent("state", isDirectory: true)

        return [
            ("~/anybrief", rootDirectoryURL),
            ("~/anybrief/config", config),
            ("~/anybrief/state", state),
            ("~/anybrief/logs", logsDirectoryURL),
            ("~/anybrief/logs/jobs", jobsLogsDirectoryURL),
            ("~/anybrief/meetings", meetingsDirectoryURL),
        ]
    }

    private func createDirectoryIfNeeded(at url: URL) throws -> Bool {
        guard !fileManager.fileExists(atPath: url.path) else {
            return false
        }

        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return true
    }

    private func displayPath(for url: URL) -> String {
        let homePath = fileManager.homeDirectoryForCurrentUser.path
        guard url.path.hasPrefix(homePath) else {
            return url.path
        }

        return "~" + url.path.dropFirst(homePath.count)
    }

    private func generateRandomHex(byteCount: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)

        guard status == errSecSuccess else {
            throw KeychainStoreError.unhandledStatus(status)
        }

        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func storedJobID(in folderURL: URL) -> String? {
        let jobIDURL = folderURL.appendingPathComponent(Self.jobIDFileName, isDirectory: false)
        return try? String(contentsOf: jobIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func meetingPaths(for folderURL: URL, jobId: String) -> MeetingPaths {
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        return MeetingPaths(
            folderURL: folderURL,
            tmpURL: tmpURL,
            systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
            micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
            jobLogURL: jobsLogsDirectoryURL.appendingPathComponent("\(jobId).log", isDirectory: false)
        )
    }

    private func finalizedMeetingFolderName(from currentName: String, duration: TimeInterval, title: String?) -> String {
        let suffix = "_inprogress"
        let baseName = currentName.hasSuffix(suffix) ? String(currentName.dropLast(suffix.count)) : currentName

        // Round up to at least 1m so we never get "_0m" for sub-minute recordings.
        let minutes = max(1, Int(ceil(duration / 60)))
        let durationSuffix = "_\(minutes)m"
        guard let title, !title.isEmpty else {
            return currentName.hasSuffix(suffix) ? baseName + durationSuffix : currentName
        }

        return baseName + "_" + sanitizedFolderComponent(title) + durationSuffix
    }

    private func customMeetingTitle(in folderURL: URL) -> String? {
        let titleURL = folderURL.appendingPathComponent(".anybrief-title", isDirectory: false)
        guard let title = try? String(contentsOf: titleURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty else {
            return nil
        }
        return title
    }

    private func sanitizedFolderComponent(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:")
            .union(.newlines)
            .union(.controlCharacters)
        let components = value.components(separatedBy: invalidCharacters)
        let joined = components.joined(separator: " ")
        let collapsedWhitespace = joined
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let limited = String(collapsedWhitespace.prefix(80))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return limited.isEmpty ? "meeting" : limited
    }
}
