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
                audioLevelsProvider: { [recordingAdapter] in
                    await recordingAdapter.audioLevels()
                },
                microphoneDevicesProvider: {
                    MicrophoneDeviceCatalog.availableDevices()
                },
                jobRepository: environment.jobRepository,
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
                stopRecordingAction: { [weak self] in
                    self?.stopRecording()
                },
                forceStopRecordingAction: { [weak self] in
                    self?.forceStopCurrentRecording()
                },
                toggleMicrophonePauseAction: { [weak self] in
                    self?.toggleMicrophonePause()
                },
                applyMicrophoneVoiceProcessingAction: { [recordingAdapter] enabled in
                    try await recordingAdapter.setMicrophoneVoiceProcessingEnabled(enabled)
                },
                applyMicrophoneDeviceAction: { [recordingAdapter] uid in
                    try await recordingAdapter.setMicrophoneDeviceUID(uid)
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
