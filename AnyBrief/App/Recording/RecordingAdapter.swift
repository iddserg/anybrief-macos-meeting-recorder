import AVFoundation
import Foundation

/// Starts/stops the in-process recorder and applies the app/job transitions required by the state machine.
actor RecordingAdapter {
    private let storageService: StorageServiceProtocol
    private let appSettingsStore: AppSettingsStoreProtocol
    private let jobRepository: JobRepositoryProtocol
    private let loggingService: LoggingService
    private let appStateDidChange: @Sendable (AppState) async -> Void
    private let notificationService: NotificationService?
    private let recorderFactory: (MeetingPaths, AppSettings) throws -> AudioRecording
    private let watchdogPollInterval: TimeInterval
    private let watchdogHungInterval: TimeInterval
    private let sleep: @Sendable (UInt64) async -> Void

    private(set) var activeSession: RecordingSession?
    private var activeRecorder: AudioRecording?
    private var isStarting = false
    private var recorderWatchdogTask: Task<Void, Never>?
    private var preEndNotificationTask: Task<Void, Never>?
    private let minimumComparableTrackDuration: TimeInterval = 120
    private let minimumMicToSystemDurationRatio = 0.8
    private let lowSystemLevelThreshold = 0.01
    private let lowSystemLevelWarningPolls = 3
    private let microphoneExplainsSystemQuietRatio = 0.50
    private let systemAudioUnexpectedRestartLimit = 3
    private let systemAudioUnexpectedRestartWindow: TimeInterval = 300
    private var systemAudioUnexpectedRestartAttempts: [Date] = []
    private var didNotifySystemAudioFailure = false

    init(
        storageService: StorageServiceProtocol,
        appSettingsStore: AppSettingsStoreProtocol = AppSettingsStore(),
        jobRepository: JobRepositoryProtocol,
        loggingService: LoggingService,
        appStateDidChange: @escaping @Sendable (AppState) async -> Void,
        notificationService: NotificationService? = nil,
        recorderURLResolver: (() throws -> URL)? = nil,
        recorderFactory: ((MeetingPaths) throws -> AudioRecording)? = nil,
        fileManager: FileManager = .default,
        watchdogPollInterval: TimeInterval = 60,
        watchdogHungInterval: TimeInterval = 300,
        watchdogKillGracePeriod: TimeInterval = 5,
        sleep: @escaping @Sendable (UInt64) async -> Void = { value in
            try? await Task.sleep(nanoseconds: value)
        }
    ) {
        self.storageService = storageService
        self.appSettingsStore = appSettingsStore
        self.jobRepository = jobRepository
        self.loggingService = loggingService
        self.appStateDidChange = appStateDidChange
        self.notificationService = notificationService
        self.recorderFactory = { paths, settings in
            if let recorderFactory {
                return try recorderFactory(paths)
            }

            if let recorderURLResolver {
                return ProcessAudioRecorder(
                    recorderURL: try recorderURLResolver(),
                    micURL: paths.micWavURL,
                    systemURL: paths.systemWavURL,
                    logURL: paths.jobLogURL
                )
            }

            return EmbeddedAudioRecorder(
                micURL: paths.micWavURL,
                systemURL: paths.systemWavURL,
                microphoneVoiceProcessingEnabled: settings.recording.microphoneVoiceProcessingEnabled,
                microphoneDeviceUID: settings.recording.microphoneDeviceUID
            )
        }
        _ = fileManager
        _ = watchdogKillGracePeriod
        self.watchdogPollInterval = watchdogPollInterval
        self.watchdogHungInterval = watchdogHungInterval
        self.sleep = sleep
    }

    func start(
        jobId: String,
        source: String = "manual",
        title: String = "Manual recording",
        autoStopAt: Date? = nil,
        microphonePausedAtStart: Bool = false,
        systemSpeakersOverride: Int? = nil,
        calendarEventUID: String? = nil,
        calendarEvent: CalendarEvent? = nil
    ) async throws -> RecordingSession {
        guard activeSession == nil, !isStarting else {
            throw RecordingAlreadyActiveError()
        }
        isStarting = true
        await appStateDidChange(.recording)
        defer {
            isStarting = false
        }

        let startRequestedAt = Date()
        let startedAt = Date()
        let paths = try storageService.createMeetingFolder(jobId: jobId, startedAt: startedAt)
        let settings = await appSettingsStore.load(using: loggingService)
        let recorder = try recorderFactory(paths, settings)
        systemAudioUnexpectedRestartAttempts = []
        didNotifySystemAudioFailure = false
        recorder.setSystemAudioInterruptionHandler { [weak self] reason in
            Task {
                await self?.handleSystemAudioStreamStopped(jobId: jobId, reason: reason)
            }
        }
        try await recorder.start()
        let recorderReadyAt = Date()
        if microphonePausedAtStart {
            try recorder.setMicrophonePaused(true)
        }
        try writeMeetingMetadata(
            title: title,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEventUID: calendarEventUID,
            calendarEvent: calendarEvent,
            to: paths.folderURL
        )

        let session = RecordingSession(
            jobId: jobId,
            pid: getpid(),
            paths: paths,
            startedAt: startedAt,
            source: source,
            title: title,
            autoStopDisabled: false,
            autoStopAt: autoStopAt,
            microphonePaused: microphonePausedAtStart,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEventUID: calendarEventUID
        )
        activeRecorder = recorder
        activeSession = session

        // Diagnostic-only output monitor. With the embedded recorder, long
        // silent periods are legitimate, so lack of file growth must not stop
        // an otherwise healthy recording.
        recorderWatchdogTask = Task { [weak self] in
            await self?.monitorRecorderOutput(for: session)
        }

        let job = Job(
            id: jobId,
            meetingId: jobId,
            status: "recording",
            stage: .recording,
            progressPercent: JobProgress.percent(for: .recording, status: "recording"),
            source: source,
            createdAt: startedAt,
            updatedAt: startedAt
        )
        await jobRepository.upsert(job)
        let startupMs = Int(Date().timeIntervalSince(startRequestedAt) * 1000)
        let recorderStartupMs = Int(recorderReadyAt.timeIntervalSince(startRequestedAt) * 1000)
        await loggingService.log(
            "Started embedded recorder in AnyBrief pid=\(session.pid) for job \(jobId) (recorderReady=\(recorderStartupMs)ms, startup=\(startupMs)ms)",
            level: .info,
            component: "Recording"
        )
        await logRecordingDiagnostics("Recording started", for: session, activity: recorder.outputActivity())
        await appStateDidChange(.recording)
        schedulePreEndWarning(for: session)
        if let notificationService {
            await notificationService.notifyRecordingStarted()
        }
        return session
    }

    func stop() async throws -> RecordingSession {
        guard let session = activeSession, let recorder = activeRecorder else {
            throw NoActiveRecordingError()
        }
        var finishedSession = session

        recorderWatchdogTask?.cancel()
        recorderWatchdogTask = nil
        preEndNotificationTask?.cancel()
        preEndNotificationTask = nil
        recorder.setSystemAudioInterruptionHandler(nil)

        let stopError: Error?
        do {
            try await stopRecorder(recorder, for: session)
            try validateOutputs(for: finishedSession)
            let warnings = systemAudioQualityWarnings(for: finishedSession)
            if !warnings.isEmpty {
                finishedSession = finishedSession.withRecordingWarnings(warnings)
                for warning in warnings {
                    await loggingService.log(
                        "Recording quality warning for job \(finishedSession.jobId): \(warning)",
                        level: .warn,
                        component: "Recording"
                    )
                }
            }
            stopError = nil
        } catch let error as RecorderAlreadyStoppedError {
            do {
                try validateOutputs(for: finishedSession)
                await loggingService.log(
                    "Recorder for job \(finishedSession.jobId) had already stopped before the stop request: \(error.localizedDescription)",
                    level: .warn,
                    component: "Recording"
                )
                stopError = nil
            } catch {
                stopError = error
            }
        } catch {
            stopError = error
        }

        activeSession = nil
        activeRecorder = nil
        systemAudioUnexpectedRestartAttempts = []
        didNotifySystemAudioFailure = false

        if let stopError {
            let failedJob = await updatedJob(
                from: finishedSession,
                status: "failed",
                stage: .recording,
                errorState: errorState(from: stopError, stage: .recording)
            )
            await jobRepository.upsert(failedJob)
            await loggingService.log(
                "Recording failed for job \(finishedSession.jobId): \(stopError.localizedDescription)",
                level: .error,
                component: "Recording"
            )
            await appStateDidChange(.error)
            throw stopError
        }

        let recordedJob = await updatedJob(from: finishedSession, status: "recorded", stage: .recorded)
        await jobRepository.upsert(recordedJob)
        if let notificationService {
            await notificationService.notifyRecordingStopped()
        }
        return finishedSession
    }

    private func writeMeetingMetadata(
        title: String,
        systemSpeakersOverride: Int?,
        calendarEventUID: String?,
        calendarEvent: CalendarEvent?,
        to folderURL: URL
    ) throws {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            try trimmedTitle.write(
                to: folderURL.appendingPathComponent(".anybrief-title", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }

        let metadata = AutopilotRecordingMetadata(
            calendarEventUID: calendarEventUID,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEvent: calendarEvent
        )
        guard metadata.calendarEventUID != nil || metadata.systemSpeakersOverride != nil || metadata.calendarEvent != nil else {
            return
        }
        let data = try JSONEncoder().encode(metadata)
        try data.write(
            to: folderURL.appendingPathComponent(".anybrief-autopilot.json", isDirectory: false),
            options: .atomic
        )
    }

    func currentSession() -> RecordingSession? {
        activeSession
    }

    func setMicrophonePaused(_ paused: Bool) async throws -> RecordingSession {
        guard let session = activeSession, let recorder = activeRecorder else {
            throw NoActiveRecordingError()
        }

        try recorder.setMicrophonePaused(paused)
        let updatedSession = session.withMicrophonePaused(paused)
        activeSession = updatedSession
        await loggingService.log(
            paused
                ? "Microphone recording paused for job \(updatedSession.jobId); writing silence to mic.wav."
                : "Microphone recording resumed for job \(updatedSession.jobId).",
            level: .info,
            component: "Recording"
        )
        return updatedSession
    }

    func setMicrophoneVoiceProcessingEnabled(_ enabled: Bool) async throws {
        guard let activeRecorder else {
            return
        }
        try activeRecorder.setMicrophoneVoiceProcessingEnabled(enabled)
        await loggingService.log(
            "Applied microphone voice processing setting to active recorder: enabled=\(enabled), inputDevice=\(activeRecorder.microphoneDiagnosticDescription())",
            level: .info,
            component: "Recording"
        )
    }

    func setMicrophoneDeviceUID(_ uid: String?) async throws {
        guard let activeRecorder else {
            return
        }
        try activeRecorder.setMicrophoneDeviceUID(uid)
        await loggingService.log(
            "Applied microphone selection to active recorder: requestedUID=\(uid ?? "system"), inputDevice=\(activeRecorder.microphoneDiagnosticDescription())",
            level: .info,
            component: "Recording"
        )
    }

    func isMicrophonePaused() -> Bool {
        activeSession?.microphonePaused ?? false
    }

    func audioLevels() -> AudioLevelSnapshot {
        guard activeSession != nil, let activeRecorder else {
            return AudioLevelSnapshot()
        }
        return activeRecorder.audioLevels()
    }

    func disableAutoStop() throws -> RecordingSession {
        guard let session = activeSession else {
            throw NoActiveRecordingError()
        }
        guard session.source == "calendar" else {
            throw NotCalendarRecordingError()
        }

        let updatedSession = session.withAutoStopDisabled(true)
        activeSession = updatedSession
        preEndNotificationTask?.cancel()
        preEndNotificationTask = nil
        return updatedSession
    }

    func cancel(jobId: String) async throws -> Job {
        guard let session = activeSession,
              let recorder = activeRecorder,
              session.jobId == jobId else {
            throw NoActiveRecordingError()
        }

        recorderWatchdogTask?.cancel()
        recorderWatchdogTask = nil
        preEndNotificationTask?.cancel()
        preEndNotificationTask = nil
        recorder.setSystemAudioInterruptionHandler(nil)

        try? await recorder.stop()

        activeSession = nil
        activeRecorder = nil
        systemAudioUnexpectedRestartAttempts = []
        didNotifySystemAudioFailure = false

        try? storageService.cleanupTemporaryArtifacts(for: session.paths)

        let now = Date()
        let cancelledJob = Job(
            id: jobId,
            meetingId: jobId,
            status: "cancelled",
            stage: .cancelled,
            progressPercent: JobProgress.percent(for: .cancelled, status: "cancelled"),
            source: session.source,
            createdAt: session.startedAt,
            updatedAt: now,
            completedAt: now
        )
        await jobRepository.upsert(cancelledJob)
        await loggingService.log(
            "Cancelled active recording for job \(jobId)",
            level: .info,
            component: "Recording"
        )
        await appStateDidChange(.idle)
        return cancelledJob
    }

    private func stopRecorder(_ recorder: AudioRecording, for session: RecordingSession) async throws {
        await logRecordingDiagnostics("Stopping recorder", for: session, activity: recorder.outputActivity())
        if session.microphoneDegraded {
            let elapsed = Date().timeIntervalSince(session.startedAt)
            do {
                try recorder.padMicrophoneSilence(toDuration: elapsed)
                await loggingService.log(
                    "Padded microphone output with silence through \(formatSeconds(elapsed)) before stopping degraded recording job \(session.jobId).",
                    level: .warn,
                    component: "Recording"
                )
            } catch {
                await loggingService.log(
                    "Unable to pad degraded microphone output with silence before stopping job \(session.jobId): \(error.localizedDescription)",
                    level: .warn,
                    component: "Recording"
                )
            }
        }
        try await recorder.stop()
        await loggingService.log(
            "Stopped embedded recorder for job \(session.jobId)",
            level: .info,
            component: "Recording"
        )
        await logRecordingDiagnostics("Recorder stopped", for: session, activity: recorder.outputActivity())
    }

    private func validateOutputs(for session: RecordingSession) throws {
        let urls = [session.paths.systemWavURL, session.paths.micWavURL]

        for url in urls {
            let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = resourceValues.fileSize, fileSize > 0 else {
                throw RecordingOutputInvalidError(
                    message: "Recorder output is missing or empty at \(url.path)."
                )
            }
        }

        guard !session.microphonePaused,
              !session.microphoneDegraded,
              let systemDuration = audioDurationIfReadable(for: session.paths.systemWavURL),
              let micDuration = audioDurationIfReadable(for: session.paths.micWavURL),
              systemDuration >= minimumComparableTrackDuration,
              micDuration < systemDuration * minimumMicToSystemDurationRatio
        else {
            return
        }

        throw RecordingOutputInvalidError(
            message: "Microphone recording is much shorter than system audio (mic \(Int(micDuration.rounded()))s, system \(Int(systemDuration.rounded()))s). Check microphone capture before processing."
        )
    }

    private func monitorRecorderOutput(for session: RecordingSession) async {
        let watchedURLs = [session.paths.systemWavURL, session.paths.micWavURL]
        var lastObservedProgress = recorderOutputProgress(for: watchedURLs)
        var lastActivity = activeRecorder?.outputActivity()
        var lastGrowthAt = Date()
        var lastMicrophoneGrowthAt = Date()
        var lastInputDevice = activeRecorder?.microphoneDiagnosticDescription()
        var lastOutputDevice = activeRecorder?.systemOutputDiagnosticDescription()
        var didWarnAboutStall = false
        var didWarnAboutMicrophoneStall = false
        var didAttemptMicrophoneRestart = false
        var lowSystemLevelPolls = 0
        var didWarnAboutLowSystemLevel = false

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(watchdogPollInterval * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            guard let currentSession = activeSession,
                  currentSession.jobId == session.jobId else {
                return
            }

            let currentProgress = recorderOutputProgress(for: watchedURLs)
            let currentActivity = activeRecorder?.outputActivity()
            await logRecordingDiagnostics("Recording heartbeat", for: currentSession, activity: currentActivity)
            let currentInputDevice = activeRecorder?.microphoneDiagnosticDescription()
            let currentOutputDevice = activeRecorder?.systemOutputDiagnosticDescription()
            let levels = activeRecorder?.audioLevels() ?? AudioLevelSnapshot()
            if currentSession.microphonePaused == false,
               let previousInputDevice = lastInputDevice,
               let currentInputDevice,
               currentInputDevice != previousInputDevice {
                await padMicrophoneSilenceThroughNow(for: currentSession)
                do {
                    try activeRecorder?.restartMicrophoneCapture()
                    lastInputDevice = activeRecorder?.microphoneDiagnosticDescription() ?? currentInputDevice
                    lastMicrophoneGrowthAt = Date()
                    lastActivity = activeRecorder?.outputActivity()
                    didWarnAboutMicrophoneStall = false
                    didAttemptMicrophoneRestart = false
                    await loggingService.log(
                        "Restarted microphone capture for job \(currentSession.jobId) after input device changed from \(previousInputDevice) to \(lastInputDevice ?? currentInputDevice).",
                        level: .info,
                        component: "Recording"
                    )
                } catch {
                    lastInputDevice = currentInputDevice
                    let warning = "microphone_degraded: microphone input device changed from \(previousInputDevice) to \(currentInputDevice), but restart failed: \(error.localizedDescription)"
                    await markMicrophoneDegraded(for: currentSession, warning: warning)
                    lastMicrophoneGrowthAt = Date()
                }
                await restartSystemAudioCapture(
                    for: currentSession,
                    reason: "input device changed from \(previousInputDevice) to \(currentInputDevice)"
                )
                lastOutputDevice = activeRecorder?.systemOutputDiagnosticDescription() ?? currentOutputDevice
                continue
            } else {
                lastInputDevice = currentInputDevice ?? lastInputDevice
            }

            if let previousOutputDevice = lastOutputDevice,
               let currentOutputDevice,
               currentOutputDevice != previousOutputDevice {
                await restartSystemAudioCapture(
                    for: currentSession,
                    reason: "output device changed from \(previousOutputDevice) to \(currentOutputDevice)"
                )
                lastOutputDevice = activeRecorder?.systemOutputDiagnosticDescription() ?? currentOutputDevice
                continue
            } else {
                lastOutputDevice = currentOutputDevice ?? lastOutputDevice
            }

            if let currentActivity,
               currentActivity.systemFramesWritten > 0,
               Date().timeIntervalSince(currentSession.startedAt) >= minimumComparableTrackDuration,
               levels.system < lowSystemLevelThreshold {
                lowSystemLevelPolls += 1
                if lowSystemLevelPolls >= lowSystemLevelWarningPolls, !didWarnAboutLowSystemLevel {
                    didWarnAboutLowSystemLevel = true
                    let warning = "system_audio_degraded: system audio level stayed very low while frames were being written (level=\(formatLevel(levels.system)), outputDevice=\(currentOutputDevice ?? "unknown"))."
                    await markSystemAudioDegraded(for: currentSession, warning: warning)
                }
            } else {
                lowSystemLevelPolls = 0
            }

            if let currentActivity, let previousActivity = lastActivity {
                if currentActivity.microphoneFramesWritten > previousActivity.microphoneFramesWritten {
                    lastMicrophoneGrowthAt = Date()
                    didWarnAboutMicrophoneStall = false
                } else if currentSession.microphonePaused == false,
                          currentActivity.systemFramesWritten > previousActivity.systemFramesWritten {
                    let stalledFor = Date().timeIntervalSince(lastMicrophoneGrowthAt)
                    if stalledFor >= watchdogHungInterval, !didWarnAboutMicrophoneStall {
                        let inputDevice = activeRecorder?.microphoneDiagnosticDescription() ?? "unavailable"
                        await loggingService.log(
                            "Microphone output has not advanced for \(Int(stalledFor.rounded())) seconds while system audio is still being recorded (micFrames=\(currentActivity.microphoneFramesWritten), systemFrames=\(currentActivity.systemFramesWritten), inputDevice=\(inputDevice)).",
                            level: .warn,
                            component: "Recording"
                        )
                        didWarnAboutMicrophoneStall = true
                    }
                    if stalledFor >= watchdogHungInterval, !didAttemptMicrophoneRestart {
                        didAttemptMicrophoneRestart = true
                        await padMicrophoneSilenceThroughNow(for: currentSession)
                        do {
                            try activeRecorder?.restartMicrophoneCapture()
                            lastMicrophoneGrowthAt = Date()
                            lastActivity = activeRecorder?.outputActivity()
                            didWarnAboutMicrophoneStall = false
                            await loggingService.log(
                                "Restarted microphone capture for job \(currentSession.jobId) after \(Int(stalledFor.rounded())) seconds without microphone output growth (inputDevice=\(activeRecorder?.microphoneDiagnosticDescription() ?? "unavailable")).",
                                level: .warn,
                                component: "Recording"
                            )
                            continue
                        } catch {
                            let warning = "microphone_degraded: microphone capture stopped advancing while system audio continued; restart failed: \(error.localizedDescription)"
                            await markMicrophoneDegraded(for: currentSession, warning: warning)
                            lastMicrophoneGrowthAt = Date()
                        }
                    } else if stalledFor >= watchdogHungInterval,
                              didAttemptMicrophoneRestart,
                              !currentSession.microphoneDegraded {
                        await padMicrophoneSilenceThroughNow(for: currentSession)
                        let warning = "microphone_degraded: microphone capture stopped advancing while system audio continued after restart attempt"
                        await markMicrophoneDegraded(for: currentSession, warning: warning)
                    }
                }
            }
            lastActivity = currentActivity

            if currentProgress.value > lastObservedProgress.value {
                lastObservedProgress = currentProgress
                lastGrowthAt = Date()
                didWarnAboutStall = false
                continue
            }

            let stalledFor = Date().timeIntervalSince(lastGrowthAt)
            guard stalledFor >= watchdogHungInterval else {
                continue
            }

            if activeRecorder?.outputActivity() == nil {
                await failHungRecorder(for: session, stalledFor: stalledFor)
                return
            }

            guard !didWarnAboutStall else {
                continue
            }
            await loggingService.log(
                "Recorder output has not advanced for \(Int(stalledFor.rounded())) seconds (\(currentProgress.description)). Continuing because embedded recording can be silent.",
                level: .warn,
                component: "Recording"
            )
            didWarnAboutStall = true
        }
    }

    private func failHungRecorder(for session: RecordingSession, stalledFor: TimeInterval) async {
        guard let recorder = activeRecorder,
              let currentSession = activeSession,
              currentSession.jobId == session.jobId else {
            return
        }

        recorderWatchdogTask?.cancel()
        recorderWatchdogTask = nil
        preEndNotificationTask?.cancel()
        preEndNotificationTask = nil
        recorder.setSystemAudioInterruptionHandler(nil)
        activeSession = nil
        activeRecorder = nil
        systemAudioUnexpectedRestartAttempts = []
        didNotifySystemAudioFailure = false

        try? await recorder.stop()

        let failedJob = await updatedJob(
            from: session,
            status: "failed",
            stage: .recording,
            errorState: Job.ErrorState(
                code: "recorder_hung",
                message: RecorderHungError(stalledFor: stalledFor).localizedDescription,
                stage: JobStage.recording.rawValue,
                retryable: false
            )
        )
        await jobRepository.upsert(failedJob)
        await loggingService.log(
            "Recorder watchdog marked job \(session.jobId) as hung after \(Int(stalledFor.rounded())) seconds without output growth.",
            level: .error,
            component: "Recording"
        )
        await appStateDidChange(.error)
    }

    private func markMicrophoneDegraded(for session: RecordingSession, warning: String) async {
        guard let currentSession = activeSession,
              currentSession.jobId == session.jobId,
              currentSession.microphoneDegraded == false else {
            return
        }

        let updatedSession = currentSession.withMicrophoneDegraded(warning)
        activeSession = updatedSession
        let job = await updatedJob(from: updatedSession, status: "recording", stage: .recording)
        await jobRepository.upsert(job)
        await loggingService.log(
            "Marked recording job \(updatedSession.jobId) as microphone_degraded; continuing system audio capture. \(warning)",
            level: .warn,
            component: "Recording"
        )
    }

    private func markSystemAudioDegraded(for session: RecordingSession, warning: String) async {
        guard let currentSession = activeSession,
              currentSession.jobId == session.jobId,
              !currentSession.recordingWarnings.contains(warning) else {
            return
        }

        let updatedSession = currentSession.withRecordingWarning(warning)
        activeSession = updatedSession
        let job = await updatedJob(from: updatedSession, status: "recording", stage: .recording)
        await jobRepository.upsert(job)
        await loggingService.log(
            "Marked recording job \(updatedSession.jobId) as system_audio_degraded. \(warning)",
            level: .warn,
            component: "Recording"
        )
    }

    private func addRecordingWarning(for session: RecordingSession, warning: String) async {
        guard let currentSession = activeSession,
              currentSession.jobId == session.jobId,
              !currentSession.recordingWarnings.contains(warning) else {
            return
        }

        let updatedSession = currentSession.withRecordingWarning(warning)
        activeSession = updatedSession
        let job = await updatedJob(from: updatedSession, status: "recording", stage: .recording)
        await jobRepository.upsert(job)
    }

    private func notifySystemAudioFailureIfNeeded(jobId: String, reason: String) async {
        guard !didNotifySystemAudioFailure else {
            await loggingService.log(
                "Skipped duplicate system audio failure notification for job \(jobId): \(reason)",
                level: .debug,
                component: "Recording"
            )
            return
        }

        didNotifySystemAudioFailure = true
        guard let notificationService else {
            await loggingService.log(
                "System audio failure notification unavailable for job \(jobId): \(reason)",
                level: .warn,
                component: "Recording"
            )
            return
        }

        await notificationService.notifySystemAudioFailed()
        await loggingService.log(
            "Notified user that system audio recording failed for job \(jobId): \(reason)",
            level: .warn,
            component: "Recording"
        )
    }

    private func handleSystemAudioStreamStopped(jobId: String, reason: String) async {
        guard let currentSession = activeSession,
              currentSession.jobId == jobId,
              let recorder = activeRecorder else {
            await loggingService.log(
                "Ignored system audio stream stop callback for inactive job \(jobId): \(reason)",
                level: .debug,
                component: "Recording"
            )
            return
        }

        let now = Date()
        systemAudioUnexpectedRestartAttempts = systemAudioUnexpectedRestartAttempts.filter {
            now.timeIntervalSince($0) <= systemAudioUnexpectedRestartWindow
        }

        guard systemAudioUnexpectedRestartAttempts.count < systemAudioUnexpectedRestartLimit else {
            let warning = "system_audio_degraded: system audio stream stopped unexpectedly and automatic restart limit was reached; continuing without reliable system audio (reason: \(reason))."
            await loggingService.log(
                "System audio stream stopped unexpectedly for job \(jobId), but restart limit \(systemAudioUnexpectedRestartLimit) per \(Int(systemAudioUnexpectedRestartWindow))s was reached. \(warning)",
                level: .warn,
                component: "Recording"
            )
            await notifySystemAudioFailureIfNeeded(jobId: jobId, reason: warning)
            await markSystemAudioDegraded(for: currentSession, warning: warning)
            return
        }

        systemAudioUnexpectedRestartAttempts.append(now)
        let attempt = systemAudioUnexpectedRestartAttempts.count
        await loggingService.log(
            "System audio stream stopped unexpectedly for job \(jobId); attempting automatic restart \(attempt)/\(systemAudioUnexpectedRestartLimit) (reason: \(reason)).",
            level: .warn,
            component: "Recording"
        )

        do {
            try await recorder.restartSystemAudioCapture()
            let warning = "system_audio_restarted: ScreenCaptureKit stream stopped unexpectedly and was restarted; a short system-audio gap may exist (reason: \(reason))."
            await addRecordingWarning(for: currentSession, warning: warning)
            await loggingService.log(
                "Restarted system audio capture for job \(jobId) after unexpected ScreenCaptureKit stream stop; recording continues, but a short system-audio gap may exist (reason: \(reason)).",
                level: .info,
                component: "Recording"
            )
        } catch {
            let warning = "system_audio_degraded: system audio stream stopped unexpectedly and automatic restart failed: \(error.localizedDescription) (reason: \(reason))."
            await loggingService.log(
                "Automatic system audio restart failed for job \(jobId) after unexpected ScreenCaptureKit stream stop: \(error.localizedDescription) (reason: \(reason)).",
                level: .warn,
                component: "Recording"
            )
            await notifySystemAudioFailureIfNeeded(jobId: jobId, reason: warning)
            await markSystemAudioDegraded(for: currentSession, warning: warning)
        }
    }

    private func restartSystemAudioCapture(for session: RecordingSession, reason: String) async {
        guard let recorder = activeRecorder else {
            return
        }

        do {
            try await recorder.restartSystemAudioCapture()
            await loggingService.log(
                "Restarted system audio capture for job \(session.jobId) after \(reason).",
                level: .info,
                component: "Recording"
            )
        } catch {
            let warning = "system_audio_degraded: system audio capture restart failed after \(reason): \(error.localizedDescription)"
            await notifySystemAudioFailureIfNeeded(jobId: session.jobId, reason: warning)
            await markSystemAudioDegraded(for: session, warning: warning)
        }
    }

    private func padMicrophoneSilenceThroughNow(for session: RecordingSession) async {
        let elapsed = Date().timeIntervalSince(session.startedAt)
        do {
            try activeRecorder?.padMicrophoneSilence(toDuration: elapsed)
            await loggingService.log(
                "Padded microphone output with silence through \(formatSeconds(elapsed)) for job \(session.jobId).",
                level: .warn,
                component: "Recording"
            )
        } catch {
            await loggingService.log(
                "Unable to pad microphone output with silence for job \(session.jobId): \(error.localizedDescription)",
                level: .warn,
                component: "Recording"
            )
        }
    }

    private func recorderOutputProgress(for urls: [URL]) -> RecorderOutputProgress {
        if let activity = activeRecorder?.outputActivity() {
            return RecorderOutputProgress(
                value: activity.framesWritten,
                description: "frames=\(activity.framesWritten)"
            )
        }

        let size = totalSize(of: urls)
        return RecorderOutputProgress(
            value: Int64(size),
            description: "size=\(size) bytes"
        )
    }

    private func totalSize(of urls: [URL]) -> Int {
        urls.reduce(0) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + max(0, size)
        }
    }

    private func audioDurationIfReadable(for url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else {
            return nil
        }
        let duration = Double(file.length) / sampleRate
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private func systemAudioQualityWarnings(for session: RecordingSession) -> [String] {
        guard let report = audioSignalReport(for: session.paths.systemWavURL),
              report.duration >= minimumComparableTrackDuration else {
            return []
        }
        let microphoneReport = audioSignalReport(for: session.paths.micWavURL)
        let micCoveredSystemQuietRatio = microphoneReport.map {
            Self.microphoneCoveredSystemQuietRatio(system: report, microphone: $0)
        } ?? 0
        let microphoneExplainsSystemQuiet = micCoveredSystemQuietRatio >= microphoneExplainsSystemQuietRatio

        var reasons: [String] = []
        if report.activeRatio < 0.04, !microphoneExplainsSystemQuiet {
            reasons.append("active=\(formatPercent(report.activeRatio))")
        }
        if report.peak < 0.02, !microphoneExplainsSystemQuiet {
            reasons.append("peak=\(formatLevel(report.peak))")
        }
        let longQuietThreshold = min(180, report.duration * 0.35)
        let longestUnexplainedQuiet = microphoneReport.map {
            Self.longestSystemQuietWithoutMicrophone(system: report, microphone: $0)
        } ?? report.longestQuietDuration
        if longestUnexplainedQuiet >= longQuietThreshold {
            reasons.append("longest_unexplained_quiet=\(formatSeconds(longestUnexplainedQuiet))")
        }

        guard !reasons.isEmpty else {
            return []
        }
        return [
            "system_audio_degraded: system audio looks suspiciously quiet or intermittent (\(reasons.joined(separator: ", ")), duration=\(formatSeconds(report.duration)). Check the source audio before trusting the transcript."
        ]
    }

    private func audioSignalReport(for url: URL) -> AudioSignalReport? {
        guard let file = try? AVAudioFile(forReading: url) else {
            return nil
        }
        let format = file.processingFormat
        let sampleRate = format.sampleRate
        guard sampleRate > 0, format.channelCount > 0 else {
            return nil
        }

        let activeThreshold: Float = 0.015
        let samplesPerSecond = 200.0
        let activityBucketsPerSecond = 20.0
        let activityBucketDuration = 1.0 / activityBucketsPerSecond
        let strideFrames = max(1, Int(sampleRate / samplesPerSecond))
        let chunkCapacity = AVAudioFrameCount(min(max(Int(sampleRate), strideFrames), 48_000))
        var sampledFrames = 0
        var activeFrames = 0
        var sumSquares = 0.0
        var peak: Float = 0
        var currentQuietFrames = 0
        var longestQuietFrames = 0
        var activityBuckets: [Bool] = []

        while file.framePosition < file.length {
            let chunkStartFrame = file.framePosition
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkCapacity) else {
                return nil
            }
            do {
                try file.read(into: buffer, frameCount: chunkCapacity)
            } catch {
                return nil
            }

            let frameLength = Int(buffer.frameLength)
            guard frameLength > 0 else {
                break
            }
            guard let channels = buffer.floatChannelData else {
                return nil
            }

            let channelCount = Int(format.channelCount)
            for frame in stride(from: 0, to: frameLength, by: strideFrames) {
                var maxAbs: Float = 0
                var frameSquareSum = 0.0
                for channel in 0..<channelCount {
                    let value = channels[channel][frame]
                    let absValue = abs(value)
                    maxAbs = max(maxAbs, absValue)
                    frameSquareSum += Double(value * value)
                }

                sampledFrames += strideFrames
                sumSquares += frameSquareSum / Double(channelCount)
                peak = max(peak, maxAbs)
                let isActive = maxAbs >= activeThreshold
                let sampleTime = Double(chunkStartFrame + AVAudioFramePosition(frame)) / sampleRate
                let bucketIndex = max(0, Int(sampleTime / activityBucketDuration))
                if bucketIndex >= activityBuckets.count {
                    activityBuckets.append(contentsOf: Array(repeating: false, count: bucketIndex - activityBuckets.count + 1))
                }
                activityBuckets[bucketIndex] = activityBuckets[bucketIndex] || isActive

                if isActive {
                    activeFrames += strideFrames
                    longestQuietFrames = max(longestQuietFrames, currentQuietFrames)
                    currentQuietFrames = 0
                } else {
                    currentQuietFrames += strideFrames
                }
            }
        }

        longestQuietFrames = max(longestQuietFrames, currentQuietFrames)
        guard sampledFrames > 0 else {
            return nil
        }

        let sampledPoints = max(1, sampledFrames / strideFrames)
        let rms = sqrt(sumSquares / Double(sampledPoints))
        let duration = Double(file.length) / sampleRate
        return AudioSignalReport(
            duration: duration,
            rms: rms,
            peak: Double(peak),
            activeRatio: Double(activeFrames) / Double(sampledFrames),
            longestQuietDuration: Double(longestQuietFrames) / sampleRate,
            activityBucketDuration: activityBucketDuration,
            activeBuckets: activityBuckets
        )
    }

    private static func microphoneCoveredSystemQuietRatio(
        system: AudioSignalReport,
        microphone: AudioSignalReport
    ) -> Double {
        let count = min(system.activeBuckets.count, microphone.activeBuckets.count)
        guard count > 0 else {
            return 0
        }

        var systemQuietBuckets = 0
        var microphoneActiveDuringSystemQuietBuckets = 0
        for index in 0..<count where !system.activeBuckets[index] {
            systemQuietBuckets += 1
            if microphone.activeBuckets[index] {
                microphoneActiveDuringSystemQuietBuckets += 1
            }
        }

        guard systemQuietBuckets > 0 else {
            return 0
        }
        return Double(microphoneActiveDuringSystemQuietBuckets) / Double(systemQuietBuckets)
    }

    private static func longestSystemQuietWithoutMicrophone(
        system: AudioSignalReport,
        microphone: AudioSignalReport
    ) -> TimeInterval {
        let count = min(system.activeBuckets.count, microphone.activeBuckets.count)
        guard count > 0 else {
            return system.longestQuietDuration
        }

        var currentQuietBuckets = 0
        var longestQuietBuckets = 0
        for index in 0..<count {
            if !system.activeBuckets[index], !microphone.activeBuckets[index] {
                currentQuietBuckets += 1
            } else {
                longestQuietBuckets = max(longestQuietBuckets, currentQuietBuckets)
                currentQuietBuckets = 0
            }
        }
        longestQuietBuckets = max(longestQuietBuckets, currentQuietBuckets)
        return TimeInterval(longestQuietBuckets) * system.activityBucketDuration
    }

    private func logRecordingDiagnostics(
        _ prefix: String,
        for session: RecordingSession,
        activity: AudioOutputActivity?
    ) async {
        let inputDevice = activeRecorder?.microphoneDiagnosticDescription() ?? "unavailable"
        let outputDevice = activeRecorder?.systemOutputDiagnosticDescription() ?? "unavailable"
        let levels = activeRecorder?.audioLevels() ?? AudioLevelSnapshot()
        await loggingService.log(
            "\(prefix) for job \(session.jobId): \(recordingDiagnostics(for: session, activity: activity)), levels{system=\(formatLevel(levels.system)), mic=\(formatLevel(levels.microphone))}, inputDevice=\(inputDevice), outputDevice=\(outputDevice)",
            level: .info,
            component: "Recording"
        )
    }

    private func recordingDiagnostics(for session: RecordingSession, activity: AudioOutputActivity?) -> String {
        let elapsed = Date().timeIntervalSince(session.startedAt)
        return "elapsed=\(formatSeconds(elapsed)), microphonePaused=\(session.microphonePaused), microphoneDegraded=\(session.microphoneDegraded), " +
        "system{\(trackDiagnostics(url: session.paths.systemWavURL, frames: activity?.systemFramesWritten))}, " +
        "mic{\(trackDiagnostics(url: session.paths.micWavURL, frames: activity?.microphoneFramesWritten))}"
    }

    private func trackDiagnostics(url: URL, frames: Int64?) -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let duration = audioDurationIfReadable(for: url).map(formatSeconds) ?? "unknown"
        let framesText = frames.map(String.init) ?? "unknown"
        return "sizeKB=\(size / 1024), duration=\(duration), frames=\(framesText)"
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.1fs", seconds)
    }

    private func formatLevel(_ level: Double) -> String {
        String(format: "%.3f", level)
    }

    private func formatPercent(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private struct RecorderOutputProgress {
        let value: Int64
        let description: String
    }

    private struct AudioSignalReport {
        let duration: TimeInterval
        let rms: Double
        let peak: Double
        let activeRatio: Double
        let longestQuietDuration: TimeInterval
        let activityBucketDuration: TimeInterval
        let activeBuckets: [Bool]
    }

    private func schedulePreEndWarning(for session: RecordingSession) {
        preEndNotificationTask?.cancel()
        preEndNotificationTask = nil

        guard session.source == "calendar",
              let autoStopAt = session.autoStopAt,
              let notificationService else {
            return
        }

        preEndNotificationTask = Task { [weak self] in
            guard let self else { return }

            let settings = await self.appSettingsStore.load(using: self.loggingService)
            let fireDate = autoStopAt.addingTimeInterval(TimeInterval(-settings.automation.calendarAutopilotSettings.preEndNotificationSec))
            let delay = fireDate.timeIntervalSinceNow
            guard delay > 0 else {
                return
            }

            await self.sleep(UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled,
                  let currentSession = await self.currentSession(),
                  currentSession.jobId == session.jobId,
                  !currentSession.autoStopDisabled else {
                return
            }

            await notificationService.notifyPreEndWarning()
        }
    }

    private func updatedJob(
        from session: RecordingSession,
        status: String,
        stage: JobStage,
        errorState: Job.ErrorState? = nil
    ) async -> Job {
        let now = Date()
        if let existingJob = await jobRepository.get(id: session.jobId) {
            return Job(
                id: existingJob.id,
                meetingId: existingJob.meetingId,
                status: status,
                stage: stage,
                progressPercent: JobProgress.percent(for: stage, status: status),
                source: existingJob.source,
                createdAt: existingJob.createdAt,
                updatedAt: now,
                completedAt: status == "failed" ? now : existingJob.completedAt,
                retryCount: existingJob.retryCount,
                error: errorState,
                warnings: Self.mergedWarnings(existingJob.warnings, session.recordingWarnings)
            )
        }

        return Job(
            id: session.jobId,
            meetingId: session.jobId,
            status: status,
            stage: stage,
            progressPercent: JobProgress.percent(for: stage, status: status),
            source: session.source,
            createdAt: session.startedAt,
            updatedAt: now,
            completedAt: status == "failed" ? now : nil,
            error: errorState,
            warnings: session.recordingWarnings
        )
    }

    private static func mergedWarnings(_ existing: [String], _ incoming: [String]) -> [String] {
        var merged = existing
        for warning in incoming where !merged.contains(warning) {
            merged.append(warning)
        }
        return merged
    }

    private func errorState(from error: Error, stage: JobStage) -> Job.ErrorState {
        let code: String
        if error is RecordingOutputInvalidError {
            code = "recording_output_invalid"
        } else if error is RecorderHungError {
            code = "recorder_hung"
        } else if error is NoActiveRecordingError {
            code = "no_active_recording"
        } else {
            code = "recording_failed"
        }

        return Job.ErrorState(
            code: code,
            message: error.localizedDescription,
            stage: stage.rawValue,
            retryable: false
        )
    }

}
