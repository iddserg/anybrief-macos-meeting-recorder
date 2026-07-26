import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let reopenDashboardNotification = Notification.Name("pro.anybrief.reopenDashboard")

    let environment = AppEnvironment.shared
    let menuBarManager = MenuBarManager()
    var menuContext = MenuBarContext(appState: .idle, currentSession: nil)
    var dashboardWindowController: DashboardWindowController?
    let launchAtLoginController = LaunchAtLoginController()
    var workspaceSleepObserver: NSObjectProtocol?
    var reopenDashboardObserver: NSObjectProtocol?
    var singleInstanceLock: SingleInstanceLock?
    var lastPermissionNotificationSignature: String?
    var isStoppingRecording = false
    @MainActor lazy var liveTranscriptService: LiveTranscriptService = {
        let loggingService = environment.loggingService
        let logger: @Sendable (String, LoggingService.LogLevel) async -> Void = { message, level in
            await loggingService.log(message, level: level, component: "LiveTranscript")
        }
        return LiveTranscriptService(sttRunner: LiveSTTCLIRunner(logger: { message, level in
            await logger(message, level)
        }), logger: { message, level in
            await logger(message, level)
        })
    }()
    let todayFolderFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    lazy var notificationService = NotificationService(
        appSettingsStore: environment.appSettingsStore,
        inAppNotificationStore: environment.inAppNotificationStore,
        permissionService: environment.permissionService,
        loggingService: environment.loggingService,
        didDeliverInAppNotification: { [weak self] item in
            await self?.handleNewInAppNotification(item)
        }
    )
    lazy var recordingAdapter = RecordingAdapter(
        storageService: environment.storageService,
        appSettingsStore: environment.appSettingsStore,
        jobRepository: environment.jobRepository,
        loggingService: environment.loggingService,
        appStateDidChange: { [weak self] appState in
            await self?.apply(appState: appState)
        },
        notificationService: notificationService
    )
    lazy var pipelineOrchestrator = PipelineOrchestrator(
        jobRepository: environment.jobRepository,
        appSettingsStore: environment.appSettingsStore,
        transcriptionService: environment.transcriptionService,
        transcriptMergeService: environment.transcriptMergeService,
        summarizationService: environment.summarizationService,
        finalizationService: FinalizationService(
            storageService: environment.storageService,
            jobRepository: environment.jobRepository,
            loggingService: environment.loggingService,
            appStateDidChange: { [weak self] appState in
                await self?.apply(appState: appState)
            }
        ),
        loggingService: environment.loggingService,
        appStateDidChange: { [weak self] appState in
            await self?.apply(appState: appState)
        },
        notifyUser: { [weak self] category, title, body in
            await self?.deliverUserNotification(category: category, title: title, body: body)
        }
    )
    lazy var startupRecoveryService = StartupRecoveryService(
        jobRepository: environment.jobRepository,
        storageService: environment.storageService,
        loggingService: environment.loggingService,
        notifyInterruptedRecording: { [weak self] body in
            await self?.notificationService.publishInternal(
                category: NotificationService.Category.recordingInterrupted.rawValue,
                title: "AnyBrief",
                body: body
            )
        },
        resumeJob: { [weak self] session, stage in
            await self?.pipelineOrchestrator.run(session: session, startingAt: stage)
        }
    )
    lazy var localAPIService = LocalAPIService(
        appSettingsStore: environment.appSettingsStore,
        keychainStore: environment.keychainStore,
        jobRepository: environment.jobRepository,
        loggingService: environment.loggingService,
        permissionService: environment.permissionService,
        storageService: environment.storageService,
        recordingAdapter: recordingAdapter,
        pipelineOrchestrator: pipelineOrchestrator,
        appStateProvider: { [environment] in
            await MainActor.run {
                environment.appState
            }
        }
    )
    lazy var autopilotService = AutopilotService(
        appSettingsStore: environment.appSettingsStore,
        keychainStore: environment.keychainStore,
        jobRepository: environment.jobRepository,
        recordingAdapter: recordingAdapter,
        pipelineOrchestrator: pipelineOrchestrator,
        loggingService: environment.loggingService,
        notifyWindowMatch: { [notificationService] match in
            await notificationService.notify(
                category: .windowObserver,
                title: "AnyBrief",
                body: String(
                    format: String(localized: "Window matched: %@"),
                    match.recordingTitle
                )
            )
        }
    )

    deinit {
        if let workspaceSleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceSleepObserver)
        }
        if let reopenDashboardObserver {
            DistributedNotificationCenter.default().removeObserver(reopenDashboardObserver)
        }
    }

}
