import XCTest
@testable import AnyBrief

/// Tests meeting-folder naming and lookup rules from the storage spec.
final class StorageServiceTests: XCTestCase {
    private var sandboxURL: URL!
    private var storageService: StorageService!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
        storageService = StorageService(
            fileManager: .default,
            appSettingsStore: InMemoryAppSettingsStore(),
            keychainStore: NoopKeychainStore(),
            rootDirectoryOverride: sandboxURL
        )
    }

    override func tearDownWithError() throws {
        if let sandboxURL, FileManager.default.fileExists(atPath: sandboxURL.path) {
            try FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testCreateMeetingFolderUsesJobIDToAvoidSameMinuteCollisions() throws {
        let startedAt = date(2026, 5, 18, 12, 34, 15)

        let first = try storageService.createMeetingFolder(jobId: "job-a", startedAt: startedAt)
        let second = try storageService.createMeetingFolder(jobId: "job-b", startedAt: startedAt.addingTimeInterval(20))

        XCTAssertNotEqual(first.folderURL, second.folderURL)
        XCTAssertNotEqual(first.tmpURL, second.tmpURL)
        XCTAssertNotEqual(first.systemWavURL, second.systemWavURL)
        XCTAssertNotEqual(first.micWavURL, second.micWavURL)
        XCTAssertTrue(first.folderURL.lastPathComponent.contains("job-a"))
        XCTAssertTrue(second.folderURL.lastPathComponent.contains("job-b"))
    }

    func testFindMeetingPathsReturnsExactFolderForJobIDWithinSameMinute() throws {
        let startedAt = date(2026, 5, 18, 12, 34, 15)
        let first = try storageService.createMeetingFolder(jobId: "job-a", startedAt: startedAt)
        let second = try storageService.createMeetingFolder(jobId: "job-b", startedAt: startedAt.addingTimeInterval(20))

        let foundFirst = try storageService.findMeetingPaths(jobId: "job-a", createdAt: startedAt)
        let foundSecond = try storageService.findMeetingPaths(jobId: "job-b", createdAt: startedAt.addingTimeInterval(20))

        XCTAssertEqual(foundFirst?.folderURL.standardizedFileURL, first.folderURL.standardizedFileURL)
        XCTAssertEqual(foundSecond?.folderURL.standardizedFileURL, second.folderURL.standardizedFileURL)
    }

    #if DEBUG
    func testDebugFileSecretStorePersistsSecretsInJSONFile() throws {
        let fileURL = sandboxURL.appendingPathComponent("debug-secrets.json", isDirectory: false)
        let store = DebugFileSecretStore(fileURL: fileURL)

        try store.save(key: "summary-key", value: "secret")

        XCTAssertEqual(store.load(key: "summary-key"), "secret")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        store.delete(key: "summary-key")

        XCTAssertNil(store.load(key: "summary-key"))
    }
    #endif

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int) -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return components.date!
    }
}

private actor InMemoryAppSettingsStore: AppSettingsStoreProtocol {
    private var settings = AppSettings.default

    func load(using loggingService: LoggingService) async -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) async throws {
        self.settings = settings
    }
}

private struct NoopKeychainStore: SecretStoreProtocol {
    func save(key: String, value: String) throws {}
    func load(key: String) -> String? { nil }
    func delete(key: String) {}
}
