import XCTest
@testable import AnyBrief

final class AutomationActionResolverTests: XCTestCase {
    func testCalendarEventStartsOnlyOncePerEligibleOccurrence() async {
        let sessionBox = TestSessionBox()
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: {
                await sessionBox.session()
            }
        )
        let event = makeEligibleEvent(uid: "event-once")
        let settings = makeSettings()

        let firstActions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [event], settings: settings))
        )
        XCTAssertEqual(firstActions.startCalendarEventUIDs, ["event-once"])

        let secondActions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [event], settings: settings))
        )
        XCTAssertTrue(secondActions.isEmpty)
    }

    func testCalendarEventDoesNotRestartAfterManualStopOfCalendarRecording() async {
        let sessionBox = TestSessionBox()
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: {
                await sessionBox.session()
            }
        )
        let event = makeEligibleEvent(uid: "event-manual-stop")
        let settings = makeSettings()

        let startActions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [event], settings: settings))
        )
        XCTAssertEqual(startActions.startCalendarEventUIDs, ["event-manual-stop"])

        await sessionBox.setSession(
            RecordingSession(
                jobId: "calendar-job",
                pid: 1,
                paths: makeMeetingPaths(),
                startedAt: Date().addingTimeInterval(-60),
                source: "calendar",
                title: event.title,
                autoStopDisabled: false,
                autoStopAt: event.endAt.addingTimeInterval(60),
                calendarEventUID: event.uid
            )
        )
        let activeActions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [event], settings: settings))
        )
        XCTAssertTrue(activeActions.isEmpty)

        await sessionBox.setSession(nil)
        let afterManualStopActions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [event], settings: settings))
        )
        XCTAssertTrue(afterManualStopActions.isEmpty)
    }

    func testCalendarSpeakerCountIsPassedAsMaximumOverride() async {
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { nil }
        )
        var settings = makeSettings()
        settings.transcription.fluidAudioSTTConfig.speakersMode = "calendar"

        let actions = await resolver.resolve(
            AutomationEvent(
                sourceID: .calDAV,
                kind: .calendarEventsRefreshed(
                    events: [makeEligibleEvent(uid: "calendar-speaker-max", participantCount: 6)],
                    settings: settings
                )
            )
        )

        XCTAssertEqual(actions.startCalendarSpeakerMaxOverrides, [5])
    }

    func testAutopilotExcludesOnlySelectedOneOffEvent() async {
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { nil }
        )
        let excludedEvent = makeEligibleEvent(uid: "excluded-event")
        let includedEvent = makeEligibleEvent(uid: "included-event")
        var settings = makeSettings()
        settings.automation.calendarAutopilotSettings.excludedEventUIDs = [excludedEvent.uid]

        let actions = await resolver.resolve(
            AutomationEvent(
                sourceID: .calDAV,
                kind: .calendarEventsRefreshed(events: [excludedEvent, includedEvent], settings: settings)
            )
        )

        XCTAssertEqual(actions.startCalendarEventUIDs, [includedEvent.uid])
    }

    func testAutopilotExcludesEveryOccurrenceInRecurringSeries() async {
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { nil }
        )
        let firstOccurrence = makeEligibleEvent(
            uid: "series-event-first",
            originalUID: "series-event",
            recurrenceRule: "FREQ=WEEKLY"
        )
        let secondOccurrence = makeEligibleEvent(
            uid: "series-event-second",
            originalUID: "series-event",
            recurrenceRule: "FREQ=WEEKLY"
        )
        var settings = makeSettings()
        settings.automation.calendarAutopilotSettings.excludedSeriesUIDs = ["series-event"]

        let actions = await resolver.resolve(
            AutomationEvent(
                sourceID: .calDAV,
                kind: .calendarEventsRefreshed(events: [firstOccurrence, secondOccurrence], settings: settings)
            )
        )

        XCTAssertTrue(actions.isEmpty)
    }

    func testFixedSpeakerCountDoesNotCreateCalendarOverride() async {
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { nil }
        )
        var settings = makeSettings()
        settings.transcription.fluidAudioSTTConfig = FluidAudioSTTConfig(
            speakersMode: "fixed",
            speakersCount: 3
        )

        let actions = await resolver.resolve(
            AutomationEvent(
                sourceID: .calDAV,
                kind: .calendarEventsRefreshed(
                    events: [makeEligibleEvent(uid: "fixed-speakers", participantCount: 6)],
                    settings: settings
                )
            )
        )

        XCTAssertEqual(actions.startCalendarSpeakerMaxOverrides, [])
    }

    func testCalendarEventDoesNotStartBeforeItsExactStartTime() async {
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { nil }
        )
        let event = makeEligibleEvent(
            uid: "future-event",
            startAt: Date().addingTimeInterval(60),
            endAt: Date().addingTimeInterval(660)
        )

        let actions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [event], settings: makeSettings()))
        )

        XCTAssertTrue(actions.isEmpty)
    }

    func testBackToBackCalendarEventsStopThenStartAtBoundary() async {
        let sessionBox = TestSessionBox()
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { await sessionBox.session() }
        )
        let first = makeEligibleEvent(
            uid: "first-event",
            startAt: Date().addingTimeInterval(-600),
            endAt: Date().addingTimeInterval(-1)
        )
        let second = makeEligibleEvent(
            uid: "second-event",
            startAt: Date().addingTimeInterval(-1),
            endAt: Date().addingTimeInterval(600)
        )
        await sessionBox.setSession(
            RecordingSession(
                jobId: "first-job",
                pid: 1,
                paths: makeMeetingPaths(),
                startedAt: first.startAt,
                source: "calendar",
                title: first.title,
                autoStopDisabled: false,
                autoStopAt: first.endAt,
                calendarEventUID: first.uid
            )
        )

        let actions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [first, second], settings: makeSettings()))
        )

        XCTAssertEqual(actions.count, 2)
        if case let .stopCalendarRecording(session, _) = actions[0] {
            XCTAssertEqual(session.jobId, "first-job")
        } else {
            XCTFail("Expected the first recording to stop before the next one starts")
        }
        XCTAssertEqual(actions.startCalendarEventUIDs, [second.uid])
    }

    func testDisabledAutoStopAlsoPreventsSwitchToNextCalendarEvent() async {
        let sessionBox = TestSessionBox()
        let resolver = AutomationActionResolver(
            jobRepository: TestAutomationJobRepository(),
            currentSessionProvider: { await sessionBox.session() }
        )
        let first = makeEligibleEvent(
            uid: "continued-event",
            startAt: Date().addingTimeInterval(-600),
            endAt: Date().addingTimeInterval(-1)
        )
        let second = makeEligibleEvent(
            uid: "next-event",
            startAt: Date().addingTimeInterval(-1),
            endAt: Date().addingTimeInterval(600)
        )
        await sessionBox.setSession(
            RecordingSession(
                jobId: "continued-job",
                pid: 1,
                paths: makeMeetingPaths(),
                startedAt: first.startAt,
                source: "calendar",
                title: first.title,
                autoStopDisabled: true,
                autoStopAt: first.endAt,
                calendarEventUID: first.uid
            )
        )

        let actions = await resolver.resolve(
            AutomationEvent(sourceID: .calDAV, kind: .calendarEventsRefreshed(events: [first, second], settings: makeSettings()))
        )

        XCTAssertTrue(actions.isEmpty)
    }

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        settings.automation.calendarAutopilotSettings.enabled = true
        settings.automation.calendarAutopilotSettings.filter = "all"
        return settings
    }

    private func makeEligibleEvent(
        uid: String,
        originalUID: String? = nil,
        participantCount: Int = 2,
        recurrenceRule: String? = nil,
        startAt: Date = Date().addingTimeInterval(-60),
        endAt: Date = Date().addingTimeInterval(600)
    ) -> CalendarEvent {
        CalendarEvent(
            uid: uid,
            originalUID: originalUID ?? uid,
            calendarName: "work",
            title: "Calendar meeting",
            startAt: startAt,
            endAt: endAt,
            timeZone: "UTC",
            location: nil,
            notes: nil,
            organizer: nil,
            attendees: [],
            meetingURLs: ["https://zoom.us/j/123"],
            participantCount: participantCount,
            hasMeetingURL: true,
            recurrenceRule: recurrenceRule,
            recurrenceID: nil
        )
    }

    private func makeMeetingPaths() -> MeetingPaths {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return MeetingPaths(
            folderURL: base,
            tmpURL: base.appendingPathComponent("tmp", isDirectory: true),
            systemWavURL: base.appendingPathComponent("system.wav"),
            micWavURL: base.appendingPathComponent("mic.wav"),
            jobLogURL: base.appendingPathComponent("job.log")
        )
    }
}

private actor TestSessionBox {
    private var currentSession: RecordingSession?

    func session() -> RecordingSession? {
        currentSession
    }

    func setSession(_ session: RecordingSession?) {
        currentSession = session
    }
}

private actor TestAutomationJobRepository: JobRepositoryProtocol {
    private var jobs: [Job] = []

    func load() async -> [Job] {
        jobs
    }

    func save(_ jobs: [Job]) async {
        self.jobs = jobs
    }

    func upsert(_ job: Job) async {
        jobs.removeAll { $0.id == job.id }
        jobs.append(job)
    }

    func get(id: String) async -> Job? {
        jobs.first { $0.id == id }
    }
}

private extension Array where Element == AutomationAction {
    var startCalendarEventUIDs: [String] {
        compactMap { action in
            if case let .startCalendarRecording(event, _, _) = action {
                return event.uid
            }
            return nil
        }
    }

    var startCalendarSpeakerMaxOverrides: [Int] {
        compactMap { action in
            if case let .startCalendarRecording(_, _, speakerMaxOverride) = action {
                return speakerMaxOverride
            }
            return nil
        }
    }
}
