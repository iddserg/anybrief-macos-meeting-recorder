import Foundation

enum AppState: Equatable {
    case idle
    case needsPermissions
    case recording
    case processing
    case error
}

final class AppEnvironment {
    static let shared = AppEnvironment()
    let loggingService = LoggingService.shared
    let permissionService = PermissionService()
    let inAppNotificationStore = InAppNotificationStore()
    let appSettingsStore: AppSettingsStoreProtocol
    let keychainStore: SecretStoreProtocol
    let storageService: StorageServiceProtocol
    let transcriptionService = TranscriptionService()
    let transcriptMergeService = TranscriptMergeService()
    let llmService: LLMService
    let summarizationService: SummarizationService
    let jobRepository: JobRepositoryProtocol
    var appState: AppState

    private init() {
        let appSettingsStore = AppSettingsStore()
        self.appSettingsStore = appSettingsStore
        self.keychainStore = SecretStoreFactory.makeDefault()
        let initialSettings = (try? appSettingsStore.loadSynchronously()) ?? .default
        jobRepository = JobRepository(
            loggingService: loggingService,
            historyLimit: initialSettings.application.jobsHistoryLimit
        )
        storageService = StorageService(
            appSettingsStore: appSettingsStore,
            keychainStore: keychainStore
        )
        let summaryLogger = loggingService
        llmService = LLMService(keychainStore: keychainStore, logger: { message, level in
            await summaryLogger.log(message, level: level, component: "LLM")
        })
        summarizationService = SummarizationService(keychainStore: keychainStore, llmService: llmService, logger: { message, level in
            await summaryLogger.log(message, level: level, component: "Summary")
        })
        appState = .idle
    }
}
