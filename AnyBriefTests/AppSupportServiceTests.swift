import XCTest
import Network
@testable import AnyBrief

final class AppSupportServiceTests: XCTestCase {
    override func tearDown() {
        OllamaURLProtocol.reset()
        super.tearDown()
    }

    func testLoadOllamaModelsReturnsSortedUniqueNames() async throws {
        OllamaURLProtocol.handler = { request in
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                #"{"models":[{"name":"qwen3:latest"},{"name":"llama3.2:latest"},{"name":"qwen3:latest"}]}"#
                    .data(using: .utf8)!
            )
        }

        let service = OllamaModelDiscoveryService(urlSession: Self.mockSession())

        let models = try await service.fetchModels()

        XCTAssertEqual(models, ["llama3.2:latest", "qwen3:latest"])
    }

    func testOllamaContextInfoReadsRunningAndShowMetadata() async throws {
        OllamaURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/ps":
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"models":[{"model":"gemma4:latest","context_length":65536}]}"#.data(using: .utf8)!
                )
            case "/api/show":
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"parameters":"temperature 0.7\nnum_ctx 32768","model_info":{"gemma4.context_length":131072}}"#.data(using: .utf8)!
                )
            default:
                throw URLError(.badURL)
            }
        }

        let service = OllamaModelDiscoveryService(urlSession: Self.mockSession())

        let info = try await service.fetchContextInfo(for: "gemma4:latest")

        XCTAssertEqual(info.runningContextLength, 65_536)
        XCTAssertEqual(info.modelMaxContextLength, 131_072)
        XCTAssertEqual(info.modelfileContextLength, 32_768)
    }

    func testOllamaContextInfoTreatsEmptyPsAsNotLoaded() async throws {
        OllamaURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/ps":
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"models":[]}"#.data(using: .utf8)!
                )
            case "/api/show":
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"parameters":"","model_info":{"gemma4.context_length":131072}}"#.data(using: .utf8)!
                )
            default:
                throw URLError(.badURL)
            }
        }

        let service = OllamaModelDiscoveryService(urlSession: Self.mockSession())

        let info = try await service.fetchContextInfo(for: "gemma4:latest")

        XCTAssertNil(info.runningContextLength)
        XCTAssertEqual(info.modelMaxContextLength, 131_072)
        XCTAssertNil(info.modelfileContextLength)
    }

    func testLaunchAtLoginControllerRegistersWhenEnablingDisabledService() throws {
        let service = MockLaunchAtLoginService(status: .notRegistered)
        let controller = LaunchAtLoginController(service: service)

        try controller.setEnabled(true)

        XCTAssertEqual(service.registerCalls, 1)
        XCTAssertEqual(service.unregisterCalls, 0)
    }

    func testLaunchAtLoginControllerUnregistersWhenDisablingEnabledService() throws {
        let service = MockLaunchAtLoginService(status: .enabled)
        let controller = LaunchAtLoginController(service: service)

        try controller.setEnabled(false)

        XCTAssertEqual(service.registerCalls, 0)
        XCTAssertEqual(service.unregisterCalls, 1)
    }

    func testSingleInstanceLockRejectsSecondAcquireForSamePath() throws {
        let fileManager = FileManager.default
        let homeDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: homeDirectoryURL, withIntermediateDirectories: true)

        let firstLock = try SingleInstanceLock.acquire(
            fileManager: fileManager,
            homeDirectoryURL: homeDirectoryURL
        )
        _ = firstLock

        XCTAssertThrowsError(
            try SingleInstanceLock.acquire(
                fileManager: fileManager,
                homeDirectoryURL: homeDirectoryURL
            )
        ) { error in
            XCTAssertEqual(error as? SingleInstanceLock.LockError, .alreadyRunning)
        }
    }

    func testJobProgressMatchesStateMachineMilestones() {
        XCTAssertEqual(JobProgress.percent(for: .recording, status: "recording"), 0)
        XCTAssertEqual(JobProgress.percent(for: .recorded, status: "recorded"), 20)
        XCTAssertEqual(JobProgress.percent(for: .transcribingSystem, status: "processing"), 20)
        XCTAssertEqual(JobProgress.percent(for: .transcribingMic, status: "processing"), 40)
        XCTAssertEqual(JobProgress.percent(for: .mergingTranscripts, status: "processing"), 55)
        XCTAssertEqual(JobProgress.percent(for: .summarizing, status: "processing"), 60)
        XCTAssertEqual(JobProgress.percent(for: .convertingAudio, status: "processing"), 85)
        XCTAssertEqual(JobProgress.percent(for: .packaging, status: "processing"), 92)
    }
}

