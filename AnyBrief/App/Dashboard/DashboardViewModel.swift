
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class DashboardViewModel: ObservableObject {
    struct CurrentActivity {
        let jobId: String
        let status: String
        let stage: String
        let startedAt: Date
        let duration: TimeInterval
        let detail: PipelineActivityDetail?
    }

    struct RecentMeeting: Equatable, Identifiable, Sendable {
        let id: String
        let title: String
        let timestamp: Date?
        let status: String
        let folderURL: URL
        let summaryURL: URL?
        let jobId: String?
        let needsFolderRename: Bool

        var canDelete: Bool {
            status != "recording" && status != "processing"
        }
    }

    struct PermissionRow: Identifiable {
        let id: String
        let title: String
        let detail: String
        let rawStatus: PermissionService.PermissionStatus
        let status: String
        let systemSettingsURL: URL
    }

    struct AutopilotScheduleEvent: Identifiable {
        let id: String
        let title: String
        let startAt: Date
        let endAt: Date
        let participantCount: Int
        let hasMeetingURL: Bool
        let meetingURL: URL?
    }

    @Published var currentActivity: CurrentActivity?
    @Published var recentMeetings: [RecentMeeting] = []
    @Published var todayAutopilotEvents: [AutopilotScheduleEvent] = []
    @Published var calendarScheduleError: String?
    @Published var summaryEnabled = false
    @Published var speakerContextPromptID: String?
    @Published var summaryProviderEntries: [SummaryProviderConfiguration] = []
    @Published var summaryProviderAPIKeys: [String: String] = [:]
    @Published var selectedSummaryProviderConfigurationID: String?
    @Published var promptItems: [PromptItem] = []
    @Published var selectedPromptItemID: String?
    @Published var summaryPromptID: String?
    @Published var summaryConnectionIDs: [String] = []
    @Published var livePromptID: String?
    @Published var liveConnectionID: String?
    @Published var isLiveLLMConfigured = false
    @Published var transcriptCleanupEnabled = false
    @Published var transcriptCleanupPromptID: String?
    @Published var transcriptCleanupConnectionIDs: [String] = []
    @Published var postProcessingEnabled = true
    @Published var postProcessingRules: [PostProcessingRuleConfiguration] = []
    @Published var selectedPostProcessingRuleID: String?
    @Published var postProcessingMessage: String?
    @Published var postProcessingMessageIsError = false
    @Published var exportingMeetingIds: Set<String> = []
    @Published var checkingSummaryProviderIDs: Set<String> = []
    @Published var summaryProviderDiagnosticResults: [String: SummaryProviderDiagnosticResult] = [:]
    @Published var localApiKey = ""
    @Published var localHTTPAPIEnabled = false
    @Published var localHTTPAPIPort = 47823
    @Published var automationSourceSettings = AppSettings.default
    @Published var calDAVEnabled = false
    @Published var calDAVCalendarID = ""
    @Published var caldavURL = ""
    @Published var caldavUsername = ""
    @Published var caldavPassword = ""
    @Published var discoveredCalendars: [CalDAVCalendarService.CalendarInfo] = []
    @Published var isTestingCalendarSettings = false
    @Published var isLoadingCalendars = false
    @Published var calendarSettingsMessage: String?
    @Published var calendarSettingsMessageIsError = false
    @Published var verifiedCalendarConnectionSignature: String?
    @Published var calendarAutopilotEnabled = false
    @Published var calendarAutopilotFilter = "meeting_url_or_multiparticipant"
    @Published var calendarAutopilotStartLeadSec = 30
    @Published var calendarAutopilotStopGraceSec = 60
    @Published var calendarAutopilotPreEndNotificationSec = 120
    @Published var calendarAutopilotMuteMicrophone = false
    @Published var calendarAutopilotParticipantCountMode = "calendar"
    @Published var calendarAutopilotParticipantCount = 2
    @Published var calendarAutopilotPollIntervalSec = 30
    @Published var languageSelection = "system"
    @Published var launchAtLogin = false
    @Published var hideDockIcon = false
    @Published var showNotifications = true
    @Published var disableSummaryFooter = false
    @Published var liveTranscriptEnabled = false
    @Published var postProcessingTabEnabled = true
    @Published var transcriptionProviderSelection = TranscriptionProviderID.fluidAudioSTT.rawValue
    @Published var transcriptionDiarizationEnabled = true
    @Published var skipMicrophoneDiarization = true
    @Published var fluidAudioSTTCustomVocabulary = ""
    @Published var whisperCppCustomVocabulary = ""
    @Published var fluidAudioSTTThreshold = 0.65
    @Published var fluidAudioSTTSpeakersMode = "auto"
    @Published var fluidAudioSTTSpeakersCount = 2
    @Published var whisperCppModel = "small"
    @Published var whisperCppLanguage = "auto"
    @Published var whisperCppUseGPU = true
    @Published var whisperCppThreshold = 0.65
    @Published var whisperCppSpeakersMode = "auto"
    @Published var whisperCppSpeakersCount = 2
    @Published var transcriptionModelStatus = FluidAudioSTTModelService().status()
    @Published var isDownloadingTranscriptionModels = false
    @Published var transcriptionModelMessage: String?
    @Published var transcriptionModelMessageIsError = false
    @Published var transcriptionTechnologyChecks: [TranscriptionTechnologyCheck] = []
    @Published var transcriptionTechnologyProviderTitle = ""
    @Published var transcriptionTechnologyMessage: String?
    @Published var transcriptionTechnologyMessageIsError = false
    @Published var isCheckingTranscriptionTechnologies = false
    @Published var microphoneVoiceProcessingEnabled = true
    @Published var microphoneDeviceUID = ""
    @Published var availableMicrophoneDevices: [MicrophoneDevice] = []
    @Published var activityLog = ""
    @Published var errorLog = ""
    @Published var permissions: [PermissionRow] = []
    @Published var isRecheckingPermissions = false
    @Published var lastPermissionsRecheckAt: Date?
    @Published var lastRefreshAt: Date?
    @Published var appState: AppState = .idle
    @Published var isMicrophonePaused = false
    let audioLevelStore = AudioLevelStore()
    @Published var isSavingSettings = false
    @Published var saveMessage: String?
    @Published var saveMessageIsError = false
    @Published var configTransferMessage: String?
    @Published var configTransferMessageIsError = false
    var savedSettingsSignature: String?

    var calendarConnectionFieldsReady: Bool {
        !caldavURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !caldavUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !caldavPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var calendarConnectionVerified: Bool {
        guard calendarConnectionFieldsReady else {
            return false
        }
        return verifiedCalendarConnectionSignature == calendarConnectionSignature()
    }

    var calendarSelectionReady: Bool {
        !calDAVCalendarID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var calendarSetupMessage: String? {
        guard calDAVEnabled else {
            return nil
        }
        if !calendarConnectionFieldsReady {
            return String(localized: "Enter CalDAV URL, username, and password first.")
        }
        if !calendarConnectionVerified {
            return String(localized: "Check CalDAV connection before saving.")
        }
        if !calendarSelectionReady {
            return String(localized: "Select a calendar before saving.")
        }
        return nil
    }

    var hasUnsavedSettings: Bool {
        guard let savedSettingsSignature else {
            return false
        }
        return currentSettingsSignature() != savedSettingsSignature
    }

    var canSaveSettings: Bool {
        guard !isSavingSettings else {
            return false
        }
        return hasUnsavedSettings
    }
    @Published var resummarizingMeetingIds: Set<String> = []
    @Published var reprocessingMeetingIds: Set<String> = []
    @Published var summaryActionMessage: String?
    @Published var summaryActionMessageIsError = false
    @Published var isCheckingForUpdates = false
    @Published var updateCheckMessage: String?
    @Published var updateCheckMessageIsError = false
    @Published var availableUpdate: AppUpdateManifest?
    @Published var isStoppingRecording = false
    @Published var liveTranscriptSnapshot = LiveTranscriptSnapshot()
    @Published var liveTranscriptPrompt = String(
        localized: "Extract the key points, decisions, risks, and action items from this live transcript. Keep the output concise and update-friendly."
    )
    @Published var liveTranscriptLLMOutput = ""
    @Published var liveTranscriptAutoProcessEnabled = false
    @Published var isProcessingLiveTranscriptPrompt = false
    @Published var liveTranscriptPromptMessage: String?
    @Published var liveTranscriptPromptMessageIsError = false

    var effectiveAppState: AppState {
        if currentActivity?.isRecording == true {
            return .recording
        }
        return appState
    }

    var canStartRecording: Bool {
        !needsPermissionSetup && effectiveAppState != .recording
    }

    var missingRequiredPermissions: [PermissionRow] {
        permissions.filter { permission in
            (permission.id == "microphone" || permission.id == "screenRecording")
                && permission.rawStatus != .granted
        }
    }

    var needsPermissionSetup: Bool {
        (effectiveAppState == .needsPermissions
            || (effectiveAppState == .error && currentActivity?.jobId == "runtime"))
            && !missingRequiredPermissions.isEmpty
    }

    let appStateProvider: @Sendable () async -> AppState
    let pipelineActivityProvider: @Sendable (String) async -> PipelineActivityDetail?
    let microphonePausedProvider: @Sendable () async -> Bool
    let audioLevelsProvider: @Sendable () async -> AudioLevelSnapshot
    let microphoneDevicesProvider: @Sendable () async -> [MicrophoneDevice]
    let startRecordingAction: @MainActor () -> Void
    let stopRecordingAction: @MainActor () -> Void
    let forceStopRecordingAction: @MainActor () -> Void
    let toggleMicrophonePauseAction: @MainActor () -> Void
    let applyMicrophoneVoiceProcessingAction: @Sendable (Bool) async throws -> Void
    let applyMicrophoneDeviceAction: @Sendable (String?) async throws -> Void
    let jobRepository: JobRepositoryProtocol
    let appSettingsStore: AppSettingsStoreProtocol
    let keychainStore: SecretStoreProtocol
    let permissionService: PermissionService
    let storageService: StorageServiceProtocol
    let llmService: LLMService
    let summarizationService: SummarizationService
    let postProcessingService: PostProcessingService
    let summaryProviderDiagnosticsService: SummaryProviderDiagnosticsService
    let summaryProviderRegistry: SummaryProviderRegistry
    let automationSourceRegistry: AutomationSourceRegistry
    let transcriptionProviderRegistry: TranscriptionProviderRegistry
    let loggingService: LoggingService
    let launchAtLoginController: LaunchAtLoginControlling
    let localAPISettingsDidChange: @Sendable () async -> Void
    let repeatMeetingProcessingAction: @Sendable (URL, String?, String, MeetingReprocessingMode) async throws -> Void
    let calendarService: CalDAVCalendarService
    let transcriptionModelService: FluidAudioSTTModelService
    let whisperCppModelService: WhisperCppModelService
    let appUpdateService: AppUpdateService
    let liveTranscriptService: LiveTranscriptService
    let workspace: NSWorkspace
    let fileManager: FileManager
    var refreshTask: Task<Void, Never>?
    var audioLevelTask: Task<Void, Never>?
    var liveTranscriptPromptTask: Task<Void, Never>?
    var liveTranscriptAutoRerunPending = false
    var hasPrefilledLiveTranscriptPrompt = false
    var hasLoadedSettings = false
    var lastCalendarScheduleRefreshAt: Date?
    var calendarScheduleBackoffUntil: Date?
    var lastCalendarScheduleBackoffErrorDescription: String?
    var lastCalendarScheduleBackoffSettingsSignature: String?
    var didAutoCheckForUpdates = false

    init(
        appStateProvider: @escaping @Sendable () async -> AppState,
        pipelineActivityProvider: @escaping @Sendable (String) async -> PipelineActivityDetail? = { _ in nil },
        microphonePausedProvider: @escaping @Sendable () async -> Bool = { false },
        audioLevelsProvider: @escaping @Sendable () async -> AudioLevelSnapshot = { AudioLevelSnapshot() },
        microphoneDevicesProvider: @escaping @Sendable () async -> [MicrophoneDevice] = {
            MicrophoneDeviceCatalog.availableDevices()
        },
        jobRepository: JobRepositoryProtocol,
        appSettingsStore: AppSettingsStoreProtocol,
        keychainStore: SecretStoreProtocol,
        permissionService: PermissionService,
        storageService: StorageServiceProtocol,
        llmService: LLMService? = nil,
        summarizationService: SummarizationService? = nil,
        postProcessingService: PostProcessingService? = nil,
        loggingService: LoggingService,
        startRecordingAction: @escaping @MainActor () -> Void,
        stopRecordingAction: @escaping @MainActor () -> Void,
        forceStopRecordingAction: @escaping @MainActor () -> Void,
        toggleMicrophonePauseAction: @escaping @MainActor () -> Void = {},
        applyMicrophoneVoiceProcessingAction: @escaping @Sendable (Bool) async throws -> Void = { _ in },
        applyMicrophoneDeviceAction: @escaping @Sendable (String?) async throws -> Void = { _ in },
        launchAtLoginController: LaunchAtLoginControlling = LaunchAtLoginController(),
        localAPISettingsDidChange: @escaping @Sendable () async -> Void = {},
        repeatMeetingProcessingAction: @escaping @Sendable (URL, String?, String, MeetingReprocessingMode) async throws -> Void = { _, _, _, _ in
            throw TranscriptionError(message: "Meeting reprocessing is unavailable.")
        },
        calendarService: CalDAVCalendarService = CalDAVCalendarService(),
        summaryProviderRegistry: SummaryProviderRegistry = .default,
        automationSourceRegistry: AutomationSourceRegistry = .default,
        transcriptionProviderRegistry: TranscriptionProviderRegistry = .default,
        transcriptionModelService: FluidAudioSTTModelService = FluidAudioSTTModelService(),
        whisperCppModelService: WhisperCppModelService = WhisperCppModelService(),
        appUpdateService: AppUpdateService = AppUpdateService(),
        liveTranscriptService: LiveTranscriptService? = nil,
        workspace: NSWorkspace = .shared,
        fileManager: FileManager = .default
    ) {
        self.appStateProvider = appStateProvider
        self.pipelineActivityProvider = pipelineActivityProvider
        self.microphonePausedProvider = microphonePausedProvider
        self.audioLevelsProvider = audioLevelsProvider
        self.microphoneDevicesProvider = microphoneDevicesProvider
        self.startRecordingAction = startRecordingAction
        self.stopRecordingAction = stopRecordingAction
        self.forceStopRecordingAction = forceStopRecordingAction
        self.toggleMicrophonePauseAction = toggleMicrophonePauseAction
        self.applyMicrophoneVoiceProcessingAction = applyMicrophoneVoiceProcessingAction
        self.applyMicrophoneDeviceAction = applyMicrophoneDeviceAction
        self.jobRepository = jobRepository
        self.appSettingsStore = appSettingsStore
        self.keychainStore = keychainStore
        self.permissionService = permissionService
        self.storageService = storageService
        self.loggingService = loggingService
        let resolvedLLMService = llmService ?? LLMService(keychainStore: keychainStore, logger: { message, level in
            await loggingService.log(message, level: level, component: "LLM")
        })
        self.llmService = resolvedLLMService
        self.summarizationService = summarizationService ?? SummarizationService(keychainStore: keychainStore, llmService: resolvedLLMService, logger: { message, level in
            await loggingService.log(message, level: level, component: "Summary")
        })
        self.postProcessingService = postProcessingService ?? PostProcessingService(logger: { message, level in
            await loggingService.log(message, level: level, component: "PostProcessing")
        })
        self.summaryProviderDiagnosticsService = SummaryProviderDiagnosticsService(logger: { message, level in
            await loggingService.log(message, level: level, component: "Summary")
        })
        self.summaryProviderRegistry = summaryProviderRegistry
        self.automationSourceRegistry = automationSourceRegistry
        self.transcriptionProviderRegistry = transcriptionProviderRegistry
        self.launchAtLoginController = launchAtLoginController
        self.localAPISettingsDidChange = localAPISettingsDidChange
        self.repeatMeetingProcessingAction = repeatMeetingProcessingAction
        self.calendarService = calendarService
        self.transcriptionModelService = transcriptionModelService
        self.whisperCppModelService = whisperCppModelService
        self.appUpdateService = appUpdateService
        self.liveTranscriptService = liveTranscriptService ?? LiveTranscriptService()
        self.workspace = workspace
        self.fileManager = fileManager
        self.liveTranscriptService.onSnapshotChanged = { [weak self] snapshot in
            self?.liveTranscriptSnapshot = snapshot
        }
    }

    func startRefreshing() {
        guard refreshTask == nil else {
            return
        }

        if !didAutoCheckForUpdates {
            didAutoCheckForUpdates = true
            checkForUpdates(userInitiated: false)
        }
        refreshTranscriptionModelStatus()

        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refresh()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled {
                    break
                }
                await self.refresh()
            }
        }

        audioLevelTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let levels = await audioLevelsProvider()
                await MainActor.run {
                    self.audioLevelStore.update(levels)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    func stopRefreshing() {
        refreshTask?.cancel()
        refreshTask = nil
        audioLevelTask?.cancel()
        audioLevelTask = nil
        audioLevelStore.reset()
        liveTranscriptService.stop()
        liveTranscriptPromptTask?.cancel()
        liveTranscriptPromptTask = nil
        isProcessingLiveTranscriptPrompt = false
    }

    func startRecording() {
        startRecordingAction()
    }

    func stopRecording() {
        guard effectiveAppState == .recording, !isStoppingRecording else {
            return
        }
        isStoppingRecording = true
        stopRecordingAction()
    }

    func forceStopRecording() {
        isStoppingRecording = true
        forceStopRecordingAction()
    }

    func toggleMicrophonePause() {
        toggleMicrophonePauseAction()
    }
}
