import AVFoundation
import XCTest
@testable import AnyBrief

/// Tests pipeline fallback and recorder watchdog behavior from the error-handling spec.
final class PipelineRobustnessTests: XCTestCase {
    func testPipelineCreatesFallbackSummaryAndMarksPartialSuccess() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let folderURL = rootURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        let jobLogURL = rootURL.appendingPathComponent("job.log", isDirectory: false)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try Data().write(to: jobLogURL)

        let transcriptText = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty twentyone twentytwo twentythree twentyfour twentyfive twentysix twentyseven twentyeight twentynine thirty"
        let transcript = "Speaker A: \(transcriptText)"
        try transcript.write(
            to: folderURL.appendingPathComponent("transcript.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 120, speaker: "Speaker A", text: transcriptText, sourceTrack: .system),
        ]
        try JSONEncoder().encode(segments).write(
            to: folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        )

        let session = RecordingSession(
            jobId: "job-summary-fallback",
            pid: 123,
            paths: MeetingPaths(
                folderURL: folderURL,
                tmpURL: tmpURL,
                systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
                micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
                jobLogURL: jobLogURL
            ),
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            source: "manual",
            title: "job-summary-fallback",
            autoStopDisabled: false
        )

        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        settings.llm.connections[0].retryCount = 3

        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: session.jobId,
                meetingId: session.jobId,
                status: "summarizing",
                stage: .summarizing,
                source: "manual",
                createdAt: session.startedAt,
                updatedAt: session.startedAt
            )
        )

        let stateRecorder = AppStateRecorder()
        let notificationRecorder = NotificationRecorder()
        let orchestrator = PipelineOrchestrator(
            jobRepository: jobRepository,
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            transcriptionService: TranscriptionService(),
            transcriptMergeService: TranscriptMergeService(),
            summarizationService: SummarizationService(
                keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
                session: SummarizationServiceTests.mockSession { request in
                    (
                        HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                },
                sleep: { _ in }
            ),
            finalizationService: FinalizationService(
                storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
                jobRepository: jobRepository,
                loggingService: LoggingService(),
                appStateDidChange: { _ in }
            ),
            loggingService: LoggingService(),
            appStateDidChange: { state in
                await stateRecorder.record(state)
            },
            notifyUser: { category, title, body in
                await notificationRecorder.record(category: category, title: title, body: body)
            }
        )

        await orchestrator.run(session: session, startingAt: .summarizing)

        let persistedJob = await jobRepository.get(id: session.jobId)
        let job = try XCTUnwrap(persistedJob)
        XCTAssertEqual(job.status, "partial_success")
        XCTAssertEqual(job.stage, .partialSuccess)
        XCTAssertEqual(job.error?.code, "summary_api_failed")

        let summary = try String(
            contentsOf: folderURL.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(summary.contains("status: partial_success"))
        XCTAssertTrue(summary.contains("summary_error: summary_api_failed"))
        XCTAssertTrue(summary.contains("Черновик - summary недоступен"))
        XCTAssertTrue(summary.contains(transcript))
        XCTAssertFalse(fileManager.fileExists(atPath: folderURL.appendingPathComponent("bundle.zip").path))

        let lastState = await stateRecorder.lastState()
        XCTAssertEqual(lastState, .idle)
        let notification = await notificationRecorder.currentValue()
        XCTAssertEqual(notification?.category, NotificationService.Category.summaryReady.rawValue)
        XCTAssertEqual(notification?.body, String(localized: "Your brief is ready"))
    }

    func testPipelineSkipsSummaryWhenTranscriptHasFewerThanThirtyWords() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let folderURL = rootURL.appendingPathComponent("2026-04-24_11-00_short", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        let jobLogURL = rootURL.appendingPathComponent("job-short.log", isDirectory: false)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try Data().write(to: jobLogURL)
        try TruncatedMicrophoneRecorder.writeSilentWav(to: tmpURL.appendingPathComponent("system.wav", isDirectory: false), seconds: 60)
        try TruncatedMicrophoneRecorder.writeSilentWav(to: tmpURL.appendingPathComponent("mic.wav", isDirectory: false), seconds: 60)

        let transcript = "one two three four five six seven eight nine ten eleven twelve thirteen fourteen"
        try transcript.write(
            to: folderURL.appendingPathComponent("transcript.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        let segments = [
            TranscriptSegment(startTime: 0, endTime: 60, speaker: "Speaker A", text: transcript, sourceTrack: .mic),
        ]
        try JSONEncoder().encode(segments).write(
            to: folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        )

        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]

        let session = RecordingSession(
            jobId: "job-short-summary",
            pid: 0,
            paths: MeetingPaths(
                folderURL: folderURL,
                tmpURL: tmpURL,
                systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
                micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
                jobLogURL: jobLogURL
            ),
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            source: "manual",
            title: "Short recording",
            autoStopDisabled: false
        )

        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: session.jobId,
                meetingId: session.jobId,
                status: "summarizing",
                stage: .summarizing,
                source: "manual",
                createdAt: session.startedAt,
                updatedAt: session.startedAt
            )
        )

        let orchestrator = PipelineOrchestrator(
            jobRepository: jobRepository,
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            transcriptionService: TranscriptionService(),
            transcriptMergeService: TranscriptMergeService(),
            summarizationService: SummarizationService(
                keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
                session: SummarizationServiceTests.mockSession { request in
                    XCTFail("Summary provider should not be called for short transcripts: \(request)")
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                },
                sleep: { _ in }
            ),
            finalizationService: FinalizationService(
                storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
                jobRepository: jobRepository,
                loggingService: LoggingService(),
                appStateDidChange: { _ in },
                ffmpegURLResolver: { try FinalizationServiceTests.stubExecutable(named: "ffmpeg", in: rootURL, contents: FinalizationServiceTests.ffmpegScript) },
                zipURLResolver: { try FinalizationServiceTests.stubExecutable(named: "zip", in: rootURL, contents: FinalizationServiceTests.zipScript) },
                durationResolver: { _ in 60 }
            ),
            loggingService: LoggingService(),
            appStateDidChange: { _ in }
        )

        await orchestrator.run(session: session, startingAt: .summarizing)

        let persistedJob = await jobRepository.get(id: session.jobId)
        let job = try XCTUnwrap(persistedJob)
        XCTAssertEqual(job.status, "completed")
        XCTAssertEqual(job.stage, .completed)
        XCTAssertFalse(fileManager.fileExists(atPath: folderURL.appendingPathComponent("summary.md").path))

        let jobLog = try String(contentsOf: jobLogURL, encoding: .utf8)
        XCTAssertTrue(jobLog.contains("Summary skipped: transcript has only 14 words; minimum is 30."))
    }

    func testRecordingAdapterWatchdogMarksHungRecorderFailed() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let stateRecorder = AppStateRecorder()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { state in
                await stateRecorder.record(state)
            },
            recorderFactory: { paths in
                try HungRecorder(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
            },
            watchdogPollInterval: 0.05,
            watchdogHungInterval: 0.2,
            watchdogKillGracePeriod: 0.05
        )

        _ = try await adapter.start(jobId: "job-recorder-hung")

        let deadline = Date().addingTimeInterval(5)
        var job: Job?
        while Date() < deadline {
            job = await jobRepository.get(id: "job-recorder-hung")
            if job?.status == "failed" {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let failedJob = try XCTUnwrap(job)
        XCTAssertEqual(failedJob.status, "failed")
        XCTAssertEqual(failedJob.error?.code, "recorder_hung")
        let activeSession = await adapter.activeSession
        XCTAssertNil(activeSession)
        let lastState = await stateRecorder.lastState()
        XCTAssertEqual(lastState, .error)
    }

    func testRecordingAdapterStopsSuccessfullyWhenRecorderAlreadyStoppedButOutputsExist() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                AlreadyStoppedRecorder(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
            },
            fileManager: fileManager
        )

        _ = try await adapter.start(jobId: "job-already-stopped")
        let session = try await adapter.stop()

        XCTAssertEqual(session.jobId, "job-already-stopped")
        let persistedJob = await jobRepository.get(id: "job-already-stopped")
        let job = try XCTUnwrap(persistedJob)
        XCTAssertEqual(job.status, "recorded")
        XCTAssertEqual(job.stage, .recorded)
        let activeSession = await adapter.activeSession
        XCTAssertNil(activeSession)
    }

    func testRecordingAdapterFailsWhenMicrophoneTrackIsMuchShorterThanSystemTrack() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                TruncatedMicrophoneRecorder(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
            },
            fileManager: fileManager
        )

        let session = try await adapter.start(jobId: "job-truncated-mic")

        do {
            _ = try await adapter.stop()
            XCTFail("Expected truncated microphone output to fail recording validation.")
        } catch let error as RecordingOutputInvalidError {
            XCTAssertTrue(error.localizedDescription.contains("Microphone recording is much shorter"))
        }

        let persistedJob = await jobRepository.get(id: "job-truncated-mic")
        let job = try XCTUnwrap(persistedJob)
        XCTAssertEqual(job.status, "failed")
        XCTAssertEqual(job.stage, .recording)
        XCTAssertTrue(fileManager.fileExists(atPath: session.paths.systemWavURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: session.paths.micWavURL.path))
    }

    func testRecordingAdapterContinuesWhenMicrophoneDegradesAndRestartFails() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let recorder = DegradingMicrophoneRecorder()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                recorder.configure(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
                return recorder
            },
            fileManager: fileManager,
            watchdogPollInterval: 0.05,
            watchdogHungInterval: 0.2
        )

        _ = try await adapter.start(jobId: "job-microphone-degraded")

        let deadline = Date().addingTimeInterval(5)
        var degradedJob: Job?
        while Date() < deadline {
            degradedJob = await jobRepository.get(id: "job-microphone-degraded")
            if degradedJob?.warnings.contains(where: { $0.contains("microphone_degraded") }) == true {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertTrue(degradedJob?.warnings.contains(where: { $0.contains("microphone_degraded") }) == true)
        XCTAssertEqual(recorder.restartAttempts, 1)
        XCTAssertFalse(recorder.padDurations.isEmpty)

        let session = try await adapter.stop()
        XCTAssertTrue(session.microphoneDegraded)
        XCTAssertTrue(session.recordingWarnings.contains(where: { $0.contains("microphone_degraded") }))
        XCTAssertGreaterThanOrEqual(recorder.padDurations.count, 2)

        let persistedRecordedJob = await jobRepository.get(id: "job-microphone-degraded")
        let recordedJob = try XCTUnwrap(persistedRecordedJob)
        XCTAssertEqual(recordedJob.status, "recorded")
        XCTAssertEqual(recordedJob.stage, .recorded)
        XCTAssertTrue(recordedJob.warnings.contains(where: { $0.contains("microphone_degraded") }))
        XCTAssertTrue(fileManager.fileExists(atPath: session.paths.systemWavURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: session.paths.micWavURL.path))
    }

    func testRecordingAdapterRestartsMicrophoneAndSystemAudioWhenInputDeviceChanges() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let recorder = SwitchingMicrophoneRecorder()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                recorder.configure(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
                return recorder
            },
            fileManager: fileManager,
            watchdogPollInterval: 0.05,
            watchdogHungInterval: 5
        )

        _ = try await adapter.start(jobId: "job-microphone-device-switch")

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if recorder.restartAttempts > 0 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(recorder.restartAttempts, 1)
        XCTAssertEqual(recorder.systemRestartAttempts, 1)
        XCTAssertFalse(recorder.padDurations.isEmpty)

        let session = try await adapter.stop()
        XCTAssertFalse(session.microphoneDegraded)
        XCTAssertTrue(session.recordingWarnings.isEmpty)
    }

    func testRecordingAdapterRestartsSystemAudioWhenStreamStopsUnexpectedly() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        let jobRepository = InMemoryJobRepository()
        let recorder = InterruptingSystemRecorder()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(logsDirectoryURL: logsURL),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                recorder.configure(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
                return recorder
            },
            fileManager: fileManager
        )

        _ = try await adapter.start(jobId: "job-system-stream-stop")
        recorder.triggerUnexpectedSystemStop(reason: "ReplayKit connection invalidated")

        let deadline = Date().addingTimeInterval(5)
        var persistedJob: Job?
        while Date() < deadline {
            if recorder.systemRestartAttempts > 0 {
                persistedJob = await jobRepository.get(id: "job-system-stream-stop")
                if persistedJob?.warnings.contains(where: { $0.contains("system_audio_restarted") }) == true {
                    break
                }
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(recorder.systemRestartAttempts, 1)
        let recordingJob = try XCTUnwrap(persistedJob)
        XCTAssertEqual(recordingJob.status, "recording")
        XCTAssertTrue(recordingJob.warnings.contains { $0.contains("system_audio_restarted") })

        let appLog = try String(
            contentsOf: logsURL.appendingPathComponent("app.log", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(appLog.contains("System audio stream stopped unexpectedly for job job-system-stream-stop; attempting automatic restart 1/3"))
        XCTAssertTrue(appLog.contains("Restarted system audio capture for job job-system-stream-stop after unexpected ScreenCaptureKit stream stop"))

        let session = try await adapter.stop()
        XCTAssertTrue(session.recordingWarnings.contains { $0.contains("system_audio_restarted") })
    }

    func testRecordingAdapterNotifiesWhenSystemAudioRestartFails() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        let jobRepository = InMemoryJobRepository()
        let recorder = InterruptingSystemRecorder(
            restartError: RecordingOutputInvalidError(message: "test system restart failed")
        )
        let notificationRecorder = NotificationRecorder()
        let settings = AppSettings.default
        let notificationService = NotificationService(
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            inAppNotificationStore: InAppNotificationStore(),
            permissionService: PermissionService(),
            loggingService: LoggingService(logsDirectoryURL: logsURL),
            checkPermissionStatus: { .granted },
            requestPermissionStatus: { .granted },
            deliver: { title, body in
                await notificationRecorder.record(category: "system", title: title, body: body)
            }
        )
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(logsDirectoryURL: logsURL),
            appStateDidChange: { _ in },
            notificationService: notificationService,
            recorderFactory: { paths in
                recorder.configure(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
                return recorder
            },
            fileManager: fileManager
        )

        _ = try await adapter.start(jobId: "job-system-stream-failed")
        recorder.triggerUnexpectedSystemStop(reason: "ReplayKit connection invalidated")

        let deadline = Date().addingTimeInterval(5)
        var persistedJob: Job?
        while Date() < deadline {
            persistedJob = await jobRepository.get(id: "job-system-stream-failed")
            let deliveredNotification = await notificationRecorder.currentValue()
            if persistedJob?.warnings.contains(where: { $0.contains("system_audio_degraded") }) == true,
               deliveredNotification != nil {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertEqual(recorder.systemRestartAttempts, 1)
        let latestNotification = await notificationRecorder.currentValue()
        let notification = try XCTUnwrap(latestNotification)
        XCTAssertEqual(notification.body, String(localized: "System audio recording failed. Microphone recording continues."))

        let recordingJob = try XCTUnwrap(persistedJob)
        XCTAssertEqual(recordingJob.status, "recording")
        XCTAssertTrue(recordingJob.warnings.contains { $0.contains("system_audio_degraded") })

        let appLog = try String(
            contentsOf: logsURL.appendingPathComponent("app.log", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(appLog.contains("Automatic system audio restart failed for job job-system-stream-failed"))
        XCTAssertTrue(appLog.contains("Notified user that system audio recording failed for job job-system-stream-failed"))

        _ = try await adapter.stop()
    }

    func testRecordingAdapterWarnsWhenSystemAudioLooksMostlySilent() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                SilentSystemRecorder(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
            },
            fileManager: fileManager
        )

        _ = try await adapter.start(jobId: "job-silent-system-audio")
        let session = try await adapter.stop()

        XCTAssertTrue(session.recordingWarnings.contains { $0.contains("system_audio_degraded") })
        let persistedJob = await jobRepository.get(id: "job-silent-system-audio")
        let recordedJob = try XCTUnwrap(persistedJob)
        XCTAssertEqual(recordedJob.status, "recorded")
        XCTAssertTrue(recordedJob.warnings.contains { $0.contains("system_audio_degraded") })
    }

    func testRecordingAdapterDoesNotWarnWhenMicrophoneExplainsSystemSilence() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let jobRepository = InMemoryJobRepository()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: jobRepository,
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                SilentSystemWithActiveMicrophoneRecorder(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
            },
            fileManager: fileManager
        )

        _ = try await adapter.start(jobId: "job-system-silent-mic-active")
        let session = try await adapter.stop()

        XCTAssertFalse(session.recordingWarnings.contains { $0.contains("system_audio_degraded") })
        let persistedJob = await jobRepository.get(id: "job-system-silent-mic-active")
        let recordedJob = try XCTUnwrap(persistedJob)
        XCTAssertEqual(recordedJob.status, "recorded")
        XCTAssertFalse(recordedJob.warnings.contains { $0.contains("system_audio_degraded") })
    }

    func testRecordingAdapterTogglesMicrophonePause() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let recorder = PausableRecorder()
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            jobRepository: InMemoryJobRepository(),
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            recorderFactory: { paths in
                recorder.configure(systemURL: paths.systemWavURL, micURL: paths.micWavURL)
                return recorder
            },
            fileManager: fileManager
        )

        _ = try await adapter.start(jobId: "job-mic-pause")

        let initiallyPaused = await adapter.isMicrophonePaused()
        XCTAssertFalse(initiallyPaused)
        let pausedSession = try await adapter.setMicrophonePaused(true)
        XCTAssertTrue(pausedSession.microphonePaused)
        let paused = await adapter.isMicrophonePaused()
        XCTAssertTrue(paused)

        let resumedSession = try await adapter.setMicrophonePaused(false)
        XCTAssertFalse(resumedSession.microphonePaused)
        let resumed = await adapter.isMicrophonePaused()
        XCTAssertFalse(resumed)
        XCTAssertEqual(recorder.pausedStates, [true, false])

        try await adapter.setMicrophoneDeviceUID("usb-microphone")
        XCTAssertEqual(recorder.selectedMicrophoneUIDs, ["usb-microphone"])
    }

    func testPipelineCompletedNotifiesBriefReady() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let folderURL = rootURL.appendingPathComponent("job-success_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)

        let transcript = "Speaker A: shipped notification support with recording pipeline diagnostics summary alerts transcript packaging audio conversion retry handling status updates and user notifications for completed meeting briefs with reliable delivery checks and dashboard refresh behavior"
        try transcript.write(
            to: folderURL.appendingPathComponent("transcript.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try JSONEncoder().encode([
            TranscriptSegment(startTime: 0, endTime: 60, speaker: "Speaker A", text: transcript, sourceTrack: .mic),
        ]).write(
            to: folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        )
        try Data("wav".utf8).write(to: tmpURL.appendingPathComponent("system.wav", isDirectory: false))
        try Data("wav".utf8).write(to: tmpURL.appendingPathComponent("mic.wav", isDirectory: false))
        try Data().write(to: rootURL.appendingPathComponent("job-success.log", isDirectory: false))

        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        let session = RecordingSession(
            jobId: "job-success",
            pid: 0,
            paths: MeetingPaths(
                folderURL: folderURL,
                tmpURL: tmpURL,
                systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
                micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
                jobLogURL: rootURL.appendingPathComponent("job-success.log", isDirectory: false)
            ),
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            source: "manual",
            title: "Manual recording",
            autoStopDisabled: false,
            autoStopAt: nil
        )

        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: session.jobId,
                meetingId: session.jobId,
                status: "summarizing",
                stage: .summarizing,
                source: "manual",
                createdAt: session.startedAt,
                updatedAt: session.startedAt
            )
        )

        let notificationRecorder = NotificationRecorder()
        let orchestrator = PipelineOrchestrator(
            jobRepository: jobRepository,
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            transcriptionService: TranscriptionService(),
            transcriptMergeService: TranscriptMergeService(),
            summarizationService: SummarizationService(
                keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
                session: SummarizationServiceTests.mockSession { request in
                    (
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                        "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"## Summary\\nReady\"}}]}".data(using: .utf8)!
                    )
                },
                sleep: { _ in }
            ),
            finalizationService: FinalizationService(
                storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
                jobRepository: jobRepository,
                loggingService: LoggingService(),
                appStateDidChange: { _ in },
                ffmpegURLResolver: { try FinalizationServiceTests.stubExecutable(named: "ffmpeg", in: rootURL, contents: FinalizationServiceTests.ffmpegScript) },
                zipURLResolver: { try FinalizationServiceTests.stubExecutable(named: "zip", in: rootURL, contents: FinalizationServiceTests.zipScript) },
                durationResolver: { _ in 60 }
            ),
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            notifyUser: { category, title, body in
                await notificationRecorder.record(category: category, title: title, body: body)
            }
        )

        await orchestrator.run(session: session, startingAt: .summarizing)

        let notification = await notificationRecorder.currentValue()
        XCTAssertEqual(notification?.category, NotificationService.Category.summaryReady.rawValue)
        XCTAssertEqual(notification?.body, String(localized: "Your brief is ready"))
    }

    func testRecordingAdapterNotifiesStartAndPreEndForCalendarRecording() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)

        let recorderScriptURL = binURL.appendingPathComponent("recorder", isDirectory: false)
        try FinalizationServiceTests.writeExecutable(
            """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --system-out)
                  shift
                  system_out="$1"
                  ;;
                --mic-out)
                  shift
                  mic_out="$1"
                  ;;
              esac
              shift
            done
            printf 'system' > "$system_out"
            printf 'mic' > "$mic_out"
            sleep 1000
            """,
            to: recorderScriptURL
        )

        var settings = AppSettings.default
        settings.automation.calendarAutopilotSettings.preEndNotificationSec = 1
        let notificationRecorder = NotificationRecorder()
        let notificationService = NotificationService(
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            inAppNotificationStore: InAppNotificationStore(),
            permissionService: PermissionService(),
            loggingService: LoggingService(),
            checkPermissionStatus: { .granted },
            requestPermissionStatus: { .granted },
            deliver: { title, body in
                await notificationRecorder.record(category: "system", title: title, body: body)
            }
        )
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            jobRepository: InMemoryJobRepository(),
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            notificationService: notificationService,
            recorderURLResolver: { recorderScriptURL },
            fileManager: fileManager
        )

        let autoStopAt = Date().addingTimeInterval(1.2)
        _ = try await adapter.start(
            jobId: "job-calendar",
            source: "calendar",
            title: "Calendar meeting",
            autoStopAt: autoStopAt
        )

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await notificationRecorder.values().count >= 2 {
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        let notifications = await notificationRecorder.values()
        XCTAssertEqual(
            notifications.map(\.body),
            [
                String(localized: "Recording started"),
                String(localized: "Recording will stop in 2 minutes")
            ]
        )

        _ = try await adapter.cancel(jobId: "job-calendar")
    }

    func testRecordingAdapterCancelsPreEndNotificationWhenAutoStopDisabled() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)

        let recorderScriptURL = binURL.appendingPathComponent("recorder", isDirectory: false)
        try FinalizationServiceTests.writeExecutable(
            """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
              case "$1" in
                --system-out)
                  shift
                  system_out="$1"
                  ;;
                --mic-out)
                  shift
                  mic_out="$1"
                  ;;
              esac
              shift
            done
            printf 'system' > "$system_out"
            printf 'mic' > "$mic_out"
            sleep 1000
            """,
            to: recorderScriptURL
        )

        var settings = AppSettings.default
        settings.automation.calendarAutopilotSettings.preEndNotificationSec = 1
        let notificationRecorder = NotificationRecorder()
        let notificationService = NotificationService(
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            inAppNotificationStore: InAppNotificationStore(),
            permissionService: PermissionService(),
            loggingService: LoggingService(),
            checkPermissionStatus: { .granted },
            requestPermissionStatus: { .granted },
            deliver: { title, body in
                await notificationRecorder.record(category: "system", title: title, body: body)
            }
        )
        let adapter = RecordingAdapter(
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: rootURL),
            appSettingsStore: FixedAppSettingsStore(settings: settings),
            jobRepository: InMemoryJobRepository(),
            loggingService: LoggingService(),
            appStateDidChange: { _ in },
            notificationService: notificationService,
            recorderURLResolver: { recorderScriptURL },
            fileManager: fileManager
        )

        _ = try await adapter.start(
            jobId: "job-calendar-disable",
            source: "calendar",
            title: "Calendar meeting",
            autoStopAt: Date().addingTimeInterval(1.2)
        )
        _ = try await adapter.disableAutoStop()
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let notifications = await notificationRecorder.values()
        XCTAssertEqual(notifications.map(\.body), [String(localized: "Recording started")])

        _ = try await adapter.cancel(jobId: "job-calendar-disable")
    }
}

