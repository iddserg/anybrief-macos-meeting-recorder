
import AppKit
import UniformTypeIdentifiers

extension DashboardViewModel {
    func selectMicrophoneDevice(_ uid: String) {
        let normalizedUID = uid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard microphoneDeviceUID != normalizedUID else {
            return
        }
        microphoneDeviceUID = normalizedUID

        Task {
            do {
                var settings = await appSettingsStore.load(using: loggingService)
                settings.recording.microphoneDeviceUID = normalizedUID.isEmpty ? nil : normalizedUID
                try await appSettingsStore.save(settings)
                try await applyMicrophoneDeviceAction(settings.recording.microphoneDeviceUID)
                await loggingService.log(
                    "Microphone selection updated: \(normalizedUID.isEmpty ? "system" : normalizedUID).",
                    level: .info,
                    component: "Dashboard"
                )
            } catch {
                await MainActor.run {
                    saveMessage = error.localizedDescription
                    saveMessageIsError = true
                }
            }
        }
    }

    func saveSettings() {
        guard savedSettingsSignature == nil || hasUnsavedSettings else {
            return
        }
        guard !isSavingSettings else {
            return
        }
        isSavingSettings = true
        saveMessage = nil
        saveMessageIsError = false

        Task {
            do {
                var settings = await appSettingsStore.load(using: loggingService)
                settings.summary.enabled = summaryEnabled
                settings.prompts.summary.speakerContextPromptID = speakerContextPromptID
                settings.llm.connections = try persistedSummaryProviderConfigurations()
                settings.prompts.items = promptItems
                settings.prompts.summary.promptID = summaryPromptID
                settings.prompts.summary.connectionIDs = summaryConnectionIDs
                settings.prompts.live.promptID = livePromptID
                settings.prompts.live.connectionID = liveConnectionID
                settings.prompts.transcriptCleanup.enabled = transcriptCleanupEnabled
                settings.prompts.transcriptCleanup.promptID = transcriptCleanupPromptID
                settings.prompts.transcriptCleanup.connectionIDs = transcriptCleanupConnectionIDs
                settings.postProcessing.enabled = postProcessingEnabled
                settings.postProcessing.rules = PostProcessingSettings.normalizedRules(postProcessingRules)
                let previousLaunchAtLogin = settings.application.launchAtLogin
                settings.application.launchAtLogin = launchAtLogin
                settings.application.hideDockIcon = hideDockIcon
                let shouldRequestNotifications = !settings.application.showNotifications && showNotifications
                settings.application.showNotifications = showNotifications
                settings.application.disableSummaryFooter = disableSummaryFooter
                settings.application.liveTranscriptEnabled = liveTranscriptEnabled
                settings.application.postProcessingTabEnabled = postProcessingTabEnabled
                settings.transcription.diarizationEnabled = transcriptionDiarizationEnabled
                settings.transcription.skipMicrophoneDiarization = skipMicrophoneDiarization
                settings.transcription.fluidAudioSTTConfig = FluidAudioSTTConfig(
                    speakersMode: fluidAudioSTTSpeakersMode,
                    speakersCount: fluidAudioSTTSpeakersCount,
                    threshold: fluidAudioSTTThreshold,
                    customVocabulary: fluidAudioSTTCustomVocabulary
                )
                settings.transcription.whisperCppConfig = WhisperCppConfig(
                    model: whisperCppModel,
                    language: whisperCppLanguage,
                    useGPU: whisperCppUseGPU,
                    speakersMode: whisperCppSpeakersMode,
                    speakersCount: whisperCppSpeakersCount,
                    threshold: whisperCppThreshold,
                    customVocabulary: whisperCppCustomVocabulary
                )
                settings.transcription.selectProvider(
                    TranscriptionProviderID(rawValue: transcriptionProviderSelection) ?? .fluidAudioSTT
                )
                let previousMicrophoneVoiceProcessingEnabled = settings.recording.microphoneVoiceProcessingEnabled
                let previousMicrophoneDeviceUID = settings.recording.microphoneDeviceUID
                settings.recording.microphoneVoiceProcessingEnabled = microphoneVoiceProcessingEnabled
                let trimmedMicrophoneDeviceUID = microphoneDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.recording.microphoneDeviceUID = trimmedMicrophoneDeviceUID.isEmpty
                    ? nil
                    : trimmedMicrophoneDeviceUID
                settings.automation.localHTTPAPISettings.enabled = localHTTPAPIEnabled
                settings.automation.localHTTPAPISettings.port = localHTTPAPIPort
                applyAutomationSourceSettings(to: &settings)
                settings.automation.calDAVSettings.enabled = calDAVEnabled
                settings.automation.calDAVSettings.name = calDAVCalendarID.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.automation.calDAVSettings.config.url = caldavURL.trimmingCharacters(in: .whitespacesAndNewlines)
                settings.automation.calDAVSettings.config.username = caldavUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                if !caldavPassword.isEmpty, !caldavPassword.hasPrefix("••") {
                    let ref = settings.automation.calDAVSettings.passwordKeychainRef ?? UUID().uuidString.lowercased()
                    try keychainStore.save(key: ref, value: caldavPassword)
                    settings.automation.calDAVSettings.passwordKeychainRef = ref
                }
                settings.automation.calendarAutopilotSettings.enabled = calendarAutopilotEnabled
                settings.automation.calendarAutopilotSettings.filter = calendarAutopilotFilter
                settings.automation.calendarAutopilotSettings.startLeadSec = calendarAutopilotStartLeadSec
                settings.automation.calendarAutopilotSettings.stopGraceSec = calendarAutopilotStopGraceSec
                settings.automation.calendarAutopilotSettings.preEndNotificationSec = calendarAutopilotPreEndNotificationSec
                settings.automation.calendarAutopilotSettings.muteMicrophone = calendarAutopilotMuteMicrophone
                settings.automation.calendarAutopilotSettings.participantCountMode = calendarAutopilotParticipantCountMode
                settings.automation.calendarAutopilotSettings.participantCount = calendarAutopilotParticipantCount
                settings.automation.calendarAutopilotSettings.pollIntervalSec = calendarAutopilotPollIntervalSec
                let previousLocale = settings.application.locale
                let previousEffectiveLanguage = LanguagePreferences.effectiveLanguageCode(for: previousLocale)
                let nextEffectiveLanguage = LanguagePreferences.effectiveLanguageCode(for: languageSelection)
                settings.application.locale = languageSelection
                let languagePreferenceDidChange = previousLocale != languageSelection
                let languageDidChange = previousEffectiveLanguage != nextEffectiveLanguage
                if languagePreferenceDidChange {
                    LanguagePreferences.apply(languageSelection)
                }

                let apiKeyReference = settings.automation.localHTTPAPISettings.apiKeyKeychainRef?.isEmpty == false
                    ? settings.automation.localHTTPAPISettings.apiKeyKeychainRef!
                    : UUID().uuidString.lowercased()
                let trimmedApiKey = localApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedApiKey.isEmpty {
                    try keychainStore.save(key: apiKeyReference, value: trimmedApiKey)
                    settings.automation.localHTTPAPISettings.apiKeyKeychainRef = apiKeyReference
                }

                if shouldRequestNotifications {
                    _ = await permissionService.request(.notifications)
                }

                if previousLaunchAtLogin != settings.application.launchAtLogin {
                    try launchAtLoginController.setEnabled(settings.application.launchAtLogin)
                }

                try await appSettingsStore.save(settings)
                await localAPISettingsDidChange()
                let hideDockIcon = settings.application.hideDockIcon
                await MainActor.run {
                    DockIconController.apply(hideDockIcon: hideDockIcon)
                }
                if previousMicrophoneVoiceProcessingEnabled != settings.recording.microphoneVoiceProcessingEnabled {
                    try await applyMicrophoneVoiceProcessingAction(settings.recording.microphoneVoiceProcessingEnabled)
                }
                if previousMicrophoneDeviceUID != settings.recording.microphoneDeviceUID {
                    try await applyMicrophoneDeviceAction(settings.recording.microphoneDeviceUID)
                }
                await loggingService.log(
                    "Dashboard settings updated.",
                    level: .info,
                    component: "Dashboard"
                )

                await MainActor.run {
                    isSavingSettings = false
                    isLiveLLMConfigured = !settings.liveLLMChain.isEmpty
                    if !settings.application.liveTranscriptEnabled {
                        liveTranscriptService.setVisible(false)
                        liveTranscriptService.setUserEnabled(false)
                    }
                    savedSettingsSignature = currentSettingsSignature()
                    hasLoadedSettings = false
                    lastCalendarScheduleRefreshAt = nil
                    clearCalendarScheduleBackoff()
                    if languageDidChange {
                        saveMessage = String(localized: "Saved. Restart AnyBrief to apply the language change.")
                        saveMessageIsError = false
                        AppRelaunchPrompt.offerForLanguageChange()
                    } else {
                        saveMessage = String(localized: "Saved.")
                        saveMessageIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    isSavingSettings = false
                    saveMessage = error.localizedDescription
                    saveMessageIsError = true
                }
            }
        }
    }

    func regenerateLocalApiKey() {
        Task {
            do {
                var settings = await appSettingsStore.load(using: loggingService)
                let apiKeyReference = settings.automation.localHTTPAPISettings.apiKeyKeychainRef?.isEmpty == false
                    ? settings.automation.localHTTPAPISettings.apiKeyKeychainRef!
                    : UUID().uuidString.lowercased()
                let newApiKey = Self.generateAPIKey()
                try keychainStore.save(key: apiKeyReference, value: newApiKey)
                settings.automation.localHTTPAPISettings.apiKeyKeychainRef = apiKeyReference
                try await appSettingsStore.save(settings)

                await loggingService.log(
                    "Local API key regenerated from Dashboard settings.",
                    level: .info,
                    component: "Settings"
                )
                await MainActor.run {
                    localApiKey = newApiKey
                    saveMessage = String(localized: "API key updated.")
                    saveMessageIsError = false
                }
            } catch {
                await MainActor.run {
                    saveMessage = error.localizedDescription
                    saveMessageIsError = true
                }
            }
        }
    }

    func currentSettingsSignature() -> String {
        let encodedProviders = (try? JSONEncoder().encode(normalizedSummaryProviderConfigurations()))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let encodedProviderKeys = (try? JSONEncoder().encode(summaryProviderAPIKeys))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let encodedPromptItems = (try? JSONEncoder().encode(promptItems))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let encodedPostProcessingRules = (try? JSONEncoder().encode(postProcessingRules))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let encodedWindowObserverSettings = (try? JSONEncoder().encode(
            automationSourceSettings.automation.windowObserverSettings.normalized()
        )).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let trimmedCaldavPassword = caldavPassword.trimmingCharacters(in: .whitespacesAndNewlines)

        let summaryParts: [String] = [
            String(summaryEnabled),
            speakerContextPromptID ?? "",
            encodedProviders,
            encodedProviderKeys,
            encodedPromptItems,
            summaryPromptID ?? "",
            summaryConnectionIDs.joined(separator: ","),
            livePromptID ?? "",
            liveConnectionID ?? "",
            String(transcriptCleanupEnabled),
            transcriptCleanupPromptID ?? "",
            transcriptCleanupConnectionIDs.joined(separator: ","),
        ]
        let integrationParts: [String] = [
            String(postProcessingEnabled),
            encodedPostProcessingRules,
            localApiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            String(localHTTPAPIEnabled),
            String(localHTTPAPIPort),
            encodedWindowObserverSettings,
        ]
        let calendarParts: [String] = [
            String(calDAVEnabled),
            calDAVCalendarID.trimmingCharacters(in: .whitespacesAndNewlines),
            caldavURL.trimmingCharacters(in: .whitespacesAndNewlines),
            caldavUsername.trimmingCharacters(in: .whitespacesAndNewlines),
            trimmedCaldavPassword.hasPrefix("••") ? "stored-password" : trimmedCaldavPassword,
            String(calendarAutopilotEnabled),
            calendarAutopilotFilter,
            String(calendarAutopilotStartLeadSec),
            String(calendarAutopilotStopGraceSec),
            String(calendarAutopilotPreEndNotificationSec),
            String(calendarAutopilotMuteMicrophone),
            calendarAutopilotParticipantCountMode,
            String(calendarAutopilotParticipantCount),
            String(calendarAutopilotPollIntervalSec),
        ]
        let applicationParts: [String] = [
            languageSelection,
            String(launchAtLogin),
            String(hideDockIcon),
            String(showNotifications),
            String(disableSummaryFooter),
            String(liveTranscriptEnabled),
            String(postProcessingTabEnabled),
            transcriptionProviderSelection,
            String(transcriptionDiarizationEnabled),
            String(skipMicrophoneDiarization),
            fluidAudioSTTCustomVocabulary.trimmingCharacters(in: .whitespacesAndNewlines),
            whisperCppCustomVocabulary.trimmingCharacters(in: .whitespacesAndNewlines),
            String(fluidAudioSTTThreshold),
            fluidAudioSTTSpeakersMode,
            String(fluidAudioSTTSpeakersCount),
            whisperCppModel,
            whisperCppLanguage,
            String(whisperCppUseGPU),
            String(whisperCppThreshold),
            whisperCppSpeakersMode,
            String(whisperCppSpeakersCount),
            String(microphoneVoiceProcessingEnabled),
            microphoneDeviceUID,
        ]
        return (summaryParts + integrationParts + calendarParts + applicationParts)
            .joined(separator: "\u{1F}")
    }

    func importSettingsConfig() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Load Config")
        panel.prompt = String(localized: "Load")
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                let data = try Data(contentsOf: url)
                var settings = try decodeAppSettingsConfig(from: data)
                let caldavPassword = settings.automation.calDAVSettings.config.password
                let localApiKey = settings.automation.localHTTPAPISettings.apiKey
                let summaryProviderApiKeys = Dictionary(
                    settings.llm.connections
                        .filter { $0.provider == .openAICompatible && !$0.openAIAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .map { ($0.id, $0.openAIAPIKey) },
                    uniquingKeysWith: { _, last in last }
                )
                settings.removeSecretReferences()
                try importSecret(caldavPassword, key: "caldav-password") {
                    settings.automation.calDAVSettings.passwordKeychainRef = $0
                }
                try importSecret(localApiKey, key: "local-api-key") {
                    settings.automation.localHTTPAPISettings.apiKeyKeychainRef = $0
                }
                for index in settings.llm.connections.indices
                    where settings.llm.connections[index].provider == .openAICompatible {
                    let id = settings.llm.connections[index].id
                    let keychainKey = "summary-provider-\(id)-api-key"
                    try importSecret(summaryProviderApiKeys[id] ?? "", key: keychainKey) {
                        settings.llm.connections[index].openAIAPIKeyKeychainRef = $0
                    }
                }
                let previousLaunchAtLogin = launchAtLogin
                let previousHideDockIcon = hideDockIcon
                try await appSettingsStore.save(settings)
                if previousLaunchAtLogin != settings.application.launchAtLogin {
                    try launchAtLoginController.setEnabled(settings.application.launchAtLogin)
                }
                if previousHideDockIcon != settings.application.hideDockIcon {
                    DockIconController.apply(hideDockIcon: settings.application.hideDockIcon)
                }
                await localAPISettingsDidChange()
                await MainActor.run {
                    hasLoadedSettings = false
                    configTransferMessage = String(localized: "Config loaded. Filled secrets were saved to Keychain.")
                    configTransferMessageIsError = false
                }
                await refresh()
            } catch {
                await MainActor.run {
                    configTransferMessage = String(
                        format: String(localized: "Failed to load config: %@"),
                        error.localizedDescription
                    )
                    configTransferMessageIsError = true
                }
            }
        }
    }

    func exportSettingsConfig() {
        let hadUnsavedSettingsBeforeExport = hasUnsavedSettings
        let panel = NSSavePanel()
        panel.title = String(localized: "Export Config")
        panel.prompt = String(localized: "Export")
        panel.nameFieldStringValue = "anybrief-config.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        Task {
            do {
                var settings = await appSettingsStore.load(using: loggingService)
                settings.removeSecretReferences()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(AppSettingsConfigFile(settings: settings))
                try data.write(to: url, options: .atomic)
                await MainActor.run {
                    configTransferMessage = String(localized: "Config exported with empty password/API key fields.")
                    configTransferMessageIsError = false
                    if !hadUnsavedSettingsBeforeExport {
                        savedSettingsSignature = currentSettingsSignature()
                        saveMessage = nil
                        saveMessageIsError = false
                    }
                }
            } catch {
                await MainActor.run {
                    configTransferMessage = String(
                        format: String(localized: "Failed to export config: %@"),
                        error.localizedDescription
                    )
                    configTransferMessageIsError = true
                }
            }
        }
    }

    func decodeAppSettingsConfig(from data: Data) throws -> AppSettings {
        let decoder = JSONDecoder()
        return try decoder.decode(AppSettingsConfigFile.self, from: data).appSettings()
    }

    func importSecret(_ value: String, key: String, assignReference: (String) -> Void) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return
        }
        try keychainStore.save(key: key, value: trimmedValue)
        assignReference(key)
    }

    var localAPIBaseURL: String { "http://127.0.0.1:\(localHTTPAPIPort)" }
    var apiDocsURL: URL {
        let isRussian: Bool
        switch languageSelection {
        case "ru":
            isRussian = true
        case "en":
            isRussian = false
        default:
            isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        }
        return URL(string: isRussian
            ? "https://anybrief.ru/api-contract.md"
            : "https://anybrief.pro/api-contract.md"
        )!
    }

    func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
    struct PromptsSnapshot {
        let items: [PromptItem]
        let summaryPromptID: String?
        let summaryConnectionIDs: [String]
        let livePromptID: String?
        let liveConnectionID: String?
        let isLiveLLMConfigured: Bool
        let livePromptText: String?
        let transcriptCleanupEnabled: Bool
        let transcriptCleanupPromptID: String?
        let transcriptCleanupConnectionIDs: [String]
    }

    func loadSettings() async -> (
        summaryEnabled: Bool,
        speakerContextPromptID: String?,
        summaryProviderEntries: [SummaryProviderConfiguration],
        summaryProviderAPIKeys: [String: String],
        promptsSnapshot: PromptsSnapshot,
        postProcessingEnabled: Bool,
        postProcessingRules: [PostProcessingRuleConfiguration],
        localApiKey: String,
        localHTTPAPIEnabled: Bool,
        localHTTPAPIPort: Int,
        automationSourceSettings: AppSettings,
        calDAVEnabled: Bool,
        calDAVCalendarID: String,
        caldavURL: String,
        caldavUsername: String,
        caldavPasswordMask: String,
        calendarAutopilotEnabled: Bool,
        calendarAutopilotFilter: String,
        calendarAutopilotStartLeadSec: Int,
        calendarAutopilotStopGraceSec: Int,
        calendarAutopilotPreEndNotificationSec: Int,
        calendarAutopilotMuteMicrophone: Bool,
        calendarAutopilotParticipantCountMode: String,
        calendarAutopilotParticipantCount: Int,
        calendarAutopilotPollIntervalSec: Int,
        languageSelection: String,
        launchAtLogin: Bool,
        hideDockIcon: Bool,
        showNotifications: Bool,
        disableSummaryFooter: Bool,
        liveTranscriptEnabled: Bool,
        postProcessingTabEnabled: Bool,
        transcriptionProviderSelection: String,
        transcriptionDiarizationEnabled: Bool,
        skipMicrophoneDiarization: Bool,
        fluidAudioSTTCustomVocabulary: String,
        whisperCppCustomVocabulary: String,
        fluidAudioSTTThreshold: Double,
        fluidAudioSTTSpeakersMode: String,
        fluidAudioSTTSpeakersCount: Int,
        whisperCppModel: String,
        whisperCppLanguage: String,
        whisperCppUseGPU: Bool,
        whisperCppThreshold: Double,
        whisperCppSpeakersMode: String,
        whisperCppSpeakersCount: Int,
        microphoneVoiceProcessingEnabled: Bool,
        microphoneDeviceUID: String
    ) {
        let settings = await appSettingsStore.load(using: loggingService)
        let localApiKey = settings.automation.localHTTPAPISettings.apiKeyKeychainRef.flatMap { keychainStore.load(key: $0) } ?? ""
        let summaryProviderEntries = normalizedLoadedSummaryProviderConfigurations(from: settings)
        let summaryProviderAPIKeys: [String: String] = Dictionary(
            summaryProviderEntries.compactMap { configuration -> (String, String)? in
                guard let ref = configuration.openAIAPIKeyKeychainRef,
                      let value = keychainStore.load(key: ref) else {
                    return nil
                }
                return (configuration.id, value)
            },
            uniquingKeysWith: { _, last in last }
        )
        let caldavPasswordMask = settings.automation.calDAVSettings.passwordKeychainRef.flatMap { keychainStore.load(key: $0) } == nil ? "" : "••••••••"
        let lang = settings.application.locale
        let transcriptionConfig = settings.transcription.fluidAudioSTTConfig
        let whisperConfig = settings.transcription.whisperCppConfig
        let promptsSnapshot = PromptsSnapshot(
            items: settings.prompts.items,
            summaryPromptID: settings.prompts.summary.promptID,
            summaryConnectionIDs: settings.prompts.summary.connectionIDs,
            livePromptID: settings.prompts.live.promptID,
            liveConnectionID: settings.prompts.live.connectionID,
            isLiveLLMConfigured: !settings.liveLLMChain.isEmpty,
            livePromptText: settings.prompts.livePrompt?.text,
            transcriptCleanupEnabled: settings.prompts.transcriptCleanup.enabled,
            transcriptCleanupPromptID: settings.prompts.transcriptCleanup.promptID,
            transcriptCleanupConnectionIDs: settings.prompts.transcriptCleanup.connectionIDs
        )
        return (
            settings.summary.enabled,
            settings.prompts.summary.speakerContextPromptID,
            summaryProviderEntries,
            summaryProviderAPIKeys,
            promptsSnapshot,
            settings.postProcessing.enabled,
            settings.postProcessing.rules,
            localApiKey,
            settings.automation.localHTTPAPISettings.enabled,
            settings.automation.localHTTPAPISettings.port,
            automationSettingsSnapshot(from: settings),
            settings.automation.calDAVSettings.enabled,
            settings.automation.calDAVSettings.name,
            settings.automation.calDAVSettings.config.url,
            settings.automation.calDAVSettings.config.username,
            caldavPasswordMask,
            settings.automation.calendarAutopilotSettings.enabled,
            settings.automation.calendarAutopilotSettings.filter,
            settings.automation.calendarAutopilotSettings.startLeadSec,
            settings.automation.calendarAutopilotSettings.stopGraceSec,
            settings.automation.calendarAutopilotSettings.preEndNotificationSec,
            settings.automation.calendarAutopilotSettings.muteMicrophone,
            settings.automation.calendarAutopilotSettings.participantCountMode,
            settings.automation.calendarAutopilotSettings.participantCount,
            settings.automation.calendarAutopilotSettings.pollIntervalSec,
            lang,
            settings.application.launchAtLogin,
            settings.application.hideDockIcon,
            settings.application.showNotifications,
            settings.application.disableSummaryFooter,
            settings.application.liveTranscriptEnabled,
            settings.application.postProcessingTabEnabled,
            settings.transcription.activeProviderConfiguration.provider.rawValue,
            settings.transcription.diarizationEnabled,
            settings.transcription.skipMicrophoneDiarization,
            transcriptionConfig.customVocabulary,
            whisperConfig.customVocabulary,
            transcriptionConfig.threshold,
            transcriptionConfig.speakersMode,
            transcriptionConfig.speakersCount,
            whisperConfig.model,
            whisperConfig.language,
            whisperConfig.useGPU,
            whisperConfig.threshold,
            whisperConfig.speakersMode,
            whisperConfig.speakersCount,
            settings.recording.microphoneVoiceProcessingEnabled,
            settings.recording.microphoneDeviceUID ?? ""
        )
    }

    func automationSettingsSnapshot(from settings: AppSettings) -> AppSettings {
        var snapshot = AppSettings.default
        snapshot.automation.windowObserverSettings = settings.automation.windowObserverSettings.normalized()
        return snapshot
    }

    func applyAutomationSourceSettings(to settings: inout AppSettings) {
        settings.automation.windowObserverSettings = automationSourceSettings.automation.windowObserverSettings.normalized()
    }

    func normalizedLoadedSummaryProviderConfigurations(from settings: AppSettings) -> [SummaryProviderConfiguration] {
        let loaded = settings.llm.connections.isEmpty
            ? [(try? summaryProviderRegistry.defaultConfiguration(for: .openAICompatible)) ?? SummaryProviderConfiguration(provider: .openAICompatible)]
            : settings.llm.connections
        return loaded.map(summaryProviderRegistry.normalize)
    }

    static func generateAPIKey() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}
