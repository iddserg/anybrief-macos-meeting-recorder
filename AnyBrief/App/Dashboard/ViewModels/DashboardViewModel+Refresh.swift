
import Foundation

extension DashboardViewModel {
    func refresh() async {
        let startingRuntimeStateRevision = runtimeStateRevision
        async let jobs = loadActivities()
        async let meetings = loadRecentMeetings()
        async let schedule = loadTodayAutopilotEventsIfNeeded()
        // Only read settings (and Keychain) on the first refresh — afterwards
        // the user edits them directly through the form and saves explicitly.
        async let settings = hasLoadedSettings ? nil : loadSettings()
        async let logs = loadLogs()
        async let statistics = callStatisticsProvider()
        async let permissionRows = loadPermissions()
        async let runtimeState = appStateProvider()
        async let microphonePaused = microphonePausedProvider()
        async let recordingAutoStop = recordingAutoStopStateProvider()
        async let microphoneDevices = microphoneDevicesProvider()

        let loadedJobs = await jobs
        let loadedMeetings = await meetings
        let loadedSchedule = await schedule
        let loadedSettings = await settings
        let loadedLogs = await logs
        let loadedStatistics = await statistics
        let loadedPermissionRows = await permissionRows
        let loadedAppState = await runtimeState
        let loadedMicrophonePaused = await microphonePaused
        let loadedRecordingAutoStop = await recordingAutoStop
        let loadedMicrophoneDevices = await microphoneDevices
        let loadedSystemAudioApplications = loadedJobs.contains(where: \.isRecording)
            ? await systemAudioApplicationsProvider()
            : []

        let loadedPlan = await loadRecordingProcessingPlan(activities: loadedJobs, meetings: loadedMeetings)
        await MainActor.run {
            if runtimeStateRevision == startingRuntimeStateRevision {
                activities = loadedJobs
                if recordingProcessingPlan != loadedPlan { recordingProcessingPlan = loadedPlan }
                appState = loadedAppState
                let effectiveState: AppState = loadedJobs.contains(where: \.isRecording) ? .recording : loadedAppState
                if effectiveState != .recording {
                    isStoppingRecording = false
                }
                isMicrophonePaused = effectiveState == .recording ? loadedMicrophonePaused : false
                recordingAutoStopState = effectiveState == .recording ? loadedRecordingAutoStop : nil
                if effectiveState != .recording {
                    isDisablingRecordingAutoStop = false
                    recordingAutoStopError = nil
                }
            }
            if availableMicrophoneDevices != loadedMicrophoneDevices {
                availableMicrophoneDevices = loadedMicrophoneDevices
            }
            if availableSystemAudioApplications != loadedSystemAudioApplications {
                availableSystemAudioApplications = loadedSystemAudioApplications
            }
            updateLiveTranscriptRecordingState(effectiveAppState == .recording)
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
                calendarAutopilotPreEndNotificationSec = s.calendarAutopilotPreEndNotificationSec
                calendarAutopilotMuteMicrophone = s.calendarAutopilotMuteMicrophone
                calendarAutopilotParticipantCountMode = s.calendarAutopilotParticipantCountMode
                calendarAutopilotParticipantCount = s.calendarAutopilotParticipantCount
                calendarAutopilotPollIntervalSec = s.calendarAutopilotPollIntervalSec
                languageSelection = s.languageSelection
                appearanceSelection = s.appearanceSelection
                launchAtLogin = s.launchAtLogin
                hideDockIcon = s.hideDockIcon
                showNotifications = s.showNotifications
                disableSummaryFooter = s.disableSummaryFooter
                liveTranscriptEnabled = s.liveTranscriptEnabled
                postProcessingTabEnabled = s.postProcessingTabEnabled
                transcriptionProviderSelection = s.transcriptionProviderSelection
                transcriptionDiarizationEnabled = s.transcriptionDiarizationEnabled
                skipMicrophoneDiarization = s.skipMicrophoneDiarization
                transcriptionProviderEntries = s.transcriptionProviderEntries
                microphoneVoiceProcessingEnabled = s.microphoneVoiceProcessingEnabled
                microphoneDeviceUID = s.microphoneDeviceUID
                systemAudioApplicationBundleIdentifier = s.systemAudioApplicationBundleIdentifier
                savedSettingsSignature = currentSettingsSignature()
                hasLoadedSettings = true
            }
            activityLog = loadedLogs.activity
            errorLog = loadedLogs.errors
            callStatistics = loadedStatistics
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
