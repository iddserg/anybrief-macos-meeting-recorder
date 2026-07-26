import Foundation

/// Resolves automation events into recording actions while preserving CalDAV autopilot behavior.
actor AutomationActionResolver {
    private let jobRepository: JobRepositoryProtocol
    private let currentSessionProvider: @Sendable () async -> RecordingSession?
    private var attemptedCalendarEventStartExpirations: [String: Date] = [:]

    init(
        jobRepository: JobRepositoryProtocol,
        currentSessionProvider: @escaping @Sendable () async -> RecordingSession?
    ) {
        self.jobRepository = jobRepository
        self.currentSessionProvider = currentSessionProvider
    }

    func resolve(_ event: AutomationEvent) async -> [AutomationAction] {
        switch event.kind {
        case let .calendarEventsRefreshed(events, settings):
            return await resolveCalendarEvents(events, settings: settings)
        case let .windowMatched(match, config, settings):
            return await resolveWindowMatch(match, config: config, settings: settings)
        case let .sourceFailed(message):
            return [.log(message: "Autopilot calendar sync failed: \(message)", level: .warn)]
        }
    }

    private func resolveCalendarEvents(_ events: [CalendarEvent], settings: AppSettings) async -> [AutomationAction] {
        let now = Date()
        let lead = TimeInterval(settings.automation.calendarAutopilotSettings.startLeadSec)
        let grace = TimeInterval(settings.automation.calendarAutopilotSettings.stopGraceSec)
        pruneCalendarStartAttempts(now: now)
        let eligibleEvents = events
            .filter { event in
                event.startAt <= now.addingTimeInterval(lead) &&
                event.endAt.addingTimeInterval(grace) > now &&
                Self.matchesFilter(event, settings: settings)
            }
            .sorted { lhs, rhs in
                if lhs.startAt == rhs.startAt { return lhs.endAt < rhs.endAt }
                return lhs.startAt < rhs.startAt
            }

        if let session = await currentSessionProvider() {
            if session.source == "calendar",
               eligibleEvents.contains(where: { $0.uid == session.calendarEventUID }) {
                if let autoStopAt = session.autoStopAt,
                   !session.autoStopDisabled,
                   autoStopAt <= now {
                    return [.stopCalendarRecording(session: session, reason: "scheduled stop")]
                }
                return []
            }
        }

        guard let selectedEvent = eligibleEvents.first(where: { !hasAttemptedCalendarStart(for: $0) }) else {
            if let action = await stopExpiredCalendarRecordingAction(now: now) {
                return [action]
            }
            return []
        }

        var actions: [AutomationAction] = []
        if let session = await currentSessionProvider() {
            if session.source == "calendar", session.calendarEventUID == selectedEvent.uid {
                if let autoStopAt = session.autoStopAt,
                   !session.autoStopDisabled,
                   autoStopAt <= now {
                    return [.stopCalendarRecording(session: session, reason: "scheduled stop")]
                }
                return []
            }

            guard session.source == "calendar" else {
                return [
                    .skip(reason: "Autopilot skipped \(selectedEvent.title): manual recording is active."),
                ]
            }

            actions.append(.stopCalendarRecording(session: session, reason: "switching to \(selectedEvent.title)"))
        }

        let jobs = await jobRepository.load()
        if let blockingJob = Self.nonCalendarActiveJob(in: jobs) {
            actions.append(
                .skip(
                    reason: "Autopilot skipped \(selectedEvent.title): non-calendar job \(blockingJob.id) is \(blockingJob.status)/\(blockingJob.stage.rawValue)."
                )
            )
            return actions
        }

        markCalendarStartAttempt(for: selectedEvent, grace: grace)
        actions.append(
            .startCalendarRecording(
                event: selectedEvent,
                settings: settings,
                systemSpeakersOverride: Self.systemSpeakers(for: selectedEvent, settings: settings)
            )
        )
        return actions
    }

    private func hasAttemptedCalendarStart(for event: CalendarEvent) -> Bool {
        attemptedCalendarEventStartExpirations[event.uid] != nil
    }

    private func markCalendarStartAttempt(for event: CalendarEvent, grace: TimeInterval) {
        attemptedCalendarEventStartExpirations[event.uid] = event.endAt.addingTimeInterval(grace)
    }

    private func pruneCalendarStartAttempts(now: Date) {
        attemptedCalendarEventStartExpirations = attemptedCalendarEventStartExpirations.filter { _, expiresAt in
            expiresAt > now
        }
    }

    private func resolveWindowMatch(
        _ match: WindowObserverMatch,
        config: WindowObserverConfig,
        settings: AppSettings
    ) async -> [AutomationAction] {
        var actions: [AutomationAction] = []
        if config.actionMode.sendsNotification {
            actions.append(.notifyWindowMatch(match: match))
        }

        guard config.actionMode.startsRecording else {
            return actions
        }

        if let session = await currentSessionProvider() {
            actions.append(.skip(reason: "Window Observer skipped \(match.recordingTitle): \(session.source) recording is active."))
            return actions
        }

        actions.append(.startWindowRecording(match: match, settings: settings))
        return actions
    }

    private func stopExpiredCalendarRecordingAction(now: Date) async -> AutomationAction? {
        guard let session = await currentSessionProvider(),
              session.source == "calendar",
              let autoStopAt = session.autoStopAt,
              !session.autoStopDisabled,
              autoStopAt <= now else {
            return nil
        }
        return .stopCalendarRecording(session: session, reason: "scheduled stop")
    }

    static func nextWakeInterval(
        now: Date,
        events: [CalendarEvent],
        settings: AppSettings,
        currentSession: RecordingSession?
    ) -> TimeInterval {
        let baseInterval = basePollInterval(for: settings)
        var candidates = [baseInterval]
        let lead = TimeInterval(settings.automation.calendarAutopilotSettings.startLeadSec)
        let grace = TimeInterval(settings.automation.calendarAutopilotSettings.stopGraceSec)

        for event in events where matchesFilter(event, settings: settings) {
            let startBoundary = event.startAt.addingTimeInterval(-lead)
            if startBoundary > now {
                candidates.append(startBoundary.timeIntervalSince(now))
            }

            let endBoundary = event.endAt.addingTimeInterval(grace)
            if endBoundary > now {
                candidates.append(endBoundary.timeIntervalSince(now))
            }
        }

        if let autoStopAt = currentSession?.autoStopAt,
           currentSession?.source == "calendar",
           currentSession?.autoStopDisabled == false,
           autoStopAt > now {
            candidates.append(autoStopAt.timeIntervalSince(now))
        }

        return max(1, candidates.min() ?? baseInterval)
    }

    static func basePollInterval(for settings: AppSettings) -> TimeInterval {
        min(
            TimeInterval(max(10, settings.automation.calendarAutopilotSettings.pollIntervalSec)),
            maxAutopilotBackgroundPollInterval
        )
    }

    static func nonCalendarActiveJob(in jobs: [Job]) -> Job? {
        jobs
            .filter { !$0.isTerminal && $0.source != "calendar" }
            .sorted {
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.createdAt > $1.createdAt
            }
            .first
    }

    private static func matchesFilter(_ event: CalendarEvent, settings: AppSettings) -> Bool {
        switch settings.automation.calendarAutopilotSettings.filter {
        case "all":
            return true
        case "meeting_url":
            return event.hasMeetingURL
        case "multiparticipant":
            return event.participantCount > 1
        default:
            return event.hasMeetingURL || event.participantCount > 1
        }
    }

    private static func systemSpeakers(for event: CalendarEvent, settings: AppSettings) -> Int? {
        let speakersMode: String
        switch settings.transcription.activeProviderConfiguration.provider {
        case .fluidAudioSTT:
            speakersMode = settings.transcription.fluidAudioSTTConfig.speakersMode
        case .whisperCpp:
            speakersMode = settings.transcription.whisperCppConfig.speakersMode
        }
        switch speakersMode {
        case "calendar":
            return max(1, min(10, event.participantCount - 1))
        default:
            return nil
        }
    }
}
