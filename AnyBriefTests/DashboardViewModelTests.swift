import XCTest
import SwiftUI
import AVFoundation
@testable import AnyBrief

/// Tests dashboard activity timing for the current pipeline stage.
final class DashboardViewModelTests: XCTestCase {
    @MainActor
    func testMicrophonePauseUpdatesImmediatelyAndAppliesRequestedState() async throws {
        let recorder = MicrophonePauseRecorder()
        let model = DashboardViewModel(
            appStateProvider: { .recording },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            applyMicrophonePauseAction: { paused in
                await recorder.record(paused)
            },
            launchAtLoginController: TestLaunchAtLoginController()
        )

        XCTAssertFalse(model.isMicrophonePaused)
        model.toggleMicrophonePause()

        XCTAssertTrue(model.isMicrophonePaused, "The recording UI should respond without waiting for its periodic refresh")
        XCTAssertTrue(model.isUpdatingMicrophonePause)

        for _ in 0..<50 where model.isUpdatingMicrophonePause {
            try await Task.sleep(for: .milliseconds(10))
        }
        let appliedValues = await recorder.values
        XCTAssertFalse(model.isUpdatingMicrophonePause)
        XCTAssertEqual(appliedValues, [true])
    }

    @MainActor
    func testRuntimeRecordingStateUpdatesWithoutWaitingForPeriodicRefresh() {
        let model = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let session = RecordingSession(
            jobId: "runtime-recording",
            pid: 1,
            paths: MeetingPaths(
                folderURL: folder,
                tmpURL: folder.appendingPathComponent("tmp"),
                systemWavURL: folder.appendingPathComponent("system.wav"),
                micWavURL: folder.appendingPathComponent("mic.wav"),
                jobLogURL: folder.appendingPathComponent("job.log")
            ),
            startedAt: Date(),
            source: "manual",
            title: "Runtime recording",
            autoStopDisabled: false,
            microphonePaused: true
        )

        model.startRecording()
        XCTAssertTrue(model.isStartingRecording)
        XCTAssertFalse(model.canStartRecording)

        model.applyRuntimeState(.recording, currentSession: session)
        XCTAssertFalse(model.isStartingRecording)
        XCTAssertEqual(model.recordingActivity?.jobId, session.jobId)
        XCTAssertTrue(model.isMicrophonePaused)

        model.isStoppingRecording = true
        model.applyRuntimeState(.processing, currentSession: nil)
        XCTAssertNil(model.recordingActivity)
        XCTAssertFalse(model.isStoppingRecording)
        XCTAssertEqual(model.effectiveAppState, .processing)
    }

