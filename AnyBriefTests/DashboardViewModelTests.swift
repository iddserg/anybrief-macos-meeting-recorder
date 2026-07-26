import XCTest
@testable import AnyBrief

/// Tests dashboard activity timing for the current pipeline stage.
final class DashboardViewModelTests: XCTestCase {
    @MainActor
    func testModelDownloadDoesNotReportReadyWhenRequiredFilesRemainMissing() async {
        let fileManager = FileManager.default
        let modelsURL = fileManager.temporaryDirectory
            .appendingPathComponent("dashboard-missing-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelsURL) }

        let modelService = FluidAudioSTTModelService(
            fileManager: fileManager,
            sttURLResolver: { URL(fileURLWithPath: "/usr/bin/true") },
            modelsDirectoryURL: modelsURL,
            coreMLModelLoader: { _ in }
        )
        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            transcriptionModelService: modelService,
            fileManager: fileManager
        )
        viewModel.transcriptionProviderSelection = TranscriptionProviderID.fluidAudioSTT.rawValue
        viewModel.transcriptionDiarizationEnabled = true

        viewModel.downloadTranscriptionModels()
        for _ in 0..<100 where viewModel.isDownloadingTranscriptionModels {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(viewModel.isDownloadingTranscriptionModels)
        XCTAssertFalse(viewModel.transcriptionModelStatus.isInstalled)
        XCTAssertTrue(viewModel.transcriptionModelMessageIsError)
        XCTAssertNotEqual(
            viewModel.transcriptionModelMessage,
            String(localized: "Transcription models are ready.")
        )
    }

    @MainActor
    func testInAppNotificationStoreMarksNotificationsAsRead() {
        let store = InAppNotificationStore()

        let first = store.add(category: "recording_started", title: "AnyBrief", body: "Recording started")
        _ = store.add(category: "summary_ready", title: "AnyBrief", body: "Your brief is ready")

        XCTAssertEqual(store.unreadCount, 2)

        store.markAsRead(id: first.id)

        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.unreadNotifications.map(\.category), ["summary_ready"])
    }

    @MainActor
    func testInAppNotificationStoreSkipsUnreadDuplicates() {
        let store = InAppNotificationStore()

        let first = store.addIfUnreadDuplicateIsMissing(
            category: "recording_interrupted",
            title: "AnyBrief",
            body: "Recording was interrupted"
        )
        let duplicate = store.addIfUnreadDuplicateIsMissing(
            category: "recording_interrupted",
            title: "AnyBrief",
            body: "Recording was interrupted"
        )

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
        XCTAssertEqual(store.unreadCount, 1)
    }

