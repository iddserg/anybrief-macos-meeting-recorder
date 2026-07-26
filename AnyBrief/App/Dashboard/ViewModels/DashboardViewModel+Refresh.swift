
import Foundation

extension DashboardViewModel {
    func refresh() async {
        async let jobs = loadCurrentActivity()
        async let meetings = loadRecentMeetings()
        async let schedule = loadTodayAutopilotEventsIfNeeded()
        // Only read settings (and Keychain) on the first refresh — afterwards
        // the user edits them directly through the form and saves explicitly.
        async let settings = hasLoadedSettings ? nil : loadSettings()
        async let logs = loadLogs()
        async let permissionRows = loadPermissions()
        async let runtimeState = appStateProvider()
        async let microphonePaused = microphonePausedProvider()
        async let microphoneDevices = microphoneDevicesProvider()

        let loadedJobs = await jobs
        let loadedMeetings = await meetings
        let loadedSchedule = await schedule
        let loadedSettings = await settings
        let loadedLogs = await logs
        let loadedPermissionRows = await permissionRows
        let loadedAppState = await runtimeState
        let loadedMicrophonePaused = await microphonePaused
        let loadedMicrophoneDevices = await microphoneDevices

        await MainActor.run {
            currentActivity = loadedJobs
            appState = loadedAppState
            let effectiveState: AppState = loadedJobs?.isRecording == true ? .recording : loadedAppState
            if effectiveState != .recording {
                isStoppingRecording = false
            }
            isMicrophonePaused = effectiveState == .recording ? loadedMicrophonePaused : false
            if availableMicrophoneDevices != loadedMicrophoneDevices {
                availableMicrophoneDevices = loadedMicrophoneDevices
            }
            updateLiveTranscriptRecordingState(effectiveState == .recording)
            if recentMeetings != loadedMeetings {
                recentMeetings = loadedMeetings
            }
            todayAutopilotEvents = loadedSchedule.events
            calendarScheduleError = loadedSchedule.error
            if let s = loadedSettings, !hasLoadedSettings {
                summaryEnabled = s.summaryEnabled
                speakerContextPromptID = s.speakerContextPromptID
                summaryProviderEntries = s.summaryProviderEntries
                summaryProviderAPIKeys = s.summaryProviderAPIKeys
                selectedSummaryProviderConfigurationID = summaryProviderEntries.first?.id
                promptItems = s.promptsSnapshot.items
                selectedPromptItemID = promptItems.first?.id
                summaryPromptID = s.promptsSnapshot.summaryPromptID
                summaryConnectionIDs = s.promptsSnapshot.summaryConnectionIDs
                livePromptID = s.promptsSnapshot.livePromptID
                liveConnectionID = s.promptsSnapshot.liveConnectionID
                isLiveLLMConfigured = s.promptsSnapshot.isLiveLLMConfigured
                transcriptCleanupEnabled = s.promptsSnapshot.transcriptCleanupEnabled
                transcriptCleanupPromptID = s.promptsSnapshot.transcriptCleanupPromptID
                transcriptCleanupConnectionIDs = s.promptsSnapshot.transcriptCleanupConnectionIDs
                if !hasPrefilledLiveTranscriptPrompt,
                   let livePromptText = s.promptsSnapshot.livePromptText,
                   !livePromptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    liveTranscriptPrompt = livePromptText
                    hasPrefilledLiveTranscriptPrompt = true
                }
                postProcessingEnabled = s.postProcessingEnabled
                postProcessingRules = s.postProcessingRules
                selectedPostProcessingRuleID = postProcessingRules.first?.id
                localApiKey = s.localApiKey
                localHTTPAPIEnabled = s.localHTTPAPIEnabled
                localHTTPAPIPort = s.localHTTPAPIPort
                automationSourceSettings = s.automationSourceSettings
                calDAVEnabled = s.calDAVEnabled
                calDAVCalendarID = s.calDAVCalendarID
                caldavURL = s.caldavURL
                caldavUsername = s.caldavUsername
                caldavPassword = s.caldavPasswordMask
                verifiedCalendarConnectionSignature = calendarConnectionFieldsReady && calendarSelectionReady
                    ? calendarConnectionSignature()
                    : nil
                calendarAutopilotEnabled = s.calendarAutopilotEnabled
                calendarAutopilotFilter = s.calendarAutopilotFilter
                calendarAutopilotStartLeadSec = s.calendarAutopilotStartLeadSec
                calendarAutopilotStopGraceSec = s.calendarAutopilotStopGraceSec
                calendarAutopilotPreEndNotificationSec = s.calendarAutopilotPreEndNotificationSec
                calendarAutopilotMuteMicrophone = s.calendarAutopilotMuteMicrophone
                calendarAutopilotParticipantCountMode = s.calendarAutopilotParticipantCountMode
                calendarAutopilotParticipantCount = s.calendarAutopilotParticipantCount
                calendarAutopilotPollIntervalSec = s.calendarAutopilotPollIntervalSec
                languageSelection = s.languageSelection
                launchAtLogin = s.launchAtLogin
                hideDockIcon = s.hideDockIcon
                showNotifications = s.showNotifications
                disableSummaryFooter = s.disableSummaryFooter
                liveTranscriptEnabled = s.liveTranscriptEnabled
                postProcessingTabEnabled = s.postProcessingTabEnabled
                transcriptionProviderSelection = s.transcriptionProviderSelection
                transcriptionDiarizationEnabled = s.transcriptionDiarizationEnabled
                skipMicrophoneDiarization = s.skipMicrophoneDiarization
                fluidAudioSTTCustomVocabulary = s.fluidAudioSTTCustomVocabulary
                whisperCppCustomVocabulary = s.whisperCppCustomVocabulary
                if !s.liveTranscriptEnabled {
                    liveTranscriptService.setVisible(false)
                    liveTranscriptService.setUserEnabled(false)
                }
                fluidAudioSTTThreshold = s.fluidAudioSTTThreshold
                fluidAudioSTTSpeakersMode = s.fluidAudioSTTSpeakersMode
                fluidAudioSTTSpeakersCount = s.fluidAudioSTTSpeakersCount
                whisperCppModel = s.whisperCppModel
                whisperCppLanguage = s.whisperCppLanguage
                whisperCppUseGPU = s.whisperCppUseGPU
                whisperCppThreshold = s.whisperCppThreshold
                whisperCppSpeakersMode = s.whisperCppSpeakersMode
                whisperCppSpeakersCount = s.whisperCppSpeakersCount
                microphoneVoiceProcessingEnabled = s.microphoneVoiceProcessingEnabled
                microphoneDeviceUID = s.microphoneDeviceUID
                savedSettingsSignature = currentSettingsSignature()
                hasLoadedSettings = true
            }
            activityLog = loadedLogs.activity
            errorLog = loadedLogs.errors
            permissions = loadedPermissionRows
            lastRefreshAt = Date()
        }
    }

    func refreshPermissions() async {
        let rows = await loadPermissions()
        await MainActor.run {
            permissions = rows
            lastRefreshAt = Date()
        }
    }
}