private extension AppSupportServiceTests {
    static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private final class MockLaunchAtLoginService: LaunchAtLoginServiceProtocol {
    var status: LaunchAtLoginServiceStatus
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() throws {
        registerCalls += 1
    }

    func unregister() throws {
        unregisterCalls += 1
    }
}

private final class OllamaURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    static func reset() {
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class LocalAPIListenerFactoryTests: XCTestCase {
    func testListenerParametersRequireLoopbackEndpoint() {
        let factory = LocalAPIListenerFactory()

        let parameters = factory.listenerParameters(port: 47_823)

        guard case let .hostPort(host, port)? = parameters.requiredLocalEndpoint else {
            return XCTFail("Expected loopback host:port endpoint.")
        }

        XCTAssertEqual("\(host)", "127.0.0.1")
        XCTAssertEqual(port.rawValue, 47_823)
    }
}

final class LocalAPISettingsTests: XCTestCase {
    func testSettingsGetReturnsGroupedPayload() async throws {
        var settings = AppSettings()
        settings.automation.localHTTPAPISettings.apiKeyKeychainRef = "api-key"
        settings.application.storageRoot = "~/custom"
        settings.application.liveTranscriptEnabled = true
        settings.application.postProcessingTabEnabled = true
        settings.recording.microphoneDeviceUID = "saved-input-device"
        settings.postProcessing.rules = [
            PostProcessingRuleConfiguration(
                id: "api-rule",
                title: "API Rule",
                calendarTitlePattern: "API Sync",
                destinationFolderPath: "/tmp/api-sync"
            ),
        ]
        settings.automation.localHTTPAPISettings.enabled = true
        settings.automation.localHTTPAPISettings.port = 48_001
        let fixture = LocalAPISettingsFixture(settings: settings, secrets: ["api-key": "secret"])

        let response = await fixture.service.handleForTesting(method: "GET", path: "/settings", apiKey: "secret")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(response.payload["application"])
        XCTAssertNotNil(response.payload["recording"])
        XCTAssertNotNil(response.payload["summary"])
        XCTAssertNotNil(response.payload["transcription"])
        XCTAssertNotNil(response.payload["automation"])
        XCTAssertNotNil(response.payload["postProcessing"])
        XCTAssertNil(response.payload["storageRoot"])

        let application = try XCTUnwrap(response.payload["application"] as? [String: Any])
        XCTAssertEqual(application["storageRoot"] as? String, "~/custom")
        XCTAssertEqual(application["liveTranscriptEnabled"] as? Bool, true)
        XCTAssertEqual(application["postProcessingTabEnabled"] as? Bool, true)
        let recording = try XCTUnwrap(response.payload["recording"] as? [String: Any])
        XCTAssertEqual(recording["microphoneDeviceUID"] as? String, "saved-input-device")
        let postProcessing = try XCTUnwrap(response.payload["postProcessing"] as? [String: Any])
        let postProcessingRules = try XCTUnwrap(postProcessing["rules"] as? [[String: Any]])
        XCTAssertEqual(postProcessingRules.first?["id"] as? String, "api-rule")
        XCTAssertEqual(postProcessingRules.first?["calendarTitlePattern"] as? String, "API Sync")
        let automation = try XCTUnwrap(response.payload["automation"] as? [String: Any])
        let sources = try XCTUnwrap(automation["sources"] as? [[String: Any]])
        let localHTTPAPI = try XCTUnwrap(sources.first { $0["source"] as? String == "local_http_api" })
        let localHTTPAPIPayload = try XCTUnwrap(localHTTPAPI["payload"] as? [String: Any])
        XCTAssertEqual(localHTTPAPIPayload["port"] as? Int, 48_001)
    }