    @MainActor
    func testInAppNotificationStoreMarksAllNotificationsAsRead() {
        let store = InAppNotificationStore()

        _ = store.add(category: "recording_started", title: "AnyBrief", body: "Recording started")
        _ = store.add(category: "summary_ready", title: "AnyBrief", body: "Your brief is ready")

        store.markAllAsRead()

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.unreadNotifications.isEmpty)
    }

    @MainActor
    func testInAppNotificationStoreRemovesReadNotifications() {
        let store = InAppNotificationStore()

        _ = store.add(category: "recording_started", title: "AnyBrief", body: "Recording started")
        _ = store.add(category: "summary_ready", title: "AnyBrief", body: "Your brief is ready")
        store.markAllAsRead()
        _ = store.add(category: "recording_stopped", title: "AnyBrief", body: "Recording stopped")

        store.removeReadNotifications()

        XCTAssertEqual(store.notifications.map(\.category), ["recording_stopped"])
        XCTAssertEqual(store.unreadCount, 1)
    }

    @MainActor
    func testNotificationServicePublishesInAppNotificationsWithoutSystemPermission() async {
        let store = InAppNotificationStore()
        let service = NotificationService(
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            inAppNotificationStore: store,
            permissionService: PermissionService(),
            loggingService: LoggingService(),
            checkPermissionStatus: { .denied },
            deliver: { _, _ in
                XCTFail("System delivery should not run when permission is denied")
            }
        )

        await service.notifyRecordingStarted()

        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.unreadNotifications.first?.category, NotificationService.Category.recordingStarted.rawValue)
    }

    @MainActor
    func testRefreshLoadsLocalAPIEnabledFlagFromSettings() async {
        var settings = AppSettings()
        settings.automation.localHTTPAPISettings.enabled = true

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )

        viewModel.startRefreshing()
        defer { viewModel.stopRefreshing() }

        for _ in 0..<50 where viewModel.localHTTPAPIEnabled == false {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(viewModel.localHTTPAPIEnabled)
    }

    @MainActor
    func testSaveSettingsPersistsLocalAPIEnabledFlagAndRestartsService() async {
        let store = MutableTestAppSettingsStore(settings: AppSettings())
        let restartExpectation = expectation(description: "local API restart callback")

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: store,
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            localAPISettingsDidChange: {
                restartExpectation.fulfill()
            }
        )
        viewModel.localHTTPAPIEnabled = true

        viewModel.saveSettings()

        await fulfillment(of: [restartExpectation], timeout: 2.0)
        XCTAssertTrue(store.lastSavedSettings?.automation.localHTTPAPISettings.enabled == true)
    }

    @MainActor
    func testSaveSettingsPersistsAppFeatureFlags() async {
        let store = MutableTestAppSettingsStore(settings: AppSettings())
        let saveExpectation = expectation(description: "settings save callback")

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: store,
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            localAPISettingsDidChange: {
                saveExpectation.fulfill()
            }
        )
        viewModel.liveTranscriptEnabled = true
        viewModel.postProcessingTabEnabled = true

        viewModel.saveSettings()

        await fulfillment(of: [saveExpectation], timeout: 2.0)
        XCTAssertTrue(store.lastSavedSettings?.application.liveTranscriptEnabled == true)
        XCTAssertTrue(store.lastSavedSettings?.application.postProcessingTabEnabled == true)
    }

    @MainActor
    func testCurrentActivityUsesStageStartTimeForProcessingJob() {
        let createdAt = Date(timeIntervalSince1970: 1_777_000_000)
        let stageStartedAt = createdAt.addingTimeInterval(18 * 60)
        let now = stageStartedAt.addingTimeInterval(44 * 60 + 26)
        let job = Job(
            id: "job-1",
            meetingId: "job-1",
            status: "processing",
            stage: .transcribingSystem,
            progressPercent: 20,
            source: "manual",
            createdAt: createdAt,
            updatedAt: stageStartedAt
        )

        let activity = DashboardViewModel.currentActivity(from: [job], appState: .processing, now: now)

        XCTAssertEqual(activity?.jobId, "job-1")
        XCTAssertEqual(activity?.stage, "transcribing_system")
        XCTAssertEqual(activity?.startedAt, stageStartedAt)
        XCTAssertEqual(activity?.duration ?? 0, 44 * 60 + 26, accuracy: 0.001)
    }

    @MainActor
    func testCurrentActivityHidesDuplicateStatusWhenStageMatches() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let job = Job(
            id: "job-2",
            meetingId: "job-2",
            status: "recording",
            stage: .recording,
            progressPercent: 0,
            source: "manual",
            createdAt: now,
            updatedAt: now
        )

        let activity = DashboardViewModel.currentActivity(from: [job], appState: .recording, now: now)

        XCTAssertEqual(activity?.showsSeparateStatus, false)
        XCTAssertFalse(activity?.summaryText.isEmpty ?? true)
        XCTAssertFalse(activity?.summaryText.contains("·") ?? true)
    }

    @MainActor
    func testCurrentActivityShowsDetailedLLMFallback() {
        let activity = DashboardViewModel.CurrentActivity(
            jobId: "job-3",
            status: "processing",
            stage: "processing_transcript",
            startedAt: Date(),
            duration: 10,
            detail: PipelineActivityDetail(
                phase: .transcriptCleanup,
                connectionName: "Ollama Gemma",
                connectionIndex: 4,
                connectionCount: 4,
                fallbackFrom: "Claude"
            )
        )

        XCTAssertEqual(
            activity.detailedStageLabel,
            "\(String(localized: "Cleaning transcript")) · Ollama Gemma"
        )
        let position = String(
            format: String(localized: "Connection %d of %d"),
            4,
            4
        )
        XCTAssertEqual(
            activity.fallbackText,
            String(
                format: String(localized: "%@ → %@ · %@"),
                "Claude",
                "Ollama Gemma",
                position
            )
        )
    }

    @MainActor
    func testLoadLogsIncludesRecentJobWarningsAndErrors() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        let jobsLogsURL = logsURL.appendingPathComponent("jobs", isDirectory: true)
        try fileManager.createDirectory(at: jobsLogsURL, withIntermediateDirectories: true)
        try """
        2026-06-25T14:00:00+03:00 [INFO] [Pipeline] ok
        2026-06-25T14:01:00+03:00 [WARN] [Recovery] preserved raw artifacts
        """.write(
            to: logsURL.appendingPathComponent("app.log", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        --- transcribing_system ---
        ERROR: stt timed out after 1080 seconds for /tmp/system.wav.
        """.write(
            to: jobsLogsURL.appendingPathComponent("job-1.log", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(logsDirectoryURL: logsURL),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )

        let logs = await viewModel.loadLogs()

        XCTAssertTrue(logs.activity.contains("[INFO] [Pipeline] ok"))
        XCTAssertTrue(logs.errors.contains("[WARN] [Recovery] preserved raw artifacts"))
        XCTAssertTrue(logs.errors.contains("ERROR: stt timed out after 1080 seconds"))
    }

    @MainActor
    func testRefreshKeepsExistingAutopilotEventsWhenCalendarReloadFails() async {
        var settings = AppSettings()
        settings.automation.calDAVSettings.enabled = true
        settings.automation.calDAVSettings.name = "work"
        settings.automation.calDAVSettings.config.url = "https://caldav.example.com"
        settings.automation.calDAVSettings.config.username = "alice"
        settings.automation.calDAVSettings.passwordKeychainRef = "calendar-password"

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings),
            keychainStore: TestKeychainStore(values: ["calendar-password": "secret"]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            calendarService: CalDAVCalendarService(dataLoader: { _ in
                throw URLError(.timedOut)
            })
        )
        let staleEvent = DashboardViewModel.AutopilotScheduleEvent(
            id: "existing-event",
            title: "Daily sync",
            startAt: Date(timeIntervalSince1970: 1_777_000_000),
            endAt: Date(timeIntervalSince1970: 1_777_003_600),
            participantCount: 2,
            hasMeetingURL: true,
            meetingURL: nil
        )
        viewModel.todayAutopilotEvents = [staleEvent]

        viewModel.startRefreshing()
        defer { viewModel.stopRefreshing() }

        for _ in 0..<50 where viewModel.lastRefreshAt == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(viewModel.todayAutopilotEvents.map(\.id), [staleEvent.id])
        XCTAssertEqual(viewModel.calendarScheduleError, URLError(.timedOut).localizedDescription)
    }

    @MainActor
    func testRepeatAllDispatchesMeetingReprocessingForBundledAudio() async throws {
        let rootURL = try makeTemporaryDirectory()
        let meetingURL = rootURL.appendingPathComponent("2026-07-25_12-00_Test_10m", isDirectory: true)
        let bundleURL = meetingURL.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data().write(to: bundleURL.appendingPathComponent("system_audio.mp3"))
        try Data().write(to: bundleURL.appendingPathComponent("microphone_audio.mp3"))

        let dispatched = expectation(description: "meeting reprocessing dispatched")
        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(meetingsDirectoryURL: rootURL),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            repeatMeetingProcessingAction: { folderURL, jobId, title, mode in
                XCTAssertEqual(folderURL, meetingURL)
                XCTAssertEqual(jobId, "job-repeat")
                XCTAssertEqual(title, "Test")
                XCTAssertEqual(mode, .all)
                dispatched.fulfill()
            }
        )
        let meeting = DashboardViewModel.RecentMeeting(
            id: meetingURL.path,
            title: "Test",
            timestamp: Date(),
            status: "completed",
            folderURL: meetingURL,
            summaryURL: nil,
            jobId: "job-repeat",
            needsFolderRename: false
        )

        XCTAssertTrue(viewModel.canRepeatMeetingProcessing(meeting))
        viewModel.repeatMeetingProcessing(meeting, mode: .all)

        await fulfillment(of: [dispatched], timeout: 2.0)
    }
}

private actor TestJobRepository: JobRepositoryProtocol {
    func load() async -> [Job] { [] }
    func save(_ jobs: [Job]) async {}
    func upsert(_ job: Job) async {}
    func get(id: String) async -> Job? { nil }
}

private final class TestAppSettingsStore: AppSettingsStoreProtocol {
    fileprivate let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load(using loggingService: LoggingService) async -> AppSettings { settings }
    func save(_ settings: AppSettings) async throws {}
}

private final class MutableTestAppSettingsStore: AppSettingsStoreProtocol {
    var settings: AppSettings
    private(set) var lastSavedSettings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load(using loggingService: LoggingService) async -> AppSettings { settings }

    func save(_ settings: AppSettings) async throws {
        self.settings = settings
        lastSavedSettings = settings
    }
}

private final class TestKeychainStore: SecretStoreProtocol {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(key: String, value: String) throws {}
    func load(key: String) -> String? { values[key] }
    func delete(key: String) {}
}

private final class TestDashboardStorageService: StorageServiceProtocol {
    let meetingsDirectoryURL: URL

    init(
        meetingsDirectoryURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    ) {
        self.meetingsDirectoryURL = meetingsDirectoryURL
    }

    func prepareStorage(using loggingService: LoggingService) async throws {}
    func createMeetingFolder(jobId: String, startedAt: Date) throws -> MeetingPaths { fatalError("unused in test") }
    func renameMeetingFolder(from paths: MeetingPaths, duration: TimeInterval) throws -> URL { fatalError("unused in test") }
    func findMeetingPaths(jobId: String, createdAt: Date) throws -> MeetingPaths? { nil }
    func cleanupTemporaryArtifacts(for paths: MeetingPaths) throws {}
}

private struct TestLaunchAtLoginController: LaunchAtLoginControlling {
    func setEnabled(_ enabled: Bool) throws {}
}
