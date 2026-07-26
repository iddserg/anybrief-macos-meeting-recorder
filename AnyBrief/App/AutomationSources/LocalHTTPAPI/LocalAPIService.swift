import Foundation
import Network

/// Local HTTP API lifecycle coordinator for localhost agents.
actor LocalAPIService {
    private let appSettingsStore: AppSettingsStoreProtocol
    private let loggingService: LoggingService
    private let listener: LocalAPIListener
    private let handlers: LocalAPIHandlers
    private let settingsDidChangeHandler: LocalAPISettingsDidChangeHandler

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
        listenerFactory: LocalAPIListenerFactoryProtocol = LocalAPIListenerFactory()
    ) {
        self.appSettingsStore = appSettingsStore
        self.loggingService = loggingService
        listener = LocalAPIListener(factory: listenerFactory)
        settingsDidChangeHandler = LocalAPISettingsDidChangeHandler()
        handlers = LocalAPIHandlers(
            appSettingsStore: appSettingsStore,
            keychainStore: keychainStore,
            jobRepository: jobRepository,
            loggingService: loggingService,
            permissionService: permissionService,
            storageService: storageService,
            recordingAdapter: recordingAdapter,
            pipelineOrchestrator: pipelineOrchestrator,
            appStateProvider: appStateProvider,
            fileManager: fileManager,
            settingsDidChangeHandler: settingsDidChangeHandler
        )
        settingsDidChangeHandler.set { [weak self] in
            await self?.start()
        }
    }

    func start() async {
        let settings = await appSettingsStore.load(using: loggingService)
        guard settings.automation.localHTTPAPISettings.enabled else {
            listener.stop()
            return
        }

        let port = UInt16(clamping: settings.automation.localHTTPAPISettings.port)
        do {
            try listener.start(
                port: port,
                stateHandler: { [weak self] state in
                    Task {
                        await self?.handleListenerState(state, port: port)
                    }
                },
                requestHandler: { [handlers] request in
                    await handlers.handle(request: request)
                }
            )
        } catch {
            await loggingService.log(
                "Failed to start Local API listener on 127.0.0.1:\(port): \(error.localizedDescription)",
                level: .error,
                component: "LocalAPI"
            )
        }
    }

    private func handleListenerState(_ state: NWListener.State, port: UInt16) async {
        switch state {
        case .ready:
            await loggingService.log(
                "Local API listening on http://127.0.0.1:\(port)",
                level: .info,
                component: "LocalAPI"
            )
        case let .failed(error):
            await loggingService.log(
                "Local API listener failed on 127.0.0.1:\(port): \(error)",
                level: .error,
                component: "LocalAPI"
            )
        default:
            break
        }
    }

    #if DEBUG
    func handleForTesting(
        method: String,
        path: String,
        body: [String: Any] = [:],
        apiKey: String? = nil
    ) async -> (statusCode: Int, payload: [String: Any]) {
        await handlers.handleForTesting(method: method, path: path, body: body, apiKey: apiKey)
    }
    #endif
}