    func testSettingsPutAppliesGroupedPayloadAndStoresLocalHTTPAPIKey() async throws {
        var settings = AppSettings()
        settings.automation.localHTTPAPISettings.apiKeyKeychainRef = "api-key"
        settings.automation.localHTTPAPISettings.port = 47_823
        let store = LocalAPITestSettingsStore(settings: settings)
        let secrets = LocalAPITestSecretStore(values: ["api-key": "secret"])
        let service = LocalAPISettingsFixture.makeService(settingsStore: store, secretStore: secrets)

        let response = await service.handleForTesting(
            method: "PUT",
            path: "/settings",
            body: [
                "application": [
                    "storageRoot": "~/grouped",
                    "locale": "ru",
                    "liveTranscriptEnabled": true,
                    "postProcessingTabEnabled": true,
                ],
                "recording": [
                    "microphoneVoiceProcessingEnabled": true,
                    "microphoneDeviceUID": "put-input-device",
                ],
                "summary": [
                    "enabled": true,
                ],
                "llm": [
                    "connections": [
                        [
                            "id": "put-connection",
                            "provider": "openai_compatible",
                            "enabled": true,
                            "retryCount": 5,
                            "timeoutSec": 180,
                            "payload": [:],
                        ],
                    ],
                ],
                "prompts": [
                    "items": [
                        [
                            "id": "put-prompt",
                            "name": "PUT Prompt",
                            "text": "Summarize briefly.",
                            "titlePatterns": ["standup"],
                        ],
                    ],
                    "summary": [
                        "promptID": "put-prompt",
                        "speakerContextPromptID": "put-prompt",
                    ],
                    "live": [
                        "connectionID": nil,
                    ],
                ],
                "transcription": [
                    "diarizationEnabled": false,
                    "skipMicrophoneDiarization": false,
                    "customVocabulary": "Admon\nMGCom: сам же ком",
                    "providers": [
                        [
                            "provider": "fluid_audio_stt",
                            "enabled": true,
                            "payload": [
                                "speakersMode": "fixed",
                                "speakersCount": 4,
                                "threshold": 0.42,
                            ],
                        ],
                    ],
                ],
                "postProcessing": [
                    "enabled": true,
                    "rules": [
                        [
                            "id": "put-rule",
                            "title": "PUT Rule",
                            "enabled": true,
                            "matchMode": "contains",
                            "calendarTitlePattern": "PUT Sync",
                            "destinationFolderPath": "/tmp/put-sync",
                            "filenameTemplate": "{date} {calendarTitle}.md",
                            "conflictBehavior": "addSuffix",
                        ],
                    ],
                ],
                "automation": [
                    "sources": [
                        [
                            "source": "local_http_api",
                            "enabled": false,
                            "payload": [
                                "enabled": false,
                                "port": 48_123,
                                "apiKey": "new-secret",
                            ],
                        ],
                        [
                            "source": "caldav",
                            "enabled": true,
                            "payload": [
                                "enabled": true,
                                "name": "work",
                                "config": [
                                    "url": "https://caldav.example.com",
                                    "username": "alice",
                                ],
                            ],
                        ],
                    ],
                    "rules": [
                        [
                            "kind": "calendar_autopilot",
                            "source": "caldav",
                            "enabled": true,
                            "payload": [
                                "enabled": true,
                                "pollIntervalSec": 120,
                            ],
                        ],
                    ],
                ],
            ],
            apiKey: "secret"
        )

        XCTAssertEqual(response.statusCode, 200)
        let saved = try XCTUnwrap(store.lastSavedSettings)
        XCTAssertEqual(saved.application.storageRoot, "~/grouped")
        XCTAssertEqual(saved.application.locale, "ru")
        XCTAssertTrue(saved.application.liveTranscriptEnabled)
        XCTAssertTrue(saved.application.postProcessingTabEnabled)
        XCTAssertTrue(saved.recording.microphoneVoiceProcessingEnabled)
        XCTAssertEqual(saved.recording.microphoneDeviceUID, "put-input-device")
        XCTAssertTrue(saved.summary.enabled)
        XCTAssertEqual(saved.prompts.summary.speakerContextPromptID, "put-prompt")
        XCTAssertEqual(saved.llm.connections.first?.retryCount, 5)
        XCTAssertEqual(saved.llm.connections.first?.timeoutSec, 180)
        XCTAssertEqual(saved.prompts.summary.promptID, "put-prompt")
        XCTAssertEqual(saved.prompts.items.first?.id, "put-prompt")
        XCTAssertEqual(saved.prompts.items.first?.titlePatterns, ["standup"])
        XCTAssertNil(saved.prompts.live.connectionID)
        XCTAssertTrue(saved.postProcessing.enabled)
        XCTAssertEqual(saved.postProcessing.rules.count, 1)
        XCTAssertEqual(saved.postProcessing.rules.first?.id, "put-rule")
        XCTAssertEqual(saved.postProcessing.rules.first?.destinationFolderPath, "/tmp/put-sync")
        XCTAssertEqual(saved.postProcessing.rules.first?.conflictBehavior, .addSuffix)
        XCTAssertEqual(saved.transcription.fluidAudioSTTConfig.speakersMode, "fixed")
        XCTAssertEqual(saved.transcription.fluidAudioSTTConfig.speakersCount, 4)
        XCTAssertEqual(saved.transcription.fluidAudioSTTConfig.threshold, 0.42)
        XCTAssertFalse(saved.transcription.diarizationEnabled)
        XCTAssertFalse(saved.transcription.skipMicrophoneDiarization)
        XCTAssertEqual(
            saved.transcription.fluidAudioSTTConfig.customVocabulary,
            "Admon\nMGCom: сам же ком"
        )
        XCTAssertEqual(
            saved.transcription.whisperCppConfig.customVocabulary,
            "Admon\nMGCom: сам же ком"
        )
        XCTAssertFalse(saved.automation.localHTTPAPISettings.enabled)
        XCTAssertEqual(saved.automation.localHTTPAPISettings.port, 48_123)
        XCTAssertEqual(saved.automation.calDAVSettings.config.url, "https://caldav.example.com")
        XCTAssertEqual(saved.automation.calDAVSettings.config.username, "alice")
        XCTAssertTrue(saved.automation.calendarAutopilotSettings.enabled)
        XCTAssertEqual(saved.automation.calendarAutopilotSettings.pollIntervalSec, 120)
        XCTAssertEqual(secrets.load(key: "api-key"), "new-secret")
    }

