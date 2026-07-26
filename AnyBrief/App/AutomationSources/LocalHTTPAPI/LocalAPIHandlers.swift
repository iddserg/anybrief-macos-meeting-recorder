import Foundation

actor LocalAPIHandlers {
    let appSettingsStore: AppSettingsStoreProtocol
    let keychainStore: SecretStoreProtocol
    let jobRepository: JobRepositoryProtocol
    let loggingService: LoggingService
    let permissionService: PermissionService
    let storageService: StorageServiceProtocol
    let recordingAdapter: RecordingAdapter
    let pipelineOrchestrator: PipelineOrchestrator
    let appStateProvider: @Sendable () async -> AppState
    let fileManager: FileManager
    let settingsDidChangeHandler: LocalAPISettingsDidChangeHandler
    var lastRecordingStartAt: Date?

    init(
        appSettingsStore: AppSettingsStoreProtocol,
        keychainStore: SecretStoreProtocol,
        jobRepository: JobRepositoryProtocol,
        loggingService: LoggingService,
        permissionService: PermissionService,
        storageService: StorageServiceProtocol,
        recordingAdapter: RecordingAdapter,
        pipelineOrchestrator: PipelineOrchestrator,
        appStateProvider: @escaping @Sendable () async -> AppState,
        fileManager: FileManager = .default,
        settingsDidChangeHandler: LocalAPISettingsDidChangeHandler = LocalAPISettingsDidChangeHandler()
    ) {
        self.appSettingsStore = appSettingsStore
        self.keychainStore = keychainStore
        self.jobRepository = jobRepository
        self.loggingService = loggingService
        self.permissionService = permissionService
        self.storageService = storageService
        self.recordingAdapter = recordingAdapter
        self.pipelineOrchestrator = pipelineOrchestrator
        self.appStateProvider = appStateProvider
        self.fileManager = fileManager
        self.settingsDidChangeHandler = settingsDidChangeHandler
    }

    func handle(request: HTTPRequest) async -> HTTPResponse {
        await logRequest(request)

        if request.method == "OPTIONS" {
            return response(status: 204, body: Data(), contentType: nil, request: request)
        }

        if request.path == "/health" {
            return jsonResponse([
                "ok": true,
                "service": "anybrief",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0",
            ], request: request)
        }

        let settings = await appSettingsStore.load(using: loggingService)
        guard let apiKeyReference = settings.automation.localHTTPAPISettings.apiKeyKeychainRef,
              let expectedAPIKey = keychainStore.load(key: apiKeyReference),
              let providedAPIKey = request.headers["x-api-key"],
              Self.constantTimeEquals(providedAPIKey, expectedAPIKey) else {
            return errorResponse(
                status: 401,
                code: "invalid_api_key",
                message: "API key is missing or invalid",
                request: request
            )
        }

        do {
            return try await dispatchAuthenticated(request: request)
        } catch let error as APIError {
            return errorResponse(status: error.status, code: error.code, message: error.message, details: error.details, request: request)
        } catch {
            return errorResponse(status: 500, code: "internal_error", message: error.localizedDescription, request: request)
        }
    }

    /// Compares two API keys in time independent of how many leading bytes match,
    /// avoiding a timing side channel on the secret.
    static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else {
            return false
        }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }

    func dispatchAuthenticated(request: HTTPRequest) async throws -> HTTPResponse {
        switch (request.method, request.path) {
        case ("GET", "/status"):
            return try await handleStatus(request: request)
        case ("GET", "/permissions"):
            return try await handlePermissions(request: request)
        case ("POST", "/recording/start"):
            return try await handleRecordingStart(request: request)
        case ("POST", "/recording/stop"):
            return try await handleRecordingStop(request: request)
        case ("POST", "/recording/disable-auto-stop"):
            return try await handleDisableAutoStop(request: request)
        case ("GET", "/recording/current"):
            return try await handleCurrentRecording(request: request)
        case ("GET", "/jobs"):
            return try await handleJobs(request: request)
        case ("GET", let path) where path.hasPrefix("/jobs/"):
            return try await handleJobRoute(request: request)
        case ("POST", let path) where path.hasPrefix("/jobs/"):
            return try await handleJobRoute(request: request)
        case ("GET", "/meetings/today"):
            return try await handleMeetingsToday(request: request)
        case ("GET", "/meetings/recent"):
            return try await handleMeetingsRecent(request: request)
        case ("GET", let path) where path.hasPrefix("/meetings/"):
            return try await handleMeetingRoute(request: request)
        case ("GET", "/settings"):
            return try await handleSettingsGet(request: request)
        case ("PUT", "/settings"):
            return try await handleSettingsPut(request: request)
        case ("GET", "/logs/recent"):
            return try await handleRecentLogs(request: request)
        default:
            return errorResponse(status: 404, code: "not_found", message: "Resource not found", request: request)
        }
    }

    #if DEBUG
    func handleForTesting(
        method: String,
        path: String,
        body: [String: Any] = [:],
        apiKey: String? = nil
    ) async -> (statusCode: Int, payload: [String: Any]) {
        let bodyData = body.isEmpty
            ? Data()
            : ((try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])) ?? Data())
        var headers: [String: String] = [:]
        if let apiKey {
            headers["x-api-key"] = apiKey
        }
        let response = await handle(request: HTTPRequest(
            method: method,
            path: path,
            query: [:],
            headers: headers,
            body: bodyData
        ))
        let payload = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] ?? [:]
        return (response.statusCode, payload)
    }
    #endif
}
