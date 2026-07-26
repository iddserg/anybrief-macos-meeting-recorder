import Foundation

/// Facade that wires automation sources through AutomationEngine.
/// Sources come from the registry only; source-specific services stay in their modules.
actor AutopilotService {
    private let automationEngine: AutomationEngine

    init(
        automationSourceRegistry: AutomationSourceRegistry = .default,
        appSettingsStore: AppSettingsStoreProtocol,
        keychainStore: SecretStoreProtocol,
        jobRepository: JobRepositoryProtocol,
        recordingAdapter: RecordingAdapter,
        pipelineOrchestrator: PipelineOrchestrator,
        loggingService: LoggingService,
        notifyWindowMatch: @escaping @Sendable (WindowObserverMatch) async -> Void = { _ in },
        sleep: @escaping @Sendable (UInt64) async -> Void = { value in
            try? await Task.sleep(nanoseconds: value)
        }
    ) {
        let currentSessionProvider: @Sendable () async -> RecordingSession? = {
            await recordingAdapter.currentSession()
        }
        let context = AutomationRuntimeContext(
            appSettingsStore: appSettingsStore,
            keychainStore: keychainStore,
            loggingService: loggingService,
            currentSessionProvider: currentSessionProvider,
            sleep: sleep
        )
        let sources = Self.makeSources(
            registry: automationSourceRegistry,
            context: context
        )
        let resolver = AutomationActionResolver(
            jobRepository: jobRepository,
            currentSessionProvider: currentSessionProvider
        )
        let handler = AutomationActionHandler(
            recordingAdapter: recordingAdapter,
            pipelineOrchestrator: pipelineOrchestrator,
            loggingService: loggingService,
            notifyWindowMatch: notifyWindowMatch
        )

        automationEngine = AutomationEngine(
            sources: sources,
            resolveActions: { event in
                await resolver.resolve(event)
            },
            handleAction: { action in
                await handler.handle(action)
            }
        )
    }

    static func makeSources(
        registry: AutomationSourceRegistry,
        context: AutomationRuntimeContext
    ) -> [any AutomationSource] {
        registry.modules.map { module in
            module.makeSource(context: context)
        }
    }

    func start() async {
        await automationEngine.start()
    }

    func stop() async {
        await automationEngine.stop()
    }
}