    func testSettingsPutRoundTripsWindowObserverGroupedPayload() async throws {
        var settings = AppSettings()
        settings.automation.localHTTPAPISettings.apiKeyKeychainRef = "api-key"
        let store = LocalAPITestSettingsStore(settings: settings)
        let secrets = LocalAPITestSecretStore(values: ["api-key": "secret"])
        let service = LocalAPISettingsFixture.makeService(settingsStore: store, secretStore: secrets)

        let response = await service.handleForTesting(
            method: "PUT",
            path: "/settings",
            body: [
                "automation": [
                    "sources": [
                        [
                            "source": "window_observer",
                            "enabled": true,
                            "payload": [
                                "enabled": true,
                                "actionMode": "notify",
                                "scope": "all_visible_windows",
                                "stableMatchSec": 15,
                                "pollIntervalSec": 4,
                                "rules": [
                                    [
                                        "id": "zoom-rule",
                                        "enabled": true,
                                        "name": "Zoom Meetings",
                                        "applicationPattern": " zoom ",
                                        "titlePattern": " sprint ",
                                    ],
                                ],
                            ],
                        ],
                    ],
                ],
            ],
            apiKey: "secret"
        )

        XCTAssertEqual(response.statusCode, 200)
        let saved = try XCTUnwrap(store.lastSavedSettings)
        XCTAssertTrue(saved.automation.windowObserverSettings.enabled)
        XCTAssertEqual(saved.automation.windowObserverSettings.actionMode, .notify)
        XCTAssertEqual(saved.automation.windowObserverSettings.scope, .allVisibleWindows)
        XCTAssertEqual(saved.automation.windowObserverSettings.stableMatchSec, 15)
        XCTAssertEqual(saved.automation.windowObserverSettings.pollIntervalSec, 4)
        XCTAssertEqual(saved.automation.windowObserverSettings.rules.count, 1)
        XCTAssertEqual(saved.automation.windowObserverSettings.rules[0].id, "zoom-rule")
        XCTAssertEqual(saved.automation.windowObserverSettings.rules[0].applicationPattern, "zoom")
        XCTAssertEqual(saved.automation.windowObserverSettings.rules[0].titlePattern, "sprint")

        let getResponse = await service.handleForTesting(method: "GET", path: "/settings", apiKey: "secret")

        XCTAssertEqual(getResponse.statusCode, 200)
        let automation = try XCTUnwrap(getResponse.payload["automation"] as? [String: Any])
        let sources = try XCTUnwrap(automation["sources"] as? [[String: Any]])
        let windowObserverSource = try XCTUnwrap(sources.first { $0["source"] as? String == "window_observer" })
        let windowObserver = try XCTUnwrap(windowObserverSource["payload"] as? [String: Any])
        XCTAssertEqual(windowObserver["enabled"] as? Bool, true)
        XCTAssertEqual(windowObserver["actionMode"] as? String, "notify")
        XCTAssertEqual(windowObserver["scope"] as? String, "all_visible_windows")
        XCTAssertEqual(windowObserver["stableMatchSec"] as? Int, 15)
        XCTAssertEqual(windowObserver["pollIntervalSec"] as? Int, 4)
        let rules = try XCTUnwrap(windowObserver["rules"] as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
        XCTAssertEqual(rules[0]["id"] as? String, "zoom-rule")
        XCTAssertEqual(rules[0]["enabled"] as? Bool, true)
        XCTAssertEqual(rules[0]["name"] as? String, "Zoom Meetings")
        XCTAssertEqual(rules[0]["applicationPattern"] as? String, "zoom")
        XCTAssertEqual(rules[0]["titlePattern"] as? String, "sprint")
    }
}

private final class LocalAPISettingsFixture {
    let service: LocalAPIService

