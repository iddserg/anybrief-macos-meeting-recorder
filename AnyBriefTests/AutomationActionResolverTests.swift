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

    private func makeSettings() -> AppSettings {
        var settings = AppSettings()
        settings.automation.calendarAutopilotSettings.enabled = true
        settings.automation.calendarAutopilotSettings.filter = "all"
        settings.automation.calendarAutopilotSettings.startLeadSec = 30
        settings.automation.calendarAutopilotSettings.stopGraceSec = 60
        return settings
    }

    private func makeEligibleEvent(uid: String, participantCount: Int = 2) -> CalendarEvent {
        CalendarEvent(
            uid: uid,
            originalUID: uid,
            calendarName: "work",
            title: "Calendar meeting",
            startAt: Date().addingTimeInterval(-60),
            endAt: Date().addingTimeInterval(600),
            timeZone: "UTC",
            location: nil,
            notes: nil,
            organizer: nil,
            attendees: [],
            meetingURLs: ["https://zoom.us/j/123"],
            participantCount: participantCount,
            hasMeetingURL: true,
            recurrenceRule: nil,
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