    @MainActor
    func testCalendarStartPreservesSelectedEventAndPreventsDuplicateRequests() async throws {
        let event = CalendarEvent(uid: "past-event", originalUID: "series", calendarName: "Work", title: "Moved meeting",
            startAt: Date(timeIntervalSinceNow: -7200), endAt: Date(timeIntervalSinceNow: -3600),
            timeZone: "UTC", location: nil, notes: "Agenda", organizer: nil, attendees: [], meetingURLs: [],
            participantCount: 3, hasMeetingURL: false, recurrenceRule: nil, recurrenceID: nil)
        let row = DashboardViewModel.AutopilotScheduleEvent(id: event.uid, title: event.title,
            startAt: event.startAt, endAt: event.endAt, participantCount: event.participantCount,
            hasMeetingURL: false, meetingURL: nil, originalUID: event.originalUID, isRecurring: false,
            autopilotEnabled: false, calendarEvent: event)
        var received: [CalendarEvent] = []
        let model = DashboardViewModel(appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {},
            startCalendarRecordingAction: { received.append($0) }, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController())
        model.activities = [.init(jobId: "older", status: "processing", stage: JobStage.summarizing.rawValue,
            startedAt: Date(), duration: 0, detail: nil)]
        XCTAssertTrue(model.canStartRecording(for: row), "Past events without a URL or autopilot remain recordable during processing")
        model.startRecording(for: row)
        XCTAssertFalse(model.canStartRecording(for: row))
        model.startRecording(for: row)
        for _ in 0..<100 where model.isStartingCalendarRecording {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(received, [event])
        XCTAssertFalse(model.isStartingCalendarRecording)
        model.activities = [.init(jobId: "new", status: "recording", stage: JobStage.recording.rawValue,
            startedAt: Date(), duration: 0, detail: nil)]
        XCTAssertFalse(model.canStartRecording(for: row))
    }

    @MainActor
    func testRecordingWorkspaceFitsMinimumWindowAndKeepsSignalHeightStable() async throws {
        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.prompts.transcriptCleanup.enabled = true
        settings.llm.connections = ["Codex", "Claude", "Ollama", "Team API"].map {
            SummaryProviderConfiguration(id: $0, provider: .commandLine, name: $0)
        }
        settings.postProcessing.rules = [PostProcessingRuleConfiguration(title: "Weekly notes", calendarTitlePattern: "Weekly",
            destinationFolderPath: "/Example/Shared folders/Team documents/Projects/Research/Weekly meeting notes and decisions", exportContent: .both)]
        let model = DashboardViewModel(appStateProvider: { .recording },
            jobRepository: TestJobRepository(), appSettingsStore: TestAppSettingsStore(settings: settings),
            keychainStore: TestKeychainStore(values: [:]), permissionService: PermissionService(),
            storageService: TestDashboardStorageService(), loggingService: LoggingService(),
            startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController())
        model.activities = [.init(jobId: "layout", status: "recording", stage: JobStage.recording.rawValue, startedAt: Date(), duration: 3665, detail: nil)]
        model.recentMeetings = [.init(id: "layout", title: "Weekly planning — product launch and customer research", timestamp: Date(), status: "recording",
            folderURL: FileManager.default.temporaryDirectory, summaryURL: nil, jobId: "layout", needsFolderRename: false)]
        model.recordingProcessingPlan = RecordingProcessingPlan(jobID: "layout", settings: settings, meetingTitle: "Weekly planning", exportTitle: "Weekly planning",
            transcriptionRegistry: .default, summaryRegistry: .default)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 580), styleMask: [.titled], backing: .buffered, defer: false)
        let originalAppearance = NSApp.appearance
        defer { window.orderOut(nil); window.contentViewController = nil; NSApp.appearance = originalAppearance }
        func scrollViews(in view: NSView) -> [NSScrollView] {
            (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews(in: $0) }
        }
        for dark in [false, true] {
            model.appearanceSelection = dark ? .dark : .light
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            for expanded in [false, true] {
                let controller = NSHostingController(rootView: DashboardView(viewModel: model, notificationStore: InAppNotificationStore(),
                    selectedPane: .status, recordingPlanExpanded: expanded)
                    .frame(width: 900, height: 580).environment(\.colorScheme, dark ? .dark : .light))
                window.contentViewController = controller
                window.setContentSize(NSSize(width: 900, height: 580))
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(200))
                let view = controller.view
                view.layoutSubtreeIfNeeded()
                let scrollers = scrollViews(in: view)
                XCTAssertFalse(scrollers.isEmpty, "Recording workspace should retain scrolling for expanded details")
                for scroller in scrollers {
                    let document = try XCTUnwrap(scroller.documentView)
                    if !expanded {
                        XCTAssertLessThanOrEqual(document.bounds.height, scroller.contentView.bounds.height + 1,
                            "Collapsed recording screen must fit the minimum window")
                        XCTAssertLessThanOrEqual(document.bounds.width, scroller.contentView.bounds.width + 1)
                    } else {
                        XCTAssertGreaterThan(document.bounds.height, scroller.contentView.bounds.height,
                            "Expanded plan must expose all details, including long export paths")
                    }
                    let silentHeight = document.bounds.height
                    model.audioLevelStore.update(AudioLevelSnapshot(system: 1, microphone: 1))
                    try await Task.sleep(for: .milliseconds(60))
                    view.layoutSubtreeIfNeeded()
                    XCTAssertEqual(document.bounds.height, silentHeight, accuracy: 1, "Changing audio levels must not move layout")
                }
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let language = Bundle.main.preferredLocalizations.first ?? "en"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to:
                    URL(fileURLWithPath: "/private/tmp/anybrief-recording-\(language)-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "compact").png"))
                model.audioLevelStore.reset()
            }
        }
    }

    @MainActor
    func testImportDialogLayoutInBothAppearances() async throws {
        let model = DashboardViewModel(appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController())
        let original = NSApp.appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentViewController = nil; NSApp.appearance = original }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let controller = NSHostingController(rootView: MeetingImportSheet(viewModel: model, completed: { _ in })
                .background(WorkspaceDesign.surface).environment(\.colorScheme, dark ? .dark : .light))
            window.contentViewController = controller
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            let view = controller.view
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-import-\(dark ? "dark" : "light").png"))
        }
    }

    @MainActor
    func testManualSummaryUsesSavedSettingsAndClearsFallbackError() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "[00:00:01] Speaker: Review tomorrow.".write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try "---\nstatus: partial_success\nsummary_error: summary_api_failed\n---\nOld fallback"
            .write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        var settings = AppSettings.default
        settings.summary.enabled = false
        settings.llm.connections = [SummarizationServiceTests.openAIConfiguration(model: "saved-model", apiKeyRef: "test-key")]
        let keys = TestKeychainStore(values: ["test-key": "test-value"])
        let session = SummarizationServiceTests.mockSession { request in
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "saved-model")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"choices":[{"message":{"role":"assistant","content":"Fresh summary"}}]}"#.utf8))
        }
        let model = DashboardViewModel(appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings), keychainStore: keys,
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            summarizationService: SummarizationService(keychainStore: keys, session: session),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController())
        // Unsaved empty form values must not override the connection used by guidance.
        model.summaryProviderEntries = []
        model.promptItems = []
        let meeting = DashboardViewModel.RecentMeeting(id: "meeting", title: "Test", timestamp: nil, status: "partial_success",
            folderURL: folder, summaryURL: folder.appendingPathComponent("summary.md"), jobId: nil, needsFolderRename: false)
        let finished = expectation(description: "Manual summary finished")
        var wasRunning = false
        let subscription = model.$resummarizingMeetingIds.sink { ids in
            if ids.contains(meeting.id) { wasRunning = true }
            else if wasRunning { wasRunning = false; finished.fulfill() }
        }
        model.repeatSummary(meeting)
        await fulfillment(of: [finished], timeout: 5)
        withExtendedLifetime(subscription) {}
        let content = MeetingReaderFiles.documents(in: folder)
        XCTAssertTrue(content.summary.contains("Fresh summary"))
        XCTAssertFalse(content.hasSummaryFailure)
        XCTAssertEqual(model.summaryActionMeetingID, meeting.id)
        XCTAssertFalse(model.summaryActionMessageIsError)
    }

    func testRecordingHintsPrioritizeBlockingSetupAndDisappearWhenConfigured() {
        func snapshot(permissions: Bool = true, transcription: Bool = true, summary: SummarySetupState = .configured) -> SetupReadinessSnapshot {
            SetupReadinessSnapshot(microphoneGranted: permissions, screenRecordingGranted: permissions,
                transcription: TranscriptionDiagnosticResult(status: transcription ? .success : .failure, message: ""), summary: summary)
        }
        XCTAssertEqual(RecordingSetupHint(snapshot: snapshot(permissions: false, transcription: false, summary: .noConnection)), .permissions)
        XCTAssertEqual(RecordingSetupHint(snapshot: snapshot(transcription: false, summary: .noConnection)), .transcription)
        XCTAssertEqual(RecordingSetupHint(snapshot: snapshot(summary: .noConnection)), .llm)
        XCTAssertEqual(RecordingSetupHint(snapshot: snapshot(summary: .disabled)), .automaticSummary)
        XCTAssertEqual(RecordingSetupHint(snapshot: snapshot(summary: .missingPrompt)), .prompt)
        XCTAssertNil(RecordingSetupHint(snapshot: snapshot()))
    }

    func testManualSummaryAvailabilityUsesMeetingPromptAndAllowsAutoSummaryOff() {
        var settings = AppSettings.default
        settings.summary.enabled = false
        settings.llm.connections = [SummaryProviderConfiguration(id: "saved")]
        settings.prompts.items = [PromptItem(id: "general", text: "Summarize"),
                                 PromptItem(id: "matched", text: "  ", titlePatterns: ["Special"])]
        settings.prompts.summary.promptID = "general"
        XCTAssertEqual(ManualSummaryAvailability(settings: settings, meetingTitle: "Meeting"), .ready)
        XCTAssertEqual(ManualSummaryAvailability(settings: settings, meetingTitle: "Special meeting"), .missingPrompt)
        settings.llm.connections[0].enabled = false
        XCTAssertEqual(ManualSummaryAvailability(settings: settings, meetingTitle: "Meeting"), .noConnection)
    }

    @MainActor
    func testContextualMeetingGuidanceRendersMissingConfiguredAndFailedSummary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "[00:00:01] Speaker: We agreed to review the proposal tomorrow."
            .write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let originalAppearance = NSApp.appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.orderOut(nil); window.contentViewController = nil; NSApp.appearance = originalAppearance }
        for scenario in ["missing-llm", "create-summary", "failed-summary", "recording"] {
            var settings = AppSettings.default
            settings.summary.enabled = false
            settings.llm.connections = scenario == "missing-llm" ? [] : [SummaryProviderConfiguration(id: "connection")]
            let failed = scenario == "failed-summary"
            let summaryURL = folder.appendingPathComponent("summary.md")
            if failed {
                try "---\nstatus: partial_success\nsummary_error: summary_api_failed\n---\nSaved transcript fallback"
                    .write(to: summaryURL, atomically: true, encoding: .utf8)
            } else { try? FileManager.default.removeItem(at: summaryURL) }
            let model = DashboardViewModel(appStateProvider: { .idle }, jobRepository: TestJobRepository(),
                appSettingsStore: TestAppSettingsStore(settings: settings), keychainStore: TestKeychainStore(values: [:]),
                permissionService: PermissionService(), storageService: TestDashboardStorageService(),
                loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
                launchAtLoginController: TestLaunchAtLoginController())
            let meeting = DashboardViewModel.RecentMeeting(id: "meeting", title: "Manual recording", timestamp: Date(),
                status: scenario == "recording" ? "recording" : (failed ? "partial_success" : "completed"), folderURL: folder, summaryURL: failed ? summaryURL : nil,
                jobId: nil, needsFolderRename: false)
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let controller = NSHostingController(rootView: MeetingReaderView(meeting: meeting, viewModel: model, openSetup: { _ in }, openCurrentRecording: {})
                    .frame(width: 520, height: 540).background(WorkspaceDesign.surface)
                    .environment(\.colorScheme, dark ? .dark : .light))
                window.contentViewController = controller
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(180))
                let view = controller.view
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "context-\(scenario)-\(dark ? "dark" : "light")"
                try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-\(name).png"))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testSummarySetupUsesEnabledConnectionsAndPromptWithoutClaimingConnectivity() {
        var settings = AppSettings.default
        settings.llm.connections = []
        XCTAssertEqual(SummarySetupState(settings: settings), .noConnection)
        settings.llm.connections = [SummaryProviderConfiguration(id: "test", enabled: false)]
        settings.summary.enabled = true
        XCTAssertEqual(SummarySetupState(settings: settings), .noConnection)
        settings.llm.connections[0].enabled = true
        settings.summary.enabled = false
        XCTAssertEqual(SummarySetupState(settings: settings), .disabled)
        XCTAssertTrue(SummarySetupState(settings: settings).opensProcessing)
        settings.summary.enabled = true
        settings.prompts.items = []
        XCTAssertEqual(SummarySetupState(settings: settings), .missingPrompt)
        settings.prompts.items = [PromptItem(id: "blank", name: "Blank", text: "  \n")]
        XCTAssertEqual(SummarySetupState(settings: settings), .missingPrompt)
        settings.prompts.items = [PromptItem(id: "summary", name: "Summary", text: "Summarize the meeting")]
        XCTAssertEqual(SummarySetupState(settings: settings), .configured)
        XCTAssertFalse(SummarySetupState(settings: settings).opensProcessing)
    }

    @MainActor
    func testReadinessCardsRenderFirstRunAndConfiguredStates() async throws {
        let originalAppearance = NSApp.appearance
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 820),
                              styleMask: [.titled], backing: .buffered, defer: false)
        defer {
            window.orderOut(nil)
            window.contentViewController = nil
            NSApp.appearance = originalAppearance
        }
        for ready in [false, true] {
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let snapshot = SetupReadinessSnapshot(microphoneGranted: ready, screenRecordingGranted: ready,
                    transcription: TranscriptionDiagnosticResult(status: ready ? .success : .failure,
                        message: ready ? String(localized: "whisper.cpp is ready.")
                            : String(localized: "whisper.cpp is not ready. Check the required technologies below.")),
                    summary: ready ? .configured : .noConnection)
                XCTAssertEqual(snapshot.recordingPermissionsGranted, ready)
                let controller = NSHostingController(rootView: SetupReadinessCards(snapshot: snapshot, open: { _ in })
                    .padding(24).frame(width: 660, height: 820, alignment: .topLeading)
                    .background(WorkspaceDesign.surface).environment(\.colorScheme, dark ? .dark : .light))
                window.contentViewController = controller
                window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(60))
                let view = controller.view
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "readiness-\(ready ? "configured" : "first-run")-\(dark ? "dark" : "light")"
                try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-\(name).png"))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = name
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        let partial = SetupReadinessSnapshot(microphoneGranted: true, screenRecordingGranted: false,
            transcription: TranscriptionDiagnosticResult(status: .success, message: ""), summary: .configured)
        XCTAssertFalse(partial.recordingPermissionsGranted)
    }

    @MainActor
    func testUpdateNotificationsAnnounceNewVersionsOnceAndRespectGlobalPreferences() async {
        let manifest = AppUpdateManifest(version: "2.1.0", build: nil,
            downloadURL: URL(string: "https://example.com/AnyBrief.dmg")!, releaseNotesURL: nil)
        let newer = AppUpdateCheckResult(currentVersion: "2.0.0", manifest: manifest, isNewer: true)
        let current = AppUpdateCheckResult(currentVersion: "2.1.0", manifest: manifest, isNewer: false)
        for (enabled, permission, expectedSystemCount) in [(true, PermissionService.PermissionStatus.granted, 3), (false, .granted, 0), (true, .denied, 0)] {
            var settings = AppSettings.default
            settings.application.showNotifications = enabled
            settings.application.notificationCategories = []
            let store = InAppNotificationStore()
            let delivered = UpdateNotificationRecorder()
            let notifications = NotificationService(appSettingsStore: TestAppSettingsStore(settings: settings),
                inAppNotificationStore: store, permissionService: PermissionService(), loggingService: LoggingService(),
                checkPermissionStatus: { permission }, deliver: { _, body in await delivered.record(body) })
            await notifications.notifyUpdateCheck(current, userInitiated: false)
            XCTAssertTrue(store.notifications.isEmpty)
            await notifications.notifyUpdateCheck(newer, userInitiated: false)
            await notifications.notifyUpdateCheck(newer, userInitiated: false)
            XCTAssertEqual(store.notifications.count, 1)
            XCTAssertEqual(store.notifications.first?.category, "update_available")
            store.markAllAsRead()
            await notifications.notifyUpdateCheck(newer, userInitiated: true)
            await notifications.notifyUpdateCheck(current, userInitiated: true)
            XCTAssertEqual(store.notifications.count, 3)
            let count = await delivered.count
            XCTAssertEqual(count, expectedSystemCount)
        }
    }

    @MainActor
    func testUpdateChecksPublishManualResultsAndKeepBackgroundErrorsQuiet() async throws {
        let store = InAppNotificationStore()
        let settingsStore = TestAppSettingsStore(settings: .default)
        let notifications = NotificationService(appSettingsStore: settingsStore, inAppNotificationStore: store,
            permissionService: PermissionService(), loggingService: LoggingService(), checkPermissionStatus: { .denied })
        let session = SummarizationServiceTests.mockSession { request in
            guard request.url?.host == "anybrief.ru" else { throw URLError(.notConnectedToInternet) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"version":"2.1.0","downloadURL":"https://example.com/AnyBrief.dmg"}"#.utf8))
        }
        let model = DashboardViewModel(appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: settingsStore, keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            appUpdateService: AppUpdateService(session: session, currentVersion: "2.0.0"), updateNotificationService: notifications)
        model.languageSelection = "ru"
        await model.checkForUpdates(userInitiated: false)?.value
        XCTAssertEqual(model.availableUpdate?.version, "2.1.0")
        XCTAssertEqual(store.notifications.first?.category, "update_available")
        model.languageSelection = "en"
        await model.checkForUpdates(userInitiated: false)?.value
        XCTAssertEqual(store.notifications.count, 1)
        XCTAssertFalse(model.isCheckingForUpdates)
        await model.checkForUpdates()?.value
        XCTAssertEqual(store.notifications.first?.category, "update_check")
        XCTAssertFalse(model.isCheckingForUpdates)
    }

    @MainActor
    func testCollectionBindingFollowsIdentityAndIgnoresRemovedEditors() {
        let first = SummaryProviderConfiguration(id: "first", name: "First")
        let second = SummaryProviderConfiguration(id: "second", name: "Second")
        var items = [first, second]
        let source = Binding(get: { items }, set: { items = $0 })
        let editor = WorkspaceCollectionBinding.item(first, in: source)
        items.swapAt(0, 1)
        editor.wrappedValue.name = "Renamed"
        XCTAssertEqual(items[0].name, "Second")
        XCTAssertEqual(items[1].name, "Renamed")
        items.removeAll { $0.id == first.id }
        editor.wrappedValue.name = "Late edit from removed field"
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Second")
        XCTAssertEqual(editor.wrappedValue.id, first.id)
    }

    @MainActor
    func testAppearanceSwitchesExistingDashboardAndNativeControls() async throws {
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let model = DashboardViewModel(
            appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController())
        model.summaryProviderEntries = try [SummaryProvider.commandLine, .openAICompatible, .localOllama]
            .map { try model.summaryProviderRegistry.defaultConfiguration(for: $0) }
        model.selectedSummaryProviderConfigurationID = model.summaryProviderEntries.first?.id
        model.promptItems = AppSettings.default.prompts.items
        let notifications = InAppNotificationStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 780),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let controller = NSHostingController(rootView: DashboardView(viewModel: model,
            notificationStore: notifications, selectedPane: .settings))
        window.contentViewController = controller
        let host = controller.view
        defer { window.orderOut(nil); window.contentViewController = nil }
        host.frame.size = NSSize(width: 1120, height: 780)
        host.layoutSubtreeIfNeeded()
        window.orderFront(nil)
        for choice in [AppAppearance.light, .dark, .system] {
            model.appearanceSelection = choice
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            if choice == .system {
                XCTAssertNil(NSApp.appearance)
                XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]),
                    NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]))
            } else {
                let expected: NSAppearance.Name = choice == .dark ? .darkAqua : .aqua
                XCTAssertEqual(window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), expected)
                XCTAssertEqual(host.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]), expected)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "Appearance – \(choice.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-theme-\(choice.rawValue).png"))
                // Check actual rendered workspace background, not just the chosen preference.
                let background = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 10, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB))
                if choice == .dark { XCTAssertLessThan(background.redComponent, 0.3) }
                else { XCTAssertGreaterThan(background.redComponent, 0.9) }
            }
        }
        let screens: [(String, DashboardView.Pane, DashboardView.SettingsCategory, String)] = [
            ("llm", .settings, .summary, "prompts"),
            ("calendar", .settings, .calendar, "prompts"),
            ("windows", .settings, .windows, "prompts"),
            ("api", .settings, .api, "prompts"),
            ("transcription", .settings, .transcription, "prompts"),
            ("transcription-fluid-expanded", .settings, .transcription, "prompts"),
            ("transcription-whisper-expanded", .settings, .transcription, "prompts"),
            ("microphone", .settings, .microphone, "prompts"),
            ("prompts", .postProcessing, .app, "prompts"),
            ("processing", .postProcessing, .app, "processing"),
            ("processing-cleanup", .postProcessing, .app, "processing"),
            ("logs", .logs, .app, "prompts"),
        ]
        for choice in [AppAppearance.dark, .light] {
            model.appearanceSelection = choice
            for (name, pane, category, tab) in screens {
                model.appearanceSelection = choice == .dark ? .light : .dark
                model.transcriptionProviderSelection = name.contains("whisper")
                    ? TranscriptionProviderID.whisperCpp.rawValue : TranscriptionProviderID.fluidAudioSTT.rawValue
                let previewController = NSHostingController(rootView: DashboardView(viewModel: model,
                    notificationStore: notifications, selectedPane: pane, templateTab: tab,
                    selectedSettingsCategory: category,
                    selectedPostProcessingTab: name == "processing-cleanup" ? .transcript : .summary,
                    transcriptionBasicSettingsExpanded: name.hasSuffix("expanded")))
                window.contentViewController = previewController
                let preview = previewController.view
                preview.frame.size = [.windows, .api, .microphone, .transcription].contains(category) || tab == "processing"
                    ? NSSize(width: 900, height: 640) : NSSize(width: 1120, height: 780)
                preview.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
                model.appearanceSelection = choice
                try await Task.sleep(for: .milliseconds(70))
                preview.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
                preview.cacheDisplay(in: preview.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "\(name) – \(choice.rawValue)"
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-theme-\(name)-\(choice.rawValue).png"))
            }
        }
    }

    @MainActor
    func testProcessingStepsScreenshot() async throws {
        let meetingFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("2026-09-08_15-15_Manual-recording", isDirectory: true)
        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.postProcessing = PostProcessingSettings(enabled: true, rules: [
            PostProcessingRuleConfiguration(
                title: "Meeting export",
                matchMode: .exact,
                calendarTitlePattern: "Manual recording",
                destinationFolderPath: "/Documents/Meetings"
            )
        ])
        let model = DashboardViewModel(
            appStateProvider: { .processing }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )
        let activity = DashboardViewModel.CurrentActivity(
            jobId: "processing-preview", status: "summarizing", stage: JobStage.summarizing.rawValue,
            startedAt: Date(), duration: 42,
            detail: PipelineActivityDetail(
                phase: .summarization,
                connectionName: "Codex",
                connectionIndex: 1,
                connectionCount: 6,
                fallbackFrom: nil
            )
        )
        let meeting = DashboardViewModel.RecentMeeting(
            id: meetingFolder.path, title: "Manual recording", timestamp: Date(), status: "processing",
            folderURL: meetingFolder, summaryURL: nil, jobId: activity.jobId, needsFolderRename: false
        )
        model.activities = [activity]
        model.recentMeetings = [meeting]
        model.recordingProcessingPlan = RecordingProcessingPlan(
            jobID: activity.jobId,
            settings: settings,
            meetingTitle: meeting.title,
            exportTitle: meeting.title,
            transcriptionRegistry: model.transcriptionProviderRegistry,
            summaryRegistry: model.summaryProviderRegistry
        )
        model.appearanceSelection = .light

        let controller = NSHostingController(rootView: DashboardView(
            viewModel: model,
            notificationStore: InAppNotificationStore(),
            selectedPane: .processing
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentViewController = controller
        defer { window.orderOut(nil); window.contentViewController = nil }
        controller.view.frame.size = NSSize(width: 1180, height: 760)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
        controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-processing-steps.png"))
    }

    @MainActor
    func testLLMEditorsRenderWhileSwitchingConnections() async throws {
        let model = DashboardViewModel(
            appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController())
        let providers: [SummaryProvider] = [.commandLine, .openAICompatible, .localOllama, .openAICompatible]
        model.summaryProviderEntries = try providers.map { try model.summaryProviderRegistry.defaultConfiguration(for: $0) }
        model.selectedSummaryProviderConfigurationID = model.summaryProviderEntries.first?.id
        let host = NSHostingView(rootView: LLMEditorTestHost(model: model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        for index in 0..<20 {
            model.selectedSummaryProviderConfigurationID = model.summaryProviderEntries[index % model.summaryProviderEntries.count].id
            host.frame.size = NSSize(width: index.isMultiple(of: 2) ? 960 : 720, height: 640)
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            func firstTextField(in view: NSView) -> NSTextField? {
                if let field = view as? NSTextField, field.isEditable { return field }
                return view.subviews.lazy.compactMap { firstTextField(in: $0) }.first
            }
            if let field = firstTextField(in: host) { window.makeFirstResponder(field) }
            if index == 5 { model.moveSummaryProviderConfiguration(model.summaryProviderEntries[0], direction: 1) }
            if index == 10, let active = model.summaryProviderEntries.first(where: { $0.id == model.selectedSummaryProviderConfigurationID }) {
                let staleAPIKey = DashboardView(viewModel: model, notificationStore: InAppNotificationStore())
                    .summaryProviderAPIKeyBinding(for: active.id)
                model.removeSummaryProviderConfiguration(active)
                staleAPIKey.wrappedValue = "late-test-key"
                XCTAssertNil(model.summaryProviderAPIKeys[active.id])
            }
            try await Task.sleep(for: .milliseconds(15))
        }
        model.selectedSummaryProviderConfigurationID = model.summaryProviderEntries.first { $0.provider == .openAICompatible }?.id
        host.frame.size = NSSize(width: 960, height: 640)
        try await Task.sleep(for: .milliseconds(30))
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
                attachment.name = "LLM editor after switching connections"
                attachment.lifetime = .keepAlways
                add(attachment)
                try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-llm-editor-review.png"))
            }
        }
        XCTAssertEqual(model.summaryProviderEntries.count, 3)
        let processingHost = NSHostingView(rootView: DashboardView(viewModel: model,
            notificationStore: InAppNotificationStore(), templateTab: "processing").templatesWorkspace
            .tint(ABDesign.accent).preferredColorScheme(.light))
        window.contentView = processingHost
        processingHost.frame.size = NSSize(width: 708, height: 460)
        processingHost.layoutSubtreeIfNeeded()
        if let bitmap = processingHost.bitmapImageRepForCachingDisplay(in: processingHost.bounds) {
            processingHost.cacheDisplay(in: processingHost.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: "/private/tmp/anybrief-processing-review.png"))
            }
        }

    }

    @MainActor
    func testModelDownloadDoesNotReportReadyWhenRequiredFilesRemainMissing() async {
        let fileManager = FileManager.default
        let modelsURL = fileManager.temporaryDirectory
            .appendingPathComponent("dashboard-missing-models-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelsURL) }

        let modelService = FluidAudioSTTModelService(
            fileManager: fileManager,
            sttURLResolver: { URL(fileURLWithPath: "/usr/bin/true") },
            modelsDirectoryURL: modelsURL,
            coreMLModelLoader: { _ in }
        )
        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            transcriptionProviderRegistry: TranscriptionProviderRegistry(modules: [FluidAudioSTTModule(modelService: modelService)]),
            fileManager: fileManager
        )
        viewModel.transcriptionProviderSelection = TranscriptionProviderID.fluidAudioSTT.rawValue
        viewModel.transcriptionDiarizationEnabled = true

        viewModel.downloadTranscriptionModels()
        for _ in 0..<100 where viewModel.isDownloadingTranscriptionModels {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertFalse(viewModel.isDownloadingTranscriptionModels)
        XCTAssertFalse(viewModel.transcriptionModelStatus.isInstalled)
        XCTAssertTrue(viewModel.transcriptionModelMessageIsError)
        XCTAssertNotEqual(
            viewModel.transcriptionModelMessage,
            String(localized: "Transcription models are ready.")
        )
    }

    @MainActor
    func testInAppNotificationStoreMarksNotificationsAsRead() {
        let store = InAppNotificationStore()

        let first = store.add(category: "recording_started", title: "AnyBrief", body: "Recording started")
        _ = store.add(category: "summary_ready", title: "AnyBrief", body: "Your brief is ready")

        XCTAssertEqual(store.unreadCount, 2)

        store.markAsRead(id: first.id)

        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.unreadNotifications.map(\.category), ["summary_ready"])
    }

    @MainActor
    func testInAppNotificationStoreSkipsUnreadDuplicates() {
        let store = InAppNotificationStore()

        let first = store.addIfUnreadDuplicateIsMissing(
            category: "recording_interrupted",
            title: "AnyBrief",
            body: "Recording was interrupted"
        )
        let duplicate = store.addIfUnreadDuplicateIsMissing(
            category: "recording_interrupted",
            title: "AnyBrief",
            body: "Recording was interrupted"
        )

        XCTAssertNotNil(first)
        XCTAssertNil(duplicate)
        XCTAssertEqual(store.unreadCount, 1)
    }

    @MainActor
    func testInAppNotificationStoreMarksAllNotificationsAsRead() {
        let store = InAppNotificationStore()

        _ = store.add(category: "recording_started", title: "AnyBrief", body: "Recording started")
        _ = store.add(category: "summary_ready", title: "AnyBrief", body: "Your brief is ready")

        store.markAllAsRead()

        XCTAssertEqual(store.unreadCount, 0)
        XCTAssertTrue(store.unreadNotifications.isEmpty)
        XCTAssertEqual(store.notifications.count, 2)
        XCTAssertTrue(store.notifications.allSatisfy(\.isRead))
    }

    @MainActor
    func testInAppNotificationStoreKeepsFiveMostRecentNotifications() {
        let store = InAppNotificationStore()

        for index in 0..<7 {
            _ = store.add(category: "event-\(index)", title: "AnyBrief", body: "Event \(index)")
        }

        XCTAssertEqual(store.notifications.map(\.category), ["event-6", "event-5", "event-4", "event-3", "event-2"])
        XCTAssertEqual(store.notifications.count, InAppNotificationStore.maximumRetainedNotifications)
    }

    @MainActor
    func testNotificationServicePublishesInAppNotificationsWithoutSystemPermission() async {
        let store = InAppNotificationStore()
        let service = NotificationService(
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            inAppNotificationStore: store,
            permissionService: PermissionService(),
            loggingService: LoggingService(),
            checkPermissionStatus: { .denied },
            deliver: { _, _ in
                XCTFail("System delivery should not run when permission is denied")
            }
        )

        await service.notifyRecordingStarted()

        XCTAssertEqual(store.unreadCount, 1)
        XCTAssertEqual(store.unreadNotifications.first?.category, NotificationService.Category.recordingStarted.rawValue)
    }

    @MainActor
    func testRefreshLoadsLocalAPIEnabledFlagFromSettings() async {
        var settings = AppSettings()
        settings.automation.localHTTPAPISettings.enabled = true
        settings.application.appearance = .dark

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )

        viewModel.startRefreshing()
        defer { viewModel.stopRefreshing() }

        for _ in 0..<50 where viewModel.localHTTPAPIEnabled == false {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(viewModel.localHTTPAPIEnabled)
        XCTAssertEqual(viewModel.appearanceSelection, .dark)
        XCTAssertFalse(viewModel.hasUnsavedSettings)
        viewModel.appearanceSelection = .light
        XCTAssertTrue(viewModel.hasUnsavedSettings)
    }

    @MainActor
    func testSaveSettingsPersistsLocalAPIEnabledFlagAndRestartsService() async {
        let store = MutableTestAppSettingsStore(settings: AppSettings())
        let restartExpectation = expectation(description: "local API restart callback")

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: store,
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            localAPISettingsDidChange: {
                restartExpectation.fulfill()
            }
        )
        viewModel.localHTTPAPIEnabled = true

        viewModel.saveSettings()

        await fulfillment(of: [restartExpectation], timeout: 2.0)
        XCTAssertTrue(store.lastSavedSettings?.automation.localHTTPAPISettings.enabled == true)
    }

    @MainActor
    func testSaveSettingsPersistsAppFeatureFlags() async {
        let store = MutableTestAppSettingsStore(settings: AppSettings())
        let saveExpectation = expectation(description: "settings save callback")

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: store,
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            localAPISettingsDidChange: {
                saveExpectation.fulfill()
            }
        )
        viewModel.liveTranscriptEnabled = true
        viewModel.appearanceSelection = .dark
        viewModel.microphoneDeviceUID = "preferred-input"
        viewModel.microphoneVoiceProcessingEnabled = true
        viewModel.postProcessingTabEnabled = true

        viewModel.saveSettings()

        await fulfillment(of: [saveExpectation], timeout: 2.0)
        XCTAssertTrue(store.lastSavedSettings?.application.liveTranscriptEnabled == true)
        XCTAssertEqual(store.lastSavedSettings?.application.appearance, .dark)
        XCTAssertEqual(store.lastSavedSettings?.recording.microphoneDeviceUID, "preferred-input")
        XCTAssertEqual(store.lastSavedSettings?.recording.microphoneVoiceProcessingEnabled, true)
        XCTAssertTrue(store.lastSavedSettings?.application.postProcessingTabEnabled == true)
    }

    @MainActor
    func testProcessingRemainsVisibleDuringNewRecordingAndAfterCompletion() async {
        let now = Date()
        func job(_ id: String, _ status: String, _ stage: JobStage) -> Job {
            Job(id: id, meetingId: id, status: status, stage: stage, source: "manual",
                createdAt: now, updatedAt: now)
        }
        let processing = job("old", "processing", .summarizing)
        var starts = 0
        let model = DashboardViewModel(
            appStateProvider: { .processing },
            jobRepository: TestJobRepository(jobs: [processing]),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: { starts += 1 },
            stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )
        model.appState = .processing
        model.activities = await model.loadActivities()
        XCTAssertNil(model.recordingActivity)
        XCTAssertEqual(model.processingActivities.map(\.jobId), ["old"])
        XCTAssertTrue(model.canStartRecording)
        model.startRecording()
        XCTAssertEqual(starts, 1)

        let recording = job("new", "recording", .recording)
        model.activities = DashboardViewModel.activities(from: [processing, recording], appState: .recording, now: now)
        XCTAssertEqual(model.recordingActivity?.jobId, "new")
        XCTAssertEqual(model.processingActivities.map(\.jobId), ["old"])
        XCTAssertFalse(model.canStartRecording)
        model.startRecording()
        XCTAssertEqual(starts, 1)

        model.activities = DashboardViewModel.activities(
            from: [recording, job("old", "completed", .completed)], appState: .idle, now: now)
        XCTAssertEqual(model.recordingActivity?.jobId, "new")
        XCTAssertTrue(model.processingActivities.isEmpty)
        XCTAssertFalse(model.canStartRecording)

        model.activities = DashboardViewModel.activities(
            from: [processing, job("new", "processing", .recorded)], appState: .processing, now: now)
        model.applyRuntimeState(.processing, currentSession: nil)
        XCTAssertNil(model.recordingActivity)
        XCTAssertEqual(Set(model.processingActivities.map(\.jobId)), ["old", "new"])
        XCTAssertTrue(model.canStartRecording)
        model.isStoppingRecording = true
        XCTAssertFalse(model.canStartRecording)
    }

    @MainActor
    func testStartingRecordingKeepsProcessingJobsBeforeNewJobIsPersisted() {
        let now = Date()
        let processing = Job(id: "old", meetingId: "old", status: "processing", stage: .summarizing,
                             source: "manual", createdAt: now, updatedAt: now)
        let activities = DashboardViewModel.activities(from: [processing], appState: .recording, now: now)
        XCTAssertEqual(activities.map(\.jobId), ["runtime", "old"])
        XCTAssertTrue(activities[0].isRecording)
        XCTAssertFalse(activities[1].isRecording)
    }

    func testRecordingPlanUsesTitlePromptOrderedConnectionsAndFirstMatchingExport() {
        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.prompts.items = [
            PromptItem(id: "default", name: "General summary", text: "General"),
            PromptItem(id: "match", name: "Weekly decisions", text: "Weekly", titlePatterns: ["weekly"])
        ]
        settings.prompts.summary.promptID = "default"
        settings.llm.connections = [
            SummaryProviderConfiguration(id: "a", name: "First"),
            SummaryProviderConfiguration(id: "b", name: "Second"),
            SummaryProviderConfiguration(id: "off", name: "Disabled provider", enabled: false)
        ]
        settings.prompts.summary.connectionIDs = ["b", "off", "a"]
        settings.postProcessing.enabled = true
        settings.postProcessing.rules = [
            PostProcessingRuleConfiguration(title: "Disabled rule", enabled: false, calendarTitlePattern: "Weekly", destinationFolderPath: "/disabled"),
            PostProcessingRuleConfiguration(title: "Weekly notes", calendarTitlePattern: "Weekly", destinationFolderPath: "/chosen", exportContent: .both),
            PostProcessingRuleConfiguration(title: "Later match", calendarTitlePattern: "Weekly", destinationFolderPath: "/not-chosen")
        ]
        let plan = RecordingProcessingPlan(jobID: "recording", settings: settings,
            meetingTitle: "WEEKLY planning", exportTitle: "Weekly planning",
            transcriptionRegistry: .default, summaryRegistry: .default)
        XCTAssertTrue(plan.summaryDetail.contains("Weekly decisions"))
        XCTAssertFalse(plan.summaryDetail.contains("General summary"))
        XCTAssertTrue(plan.summaryDetail.contains("Second → First"))
        XCTAssertFalse(plan.summaryDetail.contains("Disabled provider"))
        XCTAssertTrue(plan.exportDetail.contains("Weekly notes"))
        XCTAssertTrue(plan.exportDetail.contains("/chosen"))
        XCTAssertFalse(plan.exportDetail.contains("/not-chosen"))
        XCTAssertFalse(plan.exportDetail.contains("/disabled"))
        XCTAssertTrue(plan.transcriptDetail.contains("nvidia-parakeet-tdt-0.6b-v3"))

        settings.summary.enabled = false
        let noMatch = RecordingProcessingPlan(jobID: "recording", settings: settings,
            meetingTitle: "Other meeting", exportTitle: "Other meeting",
            transcriptionRegistry: .default, summaryRegistry: .default)
        XCTAssertEqual(noMatch.summaryDetail, String(localized: "Disabled"))
        XCTAssertEqual(noMatch.exportDetail, String(localized: "No enabled export rule matches this meeting."))
    }

    @MainActor
    func testPostProcessingMessageIsScopedToMeetingAndClearedOnSelectionChange() {
        let model = DashboardViewModel(
            appStateProvider: { .idle }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: .default), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )
        model.postProcessingMessage = "Exported"
        model.postProcessingMessageMeetingID = "first"
        model.postProcessingMessageIsError = true

        XCTAssertEqual(model.postProcessingMessage(for: "first"), "Exported")
        XCTAssertNil(model.postProcessingMessage(for: "second"))

        model.clearPostProcessingMessage()

        XCTAssertNil(model.postProcessingMessage)
        XCTAssertNil(model.postProcessingMessageMeetingID)
        XCTAssertFalse(model.postProcessingMessageIsError)
    }

    @MainActor
    func testRecordingPlanUsesSavedSettingsInsteadOfUnsavedFormValues() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var settings = AppSettings.default
        settings.summary.enabled = true
        settings.prompts.items = [PromptItem(id: "saved", name: "Saved prompt", text: "Summarize")]
        settings.prompts.summary.promptID = "saved"
        let model = DashboardViewModel(
            appStateProvider: { .recording }, jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings), keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(), storageService: TestDashboardStorageService(),
            loggingService: LoggingService(), startRecordingAction: {}, stopRecordingAction: {}, forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )
        model.summaryEnabled = false
        model.promptItems = [PromptItem(id: "unsaved", name: "Unsaved prompt", text: "Draft")]
        let activity = DashboardViewModel.CurrentActivity(jobId: "recording", status: "recording", stage: "recording", startedAt: Date(), duration: 0, detail: nil)
        let meeting = DashboardViewModel.RecentMeeting(id: "meeting", title: "Meeting", timestamp: Date(), status: "recording", folderURL: folder, summaryURL: nil, jobId: "recording", needsFolderRename: false)
        let plan = await model.loadRecordingProcessingPlan(activities: [activity], meetings: [meeting])
        XCTAssertEqual(plan?.jobID, "recording")
        XCTAssertTrue(plan?.summaryDetail.contains("Saved prompt") == true)
        XCTAssertFalse(plan?.summaryDetail.contains("Unsaved prompt") == true)
        let idlePlan = await model.loadRecordingProcessingPlan(activities: [], meetings: [meeting])
        XCTAssertNil(idlePlan)
    }

    @MainActor
    func testCurrentActivityUsesStageStartTimeForProcessingJob() {
        let createdAt = Date(timeIntervalSince1970: 1_777_000_000)
        let stageStartedAt = createdAt.addingTimeInterval(18 * 60)
        let now = stageStartedAt.addingTimeInterval(44 * 60 + 26)
        let job = Job(
            id: "job-1",
            meetingId: "job-1",
            status: "processing",
            stage: .transcribingSystem,
            progressPercent: 20,
            source: "manual",
            createdAt: createdAt,
            updatedAt: stageStartedAt
        )

        let activity = DashboardViewModel.currentActivity(from: [job], appState: .processing, now: now)

        XCTAssertEqual(activity?.jobId, "job-1")
        XCTAssertEqual(activity?.stage, "transcribing_system")
        XCTAssertEqual(activity?.startedAt, stageStartedAt)
        XCTAssertEqual(activity?.duration ?? 0, 44 * 60 + 26, accuracy: 0.001)
    }

    @MainActor
    func testCurrentActivityHidesDuplicateStatusWhenStageMatches() {
        let now = Date(timeIntervalSince1970: 1_777_000_000)
        let job = Job(
            id: "job-2",
            meetingId: "job-2",
            status: "recording",
            stage: .recording,
            progressPercent: 0,
            source: "manual",
            createdAt: now,
            updatedAt: now
        )

        let activity = DashboardViewModel.currentActivity(from: [job], appState: .recording, now: now)

        XCTAssertEqual(activity?.showsSeparateStatus, false)
        XCTAssertFalse(activity?.summaryText.isEmpty ?? true)
        XCTAssertFalse(activity?.summaryText.contains("·") ?? true)
    }

    @MainActor
    func testCurrentActivityShowsDetailedLLMFallback() {
        let activity = DashboardViewModel.CurrentActivity(
            jobId: "job-3",
            status: "processing",
            stage: "processing_transcript",
            startedAt: Date(),
            duration: 10,
            detail: PipelineActivityDetail(
                phase: .transcriptCleanup,
                connectionName: "Ollama Gemma",
                connectionIndex: 4,
                connectionCount: 4,
                fallbackFrom: "Claude"
            )
        )

        XCTAssertEqual(
            activity.detailedStageLabel,
            "\(String(localized: "Cleaning transcript")) · Ollama Gemma"
        )
        let position = String(
            format: String(localized: "Connection %d of %d"),
            4,
            4
        )
        XCTAssertEqual(
            activity.fallbackText,
            String(
                format: String(localized: "%@ → %@ · %@"),
                "Claude",
                "Ollama Gemma",
                position
            )
        )
    }

    @MainActor
    func testCurrentActivityHidesConnectionPositionUntilFallbackStarts() {
        let activity = DashboardViewModel.CurrentActivity(
            jobId: "job-first-connection",
            status: "processing",
            stage: "summarizing",
            startedAt: Date(),
            duration: 10,
            detail: PipelineActivityDetail(
                phase: .summarization,
                connectionName: "Codex",
                connectionIndex: 1,
                connectionCount: 6,
                fallbackFrom: nil
            )
        )

        XCTAssertNil(activity.fallbackText)
    }

    @MainActor
    func testLoadLogsIncludesRecentJobWarningsAndErrors() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let logsURL = rootURL.appendingPathComponent("logs", isDirectory: true)
        let jobsLogsURL = logsURL.appendingPathComponent("jobs", isDirectory: true)
        try fileManager.createDirectory(at: jobsLogsURL, withIntermediateDirectories: true)
        try """
        2026-06-25T14:00:00+03:00 [INFO] [Pipeline] ok
        2026-06-25T14:01:00+03:00 [WARN] [Recovery] preserved raw artifacts
        """.write(
            to: logsURL.appendingPathComponent("app.log", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        --- transcribing_system ---
        ERROR: stt timed out after 1080 seconds for /tmp/system.wav.
        """.write(
            to: jobsLogsURL.appendingPathComponent("job-1.log", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(logsDirectoryURL: logsURL),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController()
        )

        let logs = await viewModel.loadLogs()

        XCTAssertTrue(logs.activity.contains("[INFO] [Pipeline] ok"))
        XCTAssertTrue(logs.errors.contains("[WARN] [Recovery] preserved raw artifacts"))
        XCTAssertTrue(logs.errors.contains("ERROR: stt timed out after 1080 seconds"))
    }

    @MainActor
    func testRefreshKeepsExistingAutopilotEventsWhenCalendarReloadFails() async {
        var settings = AppSettings()
        settings.automation.calDAVSettings.enabled = true
        settings.automation.calDAVSettings.name = "work"
        settings.automation.calDAVSettings.config.url = "https://caldav.example.com"
        settings.automation.calDAVSettings.config.username = "alice"
        settings.automation.calDAVSettings.passwordKeychainRef = "calendar-password"

        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: settings),
            keychainStore: TestKeychainStore(values: ["calendar-password": "secret"]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            calendarService: CalDAVCalendarService(dataLoader: { _ in
                throw URLError(.timedOut)
            })
        )
        let staleEvent = DashboardViewModel.AutopilotScheduleEvent(
            id: "existing-event",
            title: "Daily sync",
            startAt: Date(timeIntervalSince1970: 1_777_000_000),
            endAt: Date(timeIntervalSince1970: 1_777_003_600),
            participantCount: 2,
            hasMeetingURL: true,
            meetingURL: nil,
            originalUID: "existing-event",
            isRecurring: true,
            autopilotEnabled: true
        )
        viewModel.todayAutopilotEvents = [staleEvent]

        viewModel.startRefreshing()
        defer { viewModel.stopRefreshing() }

        for _ in 0..<50 where viewModel.lastRefreshAt == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertEqual(viewModel.todayAutopilotEvents.map(\.id), [staleEvent.id])
        XCTAssertEqual(viewModel.calendarScheduleError, URLError(.timedOut).localizedDescription)
    }

    @MainActor
    func testRepeatAllDispatchesMeetingReprocessingForBundledAudio() async throws {
        let rootURL = try makeTemporaryDirectory()
        let meetingURL = rootURL.appendingPathComponent("2026-07-25_12-00_Test_10m", isDirectory: true)
        let bundleURL = meetingURL.appendingPathComponent("bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try Data().write(to: bundleURL.appendingPathComponent("system_audio.mp3"))
        try Data().write(to: bundleURL.appendingPathComponent("microphone_audio.mp3"))

        let dispatched = expectation(description: "meeting reprocessing dispatched")
        let viewModel = DashboardViewModel(
            appStateProvider: { .idle },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(meetingsDirectoryURL: rootURL),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            launchAtLoginController: TestLaunchAtLoginController(),
            repeatMeetingProcessingAction: { folderURL, jobId, title, mode in
                XCTAssertEqual(folderURL, meetingURL)
                XCTAssertEqual(jobId, "job-repeat")
                XCTAssertEqual(title, "Test")
                XCTAssertEqual(mode, .all)
                dispatched.fulfill()
            }
        )
        let meeting = DashboardViewModel.RecentMeeting(
            id: meetingURL.path,
            title: "Test",
            timestamp: Date(),
            status: "completed",
            folderURL: meetingURL,
            summaryURL: nil,
            jobId: "job-repeat",
            needsFolderRename: false
        )

        XCTAssertTrue(viewModel.canRepeatMeetingProcessing(meeting))
        viewModel.repeatMeetingProcessing(meeting, mode: .all)

        await fulfillment(of: [dispatched], timeout: 2.0)
    }

    @MainActor
    func testDisableRecordingAutoStopDispatchesForCalendarRecording() async {
        let dispatched = expectation(description: "disable auto-stop dispatched")
        let viewModel = DashboardViewModel(
            appStateProvider: { .recording },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            disableRecordingAutoStopAction: { dispatched.fulfill() },
            launchAtLoginController: TestLaunchAtLoginController()
        )
        viewModel.recordingAutoStopState = .init(isCalendarRecording: true, isDisabled: false)

        viewModel.disableRecordingAutoStop()

        await fulfillment(of: [dispatched], timeout: 2.0)
    }

    @MainActor
    func testDisableRecordingAutoStopIgnoresManualRecording() async {
        let dispatched = expectation(description: "disable auto-stop not dispatched")
        dispatched.isInverted = true
        let viewModel = DashboardViewModel(
            appStateProvider: { .recording },
            jobRepository: TestJobRepository(),
            appSettingsStore: TestAppSettingsStore(settings: AppSettings()),
            keychainStore: TestKeychainStore(values: [:]),
            permissionService: PermissionService(),
            storageService: TestDashboardStorageService(),
            loggingService: LoggingService(),
            startRecordingAction: {},
            stopRecordingAction: {},
            forceStopRecordingAction: {},
            disableRecordingAutoStopAction: { dispatched.fulfill() },
            launchAtLoginController: TestLaunchAtLoginController()
        )
        viewModel.recordingAutoStopState = .init(isCalendarRecording: false, isDisabled: false)

        viewModel.disableRecordingAutoStop()

        await fulfillment(of: [dispatched], timeout: 0.1)
        XCTAssertFalse(viewModel.isDisablingRecordingAutoStop)
    }
}

private actor TestJobRepository: JobRepositoryProtocol {
    let jobs: [Job]
    init(jobs: [Job] = []) { self.jobs = jobs }
    func load() async -> [Job] { jobs }
    func save(_ jobs: [Job]) async {}
    func upsert(_ job: Job) async {}
    func get(id: String) async -> Job? { nil }
}

private final class TestAppSettingsStore: AppSettingsStoreProtocol {
    fileprivate let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load(using loggingService: LoggingService) async -> AppSettings { settings }
    func save(_ settings: AppSettings) async throws {}
}

private final class MutableTestAppSettingsStore: AppSettingsStoreProtocol {
    var settings: AppSettings
    private(set) var lastSavedSettings: AppSettings?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load(using loggingService: LoggingService) async -> AppSettings { settings }

    func save(_ settings: AppSettings) async throws {
        self.settings = settings
        lastSavedSettings = settings
    }
}

private final class TestKeychainStore: SecretStoreProtocol {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(key: String, value: String) throws {}
    func load(key: String) -> String? { values[key] }
    func delete(key: String) {}
}

private final class TestDashboardStorageService: StorageServiceProtocol {
    let meetingsDirectoryURL: URL

    init(
        meetingsDirectoryURL: URL = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
    ) {
        self.meetingsDirectoryURL = meetingsDirectoryURL
    }

    func prepareStorage(using loggingService: LoggingService) async throws {}
    func createMeetingFolder(jobId: String, startedAt: Date) throws -> MeetingPaths { fatalError("unused in test") }
    func renameMeetingFolder(from paths: MeetingPaths, duration: TimeInterval) throws -> URL { fatalError("unused in test") }
    func findMeetingPaths(jobId: String, createdAt: Date) throws -> MeetingPaths? { nil }
    func cleanupTemporaryArtifacts(for paths: MeetingPaths) throws {}
}

private struct TestLaunchAtLoginController: LaunchAtLoginControlling {
    func setEnabled(_ enabled: Bool) throws {}
}

final class MeetingReaderFilesTests: XCTestCase {
    func testSummaryFailureRequiresKnownFrontmatterMarker() {
        var content = MeetingReaderContent()
        content.summary = "---\nstatus: partial_success\nsummary_error: summary_api_failed\n---\nFallback"
        XCTAssertTrue(content.hasSummaryFailure)
        content.summary = "---\nstatus: completed\n---\nsummary_error: summary_api_failed"
        XCTAssertFalse(content.hasSummaryFailure)
        content.summary = "---\nstatus: partial_success\n---\nSummary"
        XCTAssertFalse(content.hasSummaryFailure)
    }

    func testMissingSummaryUsesRecordedSkipReasonAndCounts() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let logURL = folder.appendingPathComponent("job.log")
        try "ℹ️ Summary skipped: transcript has only 10 words; minimum is 30.\n--- converting_audio ---\n"
            .write(to: logURL, atomically: true, encoding: .utf8)
        let content = MeetingReaderFiles.documents(in: folder, jobLogURL: logURL)
        XCTAssertEqual(content.summarySkipReason, .shortTranscript(words: 10, minimum: 30))
        XCTAssertTrue(content.missingSummaryMessage(status: "completed").contains("10"))
        XCTAssertTrue(content.missingSummaryMessage(status: "completed").contains("30"))
        XCTAssertNotEqual(content.missingSummaryMessage(status: "failed"), content.summarySkipReason?.message)
        try "# Summary".write(to: folder.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        XCTAssertNil(MeetingReaderFiles.documents(in: folder, jobLogURL: logURL).summarySkipReason)
    }

    func testSummarySkipReasonUsesLatestAttemptAndDoesNotGuess() {
        typealias Reason = MeetingReaderContent.SummarySkipReason
        let short = "ℹ️ Summary skipped: transcript has only 10 words; minimum is 30."
        let disabled = "ℹ️ Summary skipped: automatic summary is disabled."
        XCTAssertEqual(Reason.from(jobLog: short + "\n" + disabled), .disabled)
        XCTAssertEqual(Reason.from(jobLog: disabled + "\n" + short), .shortTranscript(words: 10, minimum: 30))
        XCTAssertNil(Reason.from(jobLog: short + "\n--- summarizing ---\nERROR: failed"))
        XCTAssertNil(Reason.from(jobLog: ""))
        XCTAssertNil(Reason.from(jobLog: "ERROR: short input"))
        XCTAssertNil(Reason.from(jobLog: "ℹ️ Summary skipped: transcript has only unknown words; minimum is 30."))
    }

    func testTechnicalDetailsFormatsSavedMetadataAndCopyText() throws {
        let summary = """
        ---
        date: 2026-09-05T14:21:07.136Z
        duration: 1
        speakers: 2
        model: ""
        summary_provider:
          type: "cli"
          title: "CLI"
          timeout_sec: 600
          command_preset: "codex"
        transcription:
          provider: "fluid_audio_stt"
          model: "nvidia-parakeet-tdt-0.6b-v3"
          acceleration: "core_ml"
          diarization_enabled: true
          speakers_mode: "auto"
          speakers_count: 2
          system_speakers: "auto"
          microphone_speakers: 1
          threshold: 0.65
        audio:
          system:
            status: "recorded"
            duration_sec: 32.23
            size_bytes: 12382144
            segments: 1
            speakers: 1
          microphone:
            status: "recorded_no_speech"
            duration_sec: 32.23
            size_bytes: 6192456
            segments: 0
            speakers: 0
        ---
        Summary body: not technical data
        """
        let details = MeetingTechnicalDetails(summary: summary)
        XCTAssertEqual(details.sections.map(\.id), ["", "summary_provider", "transcription", "audio.system", "audio.microphone"])
        let rows = Dictionary(uniqueKeysWithValues: details.sections.flatMap(\.rows).map { ($0.id, $0) })
        XCTAssertEqual(rows["model"]?.value, String(localized: "Not specified"))
        XCTAssertEqual(rows["duration"]?.value, "1")
        XCTAssertEqual(rows["duration"]?.title, String(localized: "Duration (minutes)"))
        XCTAssertEqual(rows["audio.system.duration_sec"]?.value, "32.23")
        XCTAssertEqual(rows["audio.system.duration_sec"]?.title, String(localized: "Duration (seconds)"))
        XCTAssertEqual(rows["transcription.diarization_enabled"]?.value, String(localized: "Enabled"))
        XCTAssertEqual(rows["summary_provider.command_preset"]?.value, "Codex")
        XCTAssertEqual(rows["audio.microphone.status"]?.value, String(localized: "Recorded, no speech detected"))
        XCTAssertEqual(rows["audio.microphone.segments"]?.value, "0")
        XCTAssertTrue(try XCTUnwrap(rows["audio.system.size_bytes"]?.value).contains(Int64(12382144).formatted()))
        XCTAssertNotEqual(rows["date"]?.value, "2026-09-05T14:21:07.136Z")
        for section in details.sections {
            XCTAssertTrue(details.copyText.contains(section.title))
            for row in section.rows { XCTAssertTrue(details.copyText.contains("\(row.title): \(row.value)")) }
        }
        XCTAssertFalse(details.copyText.contains("summary_provider:"))
        XCTAssertFalse(details.copyText.contains("Summary body"))
    }

    func testTechnicalMetadataRequiresClosedFrontmatterAndPreservesQuotedValues() {
        XCTAssertTrue(MeetingTechnicalDetails(summary: "duration: 1").sections.isEmpty)
        XCTAssertTrue(MeetingTechnicalDetails(summary: "---\nduration: 1\nBody").sections.isEmpty)
        let summary = #"""
        ---
        model: "Model: \"quoted\""
        summary_provider:
          api_url: "https://example.test/v1:8000"
          command: "C:\\tools\\cli"
        ---
        model: body must not replace metadata
        """#
        let values = MeetingTechnicalDetails.scalars(in: summary.replacingOccurrences(of: "\n", with: "\r\n"))
        XCTAssertEqual(values["model"], #"Model: "quoted""#)
        XCTAssertEqual(values["summary_provider.api_url"], "https://example.test/v1:8000")
        XCTAssertEqual(values["summary_provider.command"], #"C:\tools\cli"#)
    }

    func testDocumentsKeepTranscriptWhenSummaryIsMissingOrUnreadable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "Speaker 1: Hello".write(to: folder.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        let missing = MeetingReaderFiles.documents(in: folder)
        XCTAssertEqual(missing.transcript, "Speaker 1: Hello")
        XCTAssertEqual(missing.summary, "")
        XCTAssertNil(missing.summaryError)
        try Data([0xff, 0xfe, 0xfd]).write(to: folder.appendingPathComponent("summary.md"))
        let unreadable = MeetingReaderFiles.documents(in: folder)
        XCTAssertNotNil(unreadable.summaryError)
        XCTAssertEqual(unreadable.transcript, missing.transcript)
    }

    func testAudioCopiesLooseTracksWithoutChangingMeetingFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("meeting")
        let scratch = root.appendingPathComponent("playback")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("audio fixture".utf8)
        let input = source.appendingPathComponent("system_audio.mp3")
        try bytes.write(to: input)
        let urls = try MeetingReaderFiles.audio(in: source, scratch: scratch)
        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.deletingLastPathComponent().path, scratch.path)
        XCTAssertEqual(try Data(contentsOf: input), bytes)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(urls.first)), bytes)
    }

    func testArchivedAudioExtractsOnlyKnownMembersAndPreservesArchive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("meeting")
        let inputs = root.appendingPathComponent("inputs")
        let scratch = root.appendingPathComponent("playback")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["system_audio.mp3", "microphone_audio.mp3", "private.txt"] {
            try Data(name.utf8).write(to: inputs.appendingPathComponent(name))
        }
        let archive = source.appendingPathComponent("bundle.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = inputs
        zip.arguments = ["-q", archive.path, "system_audio.mp3", "microphone_audio.mp3", "private.txt"]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let before = try Data(contentsOf: archive)
        let urls = try MeetingReaderFiles.audio(in: source, scratch: scratch)
        XCTAssertEqual(Set(urls.map(\.lastPathComponent)), ["system_audio.mp3", "microphone_audio.mp3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("private.txt").path))
        XCTAssertEqual(try Data(contentsOf: archive), before)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.path), ["bundle.zip"])
    }

    @MainActor
    func testAudioSourceSelectionPreservesPositionAndIsolatesTracks() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try copyAudioFixture(in: folder, name: "system_audio.mp3")
        try copyAudioFixture(in: folder, name: "microphone_audio.mp3")
        let model = MeetingReaderModel()
        defer { model.stop() }
        await model.loadAudio(folder: folder)
        XCTAssertNil(model.audioError)
        XCTAssertEqual(model.audioSources, [.together, .system, .microphone])
        XCTAssertEqual(model.selectedAudioSource, .together)
        let system = try XCTUnwrap(model.playersBySource[.system])
        let mic = try XCTUnwrap(model.playersBySource[.microphone])
        let scratch = try XCTUnwrap(system.url?.deletingLastPathComponent())
        XCTAssertEqual(system.volume, 1)
        XCTAssertEqual(mic.volume, 1)
        model.seek(0.25)

        model.selectAudioSource(.system)
        XCTAssertEqual(system.volume, 1)
        XCTAssertEqual(mic.volume, 0)
        model.selectAudioSource(.microphone)
        XCTAssertEqual(system.volume, 0)
        XCTAssertEqual(mic.volume, 1)
        XCTAssertEqual(model.position, 0.25)
        XCTAssertEqual(system.currentTime, 0.25, accuracy: 0.01)
        XCTAssertEqual(mic.currentTime, 0.25, accuracy: 0.01)
        XCTAssertEqual(model.duration, 1, accuracy: 0.01)
        model.selectAudioSource(.together)
        XCTAssertEqual(system.volume, 1)
        XCTAssertEqual(mic.volume, 1)
        XCTAssertEqual(model.position, 0.25)

        model.stop()
        XCTAssertTrue(model.audioSources.isEmpty)
        XCTAssertTrue(model.playersBySource.isEmpty)
        XCTAssertEqual(model.position, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("system_audio.mp3").path))
    }

    @MainActor
    func testSingleAudioTrackDoesNotOfferMissingSource() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try copyAudioFixture(in: folder, name: "microphone_audio.mp3")
        let model = MeetingReaderModel()
        defer { model.stop() }
        await model.loadAudio(folder: folder)
        XCTAssertNil(model.audioError)
        XCTAssertEqual(model.audioSources, [.microphone])
        XCTAssertEqual(model.selectedAudioSource, .microphone)
        model.selectAudioSource(.system)
        XCTAssertEqual(model.selectedAudioSource, .microphone)
        XCTAssertEqual(model.playersBySource[.microphone]?.volume, 1)
    }

    private func copyAudioFixture(in folder: URL, name: String) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/short-audio.mp3")
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent(name))
    }

    @MainActor
    func testRecordingTimeHandlesHourBoundary() {
        XCTAssertEqual(DashboardView.recordingTime(0), "00:00")
        XCTAssertEqual(DashboardView.recordingTime(-1), "00:00")
        XCTAssertEqual(DashboardView.recordingTime(3599), "59:59")
        XCTAssertEqual(DashboardView.recordingTime(3600), "1:00:00")
    }
}

private struct LLMEditorTestHost: View {
    @ObservedObject var model: DashboardViewModel
    var body: some View {
        DashboardView(viewModel: model, notificationStore: InAppNotificationStore()).summarySettingsGroup
            .background(WorkspaceDesign.surface).tint(ABDesign.accent).preferredColorScheme(.light)
    }
}

private actor UpdateNotificationRecorder {
    private(set) var count = 0
    func record(_ body: String) { count += 1 }
}

private actor MicrophonePauseRecorder {
    private(set) var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
}