    init(settings: AppSettings, secrets: [String: String]) {
        let store = LocalAPITestSettingsStore(settings: settings)
        let secretStore = LocalAPITestSecretStore(values: secrets)
        service = Self.makeService(settingsStore: store, secretStore: secretStore)
    }

    static func makeService(
        settingsStore: LocalAPITestSettingsStore,
        secretStore: LocalAPITestSecretStore
    ) -> LocalAPIService {
        let loggingService = LoggingService()
        let jobRepository = LocalAPITestJobRepository()
        let storageService = LocalAPITestStorageService()
        let recordingAdapter = RecordingAdapter(
            storageService: storageService,
            appSettingsStore: settingsStore,
            jobRepository: jobRepository,
            loggingService: loggingService,
            appStateDidChange: { _ in }
        )
        let finalizationService = FinalizationService(
            storageService: storageService,
            jobRepository: jobRepository,
            loggingService: loggingService,
            appStateDidChange: { _ in }
        )
        let pipelineOrchestrator = PipelineOrchestrator(
            jobRepository: jobRepository,
            appSettingsStore: settingsStore,
            transcriptionService: TranscriptionService(),
            transcriptMergeService: TranscriptMergeService(),
            summarizationService: SummarizationService(keychainStore: secretStore),
            finalizationService: finalizationService,
            loggingService: loggingService,
            appStateDidChange: { _ in }
        )
        return LocalAPIService(
            appSettingsStore: settingsStore,
            keychainStore: secretStore,
            jobRepository: jobRepository,
            loggingService: loggingService,
            permissionService: PermissionService(),
            storageService: storageService,
            recordingAdapter: recordingAdapter,
            pipelineOrchestrator: pipelineOrchestrator,
            appStateProvider: { .idle },
            listenerFactory: LocalAPITestListenerFactory()
        )
    }
}

private final class LocalAPITestSettingsStore: AppSettingsStoreProtocol {
    private var settings: AppSettings
    private(set) var lastSavedSettings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load(using loggingService: LoggingService) async -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) async throws {
        self.settings = settings
        lastSavedSettings = settings
    }
}

private final class LocalAPITestSecretStore: SecretStoreProtocol {
    private var values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(key: String, value: String) throws {
        values[key] = value
    }

    func load(key: String) -> String? {
        values[key]
    }

    func delete(key: String) {
        values.removeValue(forKey: key)
    }
}

private final class LocalAPITestJobRepository: JobRepositoryProtocol {
    private var jobs: [Job] = []

    func load() async -> [Job] { jobs }
    func save(_ jobs: [Job]) async { self.jobs = jobs }
    func upsert(_ job: Job) async { jobs.removeAll { $0.id == job.id }; jobs.append(job) }
    func get(id: String) async -> Job? { jobs.first { $0.id == id } }
}

private final class LocalAPITestStorageService: StorageServiceProtocol {
    let meetingsDirectoryURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    func prepareStorage(using loggingService: LoggingService) async throws {}
    func createMeetingFolder(jobId: String, startedAt: Date) throws -> MeetingPaths { fatalError("unused in test") }
    func renameMeetingFolder(from paths: MeetingPaths, duration: TimeInterval) throws -> URL { fatalError("unused in test") }
    func findMeetingPaths(jobId: String, createdAt: Date) throws -> MeetingPaths? { nil }
    func cleanupTemporaryArtifacts(for paths: MeetingPaths) throws {}
}

private struct LocalAPITestListenerFactory: LocalAPIListenerFactoryProtocol {
    func makeListener(port: UInt16) throws -> NWListener {
        throw NSError(domain: "LocalAPITestListenerFactory", code: 1)
    }
}
