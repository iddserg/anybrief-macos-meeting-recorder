import AppKit
import Foundation

extension AppDelegate {
    @MainActor
    func presentDashboard() {
        guard dashboardWindowController == nil else {
            dashboardWindowController?.show()
            return
        }

        let controller = DashboardWindowController(
            viewModel: DashboardViewModel(
                appStateProvider: { [environment] in
                    await MainActor.run {
                        environment.appState
                    }
                },
                pipelineActivityProvider: { [pipelineOrchestrator] jobId in
                    await pipelineOrchestrator.activityDetail(for: jobId)
                },
                microphonePausedProvider: { [recordingAdapter] in
                    await recordingAdapter.isMicrophonePaused()
                },
                recordingAutoStopStateProvider: { [recordingAdapter] in
                    guard let session = await recordingAdapter.currentSession() else {
                        return nil
                    }
                    return DashboardViewModel.RecordingAutoStopState(
                        isCalendarRecording: session.source == "calendar",
                        isDisabled: session.autoStopDisabled,
                        autoStopAt: session.autoStopAt
                    )
                },
                audioLevelsProvider: { [recordingAdapter] in
                    await recordingAdapter.audioLevels()
                },
                microphoneDevicesProvider: {
                    MicrophoneDeviceCatalog.availableDevices()
                },
                systemAudioApplicationsProvider: {
                    await SystemAudioApplicationCatalog.availableApplications()
                },
                jobRepository: environment.jobRepository,
                callStatisticsProvider: { [environment] in
                    await environment.callStatisticsService.dailyStatistics()
                },
                appSettingsStore: environment.appSettingsStore,
                keychainStore: environment.keychainStore,
                permissionService: environment.permissionService,
                storageService: environment.storageService,
                llmService: environment.llmService,
                summarizationService: environment.summarizationService,
                loggingService: environment.loggingService,
                startRecordingAction: { [weak self] in
                    self?.startRecording()
                },
                startCalendarRecordingAction: { [weak self] event in
                    guard let self else { return }
                    do {
                        _ = try await self.recordingAdapter.startManually(calendarEvent: event)
                    } catch {
                        await self.handleRecordingActionError(error, action: "start")
                        throw error
                    }
                },
                stopRecordingAction: { [weak self] in
                    self?.stopRecording()
                },
                forceStopRecordingAction: { [weak self] in
                    self?.forceStopCurrentRecording()
                },
                applyMicrophonePauseAction: { [weak self] paused in
                    guard let self else { throw CancellationError() }
                    _ = try await self.recordingAdapter.setMicrophonePaused(paused)
                    let appState = await MainActor.run {
                        self.environment.appState
                    }
                    await self.apply(appState: appState)
                },
                disableRecordingAutoStopAction: { [recordingAdapter] in
                    _ = try await recordingAdapter.disableAutoStop()
                },
                applyMicrophoneVoiceProcessingAction: { [recordingAdapter] enabled in
                    try await recordingAdapter.setMicrophoneVoiceProcessingEnabled(enabled)
                },
                applyMicrophoneDeviceAction: { [recordingAdapter] uid in
                    try await recordingAdapter.setMicrophoneDeviceUID(uid)
                },
                applySystemAudioApplicationAction: { [recordingAdapter] bundleIdentifier in
                    try await recordingAdapter.setSystemAudioApplicationBundleIdentifier(bundleIdentifier)
                },
                launchAtLoginController: launchAtLoginController,
                localAPISettingsDidChange: { [localAPIService] in
                    await localAPIService.start()
                },
                repeatMeetingProcessingAction: { [weak self] folderURL, jobId, title, mode in
                    guard let self else {
                        throw CancellationError()
                    }
                    try await self.pipelineOrchestrator.repeatProcessing(
                        meetingFolderURL: folderURL,
                        jobId: jobId,
                        title: title,
                        mode: mode
                    )
                },
                importMeetingAction: { [weak self] file, title, date in
                    guard let self else { throw CancellationError() }
                    let session = try await self.meetingImportService.prepare(file: file, title: title, date: date)
                    await self.environment.jobRepository.upsert(Job(
                        id: session.jobId, meetingId: session.jobId, status: "processing", stage: .recorded,
                        source: session.source, createdAt: date, updatedAt: Date()
                    ))
                    await self.pipelineOrchestrator.enqueue(session: session)
                    return session.jobId
                },
                updateNotificationService: notificationService,
                liveTranscriptService: liveTranscriptService
            ),
            notificationStore: environment.inAppNotificationStore,
            onClose: { [weak self] in
                self?.dashboardWindowController = nil
            }
        )
        dashboardWindowController = controller
        controller.show()
    }
}
