import Foundation

/// Executes automation actions against recording and pipeline services.
actor AutomationActionHandler {
    private let recordingAdapter: RecordingAdapter
    private let pipelineOrchestrator: PipelineOrchestrator
    private let loggingService: LoggingService
    private let notifyWindowMatch: @Sendable (WindowObserverMatch) async -> Void

    init(
        recordingAdapter: RecordingAdapter,
        pipelineOrchestrator: PipelineOrchestrator,
        loggingService: LoggingService,
        notifyWindowMatch: @escaping @Sendable (WindowObserverMatch) async -> Void = { _ in }
    ) {
        self.recordingAdapter = recordingAdapter
        self.pipelineOrchestrator = pipelineOrchestrator
        self.loggingService = loggingService
        self.notifyWindowMatch = notifyWindowMatch
    }

    func handle(_ action: AutomationAction) async {
        do {
            switch action {
            case let .startCalendarRecording(event, settings, systemSpeakersOverride):
                try await start(event: event, settings: settings, systemSpeakersOverride: systemSpeakersOverride)
            case let .startWindowRecording(match, settings):
                try await start(match: match, settings: settings)
            case let .notifyWindowMatch(match):
                await notifyWindowMatch(match)
            case let .stopCalendarRecording(session, reason):
                try await stop(session: session, reason: reason)
            case let .skip(reason):
                await loggingService.log(reason, level: .warn, component: "Autopilot")
            case let .log(message, level):
                await loggingService.log(message, level: level, component: "Autopilot")
            }
        } catch {
            await loggingService.log(
                "Autopilot action failed: \(error.localizedDescription)",
                level: .error,
                component: "Autopilot"
            )
        }
    }

    private func start(event: CalendarEvent, settings: AppSettings, systemSpeakersOverride: Int?) async throws {
        let session = try await recordingAdapter.start(
            jobId: JobIDGenerator.make(),
            source: "calendar",
            title: event.title,
            autoStopAt: event.endAt.addingTimeInterval(TimeInterval(settings.automation.calendarAutopilotSettings.stopGraceSec)),
            microphonePausedAtStart: settings.automation.calendarAutopilotSettings.muteMicrophone,
            systemSpeakersOverride: systemSpeakersOverride,
            calendarEventUID: event.uid,
            calendarEvent: event
        )
        await loggingService.log(
            "Autopilot started recording \(event.title) for job \(session.jobId) systemSpeakerMax=\(systemSpeakersOverride.map(String.init) ?? "auto").",
            level: .info,
            component: "Autopilot"
        )
    }

    private func start(match: WindowObserverMatch, settings: AppSettings) async throws {
        let session = try await recordingAdapter.start(
            jobId: JobIDGenerator.make(),
            source: "window_observer",
            title: match.recordingTitle,
            microphonePausedAtStart: settings.automation.calendarAutopilotSettings.muteMicrophone
        )
        await loggingService.log(
            "Window Observer started recording \(match.recordingTitle) for job \(session.jobId).",
            level: .info,
            component: "WindowObserver"
        )
    }

    private func stop(session: RecordingSession, reason: String) async throws {
        let stopped = try await recordingAdapter.stop()
        await pipelineOrchestrator.enqueue(session: stopped)
        await loggingService.log(
            "Autopilot stopped recording \(session.jobId): \(reason).",
            level: .info,
            component: "Autopilot"
        )
    }
}