private final class HungRecorder: AudioRecording {
    private let systemURL: URL
    private let micURL: URL

    init(systemURL: URL, micURL: URL) throws {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try Data("system".utf8).write(to: systemURL)
        try Data("mic".utf8).write(to: micURL)
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }
}

private final class AlreadyStoppedRecorder: AudioRecording {
    private let systemURL: URL
    private let micURL: URL

    init(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try Data("system".utf8).write(to: systemURL)
        try Data("mic".utf8).write(to: micURL)
    }

    func stop() async throws {
        throw RecorderAlreadyStoppedError(message: "Recorder had already stopped.")
    }

    func setMicrophonePaused(_ paused: Bool) throws {}

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }
}

private final class TruncatedMicrophoneRecorder: AudioRecording {
    private let systemURL: URL
    private let micURL: URL

    init(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try Self.writeSilentWav(to: systemURL, seconds: 130)
        try Self.writeSilentWav(to: micURL, seconds: 10)
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }

    fileprivate static func writeSilentWav(to url: URL, seconds: Int) throws {
        let sampleRate = 16_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RecordingOutputInvalidError(message: "Unable to create test audio format.")
        }
        let frameCount = AVAudioFrameCount(seconds * Int(sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw RecordingOutputInvalidError(message: "Unable to create test audio buffer.")
        }
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    fileprivate static func writeToneWav(to url: URL, seconds: Int) throws {
        let sampleRate = 16_000.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw RecordingOutputInvalidError(message: "Unable to create test audio format.")
        }
        let frameCount = AVAudioFrameCount(seconds * Int(sampleRate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else {
            throw RecordingOutputInvalidError(message: "Unable to create test audio buffer.")
        }
        buffer.frameLength = frameCount
        for frame in 0..<Int(frameCount) {
            channel[frame] = sin(Float(frame) * 0.05) * 0.08
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}

private final class SilentSystemRecorder: AudioRecording {
    private let systemURL: URL
    private let micURL: URL

    init(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try TruncatedMicrophoneRecorder.writeSilentWav(to: systemURL, seconds: 130)
        try TruncatedMicrophoneRecorder.writeSilentWav(to: micURL, seconds: 130)
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }
}

private final class SilentSystemWithActiveMicrophoneRecorder: AudioRecording {
    private let systemURL: URL
    private let micURL: URL

    init(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try TruncatedMicrophoneRecorder.writeSilentWav(to: systemURL, seconds: 130)
        try TruncatedMicrophoneRecorder.writeToneWav(to: micURL, seconds: 130)
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }
}

private final class DegradingMicrophoneRecorder: AudioRecording {
    private var systemURL: URL?
    private var micURL: URL?
    private let lock = NSLock()
    private var systemFrames: Int64 = 16_000
    private var micFrames: Int64 = 16_000
    private(set) var restartAttempts = 0
    private(set) var padDurations: [TimeInterval] = []

    func configure(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try TruncatedMicrophoneRecorder.writeSilentWav(to: try XCTUnwrap(systemURL), seconds: 130)
        try TruncatedMicrophoneRecorder.writeSilentWav(to: try XCTUnwrap(micURL), seconds: 10)
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func restartMicrophoneCapture() throws {
        lock.lock()
        restartAttempts += 1
        lock.unlock()
        throw RecordingOutputInvalidError(message: "test microphone restart failed")
    }

    func padMicrophoneSilence(toDuration duration: TimeInterval) throws {
        lock.lock()
        padDurations.append(duration)
        lock.unlock()
    }

    func microphoneDiagnosticDescription() -> String {
        "Test Microphone [test-device]"
    }

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }

    func outputActivity() -> AudioOutputActivity? {
        lock.lock()
        systemFrames += 16_000
        let snapshot = AudioOutputActivity(
            systemFramesWritten: systemFrames,
            microphoneFramesWritten: micFrames
        )
        lock.unlock()
        return snapshot
    }
}

private final class SwitchingMicrophoneRecorder: AudioRecording {
    private var systemURL: URL?
    private var micURL: URL?
    private let lock = NSLock()
    private var systemFrames: Int64 = 16_000
    private var micFrames: Int64 = 16_000
    private var activityPolls = 0
    private var didSwitchInputDevice = false
    private(set) var restartAttempts = 0
    private(set) var systemRestartAttempts = 0
    private(set) var padDurations: [TimeInterval] = []

    func configure(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try TruncatedMicrophoneRecorder.writeSilentWav(to: try XCTUnwrap(systemURL), seconds: 2)
        try TruncatedMicrophoneRecorder.writeSilentWav(to: try XCTUnwrap(micURL), seconds: 2)
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func restartMicrophoneCapture() throws {
        lock.lock()
        restartAttempts += 1
        lock.unlock()
    }

    func restartSystemAudioCapture() async throws {
        systemRestartAttempts += 1
    }

    func padMicrophoneSilence(toDuration duration: TimeInterval) throws {
        lock.lock()
        padDurations.append(duration)
        lock.unlock()
    }

    func microphoneDiagnosticDescription() -> String {
        lock.lock()
        defer { lock.unlock() }
        return didSwitchInputDevice
            ? "AirPods Pro [test-airpods-input]"
            : "MacBook Pro Microphone [test-built-in-input]"
    }

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }

    func outputActivity() -> AudioOutputActivity? {
        lock.lock()
        activityPolls += 1
        if activityPolls >= 3 {
            didSwitchInputDevice = true
        }
        systemFrames += 16_000
        micFrames += 16_000
        let snapshot = AudioOutputActivity(
            systemFramesWritten: systemFrames,
            microphoneFramesWritten: micFrames
        )
        lock.unlock()
        return snapshot
    }
}

private final class InterruptingSystemRecorder: AudioRecording {
    private var systemURL: URL?
    private var micURL: URL?
    private let lock = NSLock()
    private let restartError: Error?
    private var interruptionHandler: (@Sendable (String) -> Void)?
    private var _systemRestartAttempts = 0

    init(restartError: Error? = nil) {
        self.restartError = restartError
    }

    var systemRestartAttempts: Int {
        lock.lock()
        defer { lock.unlock() }
        return _systemRestartAttempts
    }

    func configure(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try Data("system".utf8).write(to: try XCTUnwrap(systemURL))
        try Data("mic".utf8).write(to: try XCTUnwrap(micURL))
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {}

    func setSystemAudioInterruptionHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        interruptionHandler = handler
        lock.unlock()
    }

    func restartSystemAudioCapture() async throws {
        incrementRestartAttempts()
        if let restartError {
            throw restartError
        }
    }

    private func incrementRestartAttempts() {
        lock.lock()
        _systemRestartAttempts += 1
        lock.unlock()
    }

    func triggerUnexpectedSystemStop(reason: String) {
        lock.lock()
        let handler = interruptionHandler
        lock.unlock()
        handler?(reason)
    }

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }
}

private final class PausableRecorder: AudioRecording {
    private var systemURL: URL?
    private var micURL: URL?
    private(set) var pausedStates: [Bool] = []
    private(set) var selectedMicrophoneUIDs: [String?] = []

    func configure(systemURL: URL, micURL: URL) {
        self.systemURL = systemURL
        self.micURL = micURL
    }

    func start() async throws {
        try Data("system".utf8).write(to: try XCTUnwrap(systemURL))
        try Data("mic".utf8).write(to: try XCTUnwrap(micURL))
    }

    func stop() async throws {}

    func setMicrophonePaused(_ paused: Bool) throws {
        pausedStates.append(paused)
    }

    func setMicrophoneDeviceUID(_ uid: String?) throws {
        selectedMicrophoneUIDs.append(uid)
    }

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }
}
