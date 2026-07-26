import XCTest
@testable import AnyBrief

/// Tests CalDAV URL construction rules from the autopilot/calendar integration spec.
final class CalDAVCalendarServiceTests: XCTestCase {
    func testCalendarURLAppendsCalendarPathToHostWithoutTrailingSlash() {
        let url = CalDAVCalendarService.calendarURL(
            baseURLString: "https://caldav.example.com",
            username: "alice",
            calendarID: "work"
        )

        XCTAssertEqual(url?.absoluteString, "https://caldav.example.com/calendars/alice/work/")
    }

    func testCalendarURLAppendsCalendarPathToHostWithTrailingSlash() {
        let url = CalDAVCalendarService.calendarURL(
            baseURLString: "https://caldav.example.com/",
            username: "alice",
            calendarID: "work"
        )

        XCTAssertEqual(url?.absoluteString, "https://caldav.example.com/calendars/alice/work/")
    }

    func testCalendarURLKeepsExpandedCalendarPathUntouched() {
        let url = CalDAVCalendarService.calendarURL(
            baseURLString: "https://caldav.example.com/calendars/alice/work/",
            username: "bob",
            calendarID: "personal"
        )

        XCTAssertEqual(url?.absoluteString, "https://caldav.example.com/calendars/alice/work/")
    }

    func testCalendarURLKeepsBaseURLWhenCalendarIDIsEmpty() {
        let url = CalDAVCalendarService.calendarURL(
            baseURLString: "https://caldav.example.com",
            username: "alice",
            calendarID: ""
        )

        XCTAssertEqual(url?.absoluteString, "https://caldav.example.com")
    }

    func testCalendarURLEncodesUsernameAndCalendarNamePathComponents() {
        let url = CalDAVCalendarService.calendarURL(
            baseURLString: "https://caldav.example.com/dav",
            username: "alice smith@example.com",
            calendarID: "team / eng"
        )

        XCTAssertEqual(
            url?.absoluteString,
            "https://caldav.example.com/dav/calendars/alice%20smith@example.com/team%20%2F%20eng/"
        )
    }

    func testCalendarHomeURLAppendsCalendarsCollection() {
        let url = CalDAVCalendarService.calendarHomeURL(
            baseURLString: "https://caldav.example.com",
            username: "alice@example.com"
        )

        XCTAssertEqual(url?.absoluteString, "https://caldav.example.com/calendars/alice@example.com/")
    }

    func testCalendarHomeURLUsesParentCollectionForExpandedCalendarURL() {
        let url = CalDAVCalendarService.calendarHomeURL(
            baseURLString: "https://caldav.example.com/calendars/alice@example.com/work/",
            username: "alice@example.com"
        )

        XCTAssertEqual(url?.absoluteString, "https://caldav.example.com/calendars/alice@example.com/")
    }

    func testParseCalendarListExtractsCalendarIDsAndDisplayNames() throws {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:response>
            <d:href>/calendars/alice@example.com/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Alice</d:displayname>
                <d:resourcetype><d:collection /></d:resourcetype>
              </d:prop>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/calendars/alice@example.com/events-4574505/</d:href>
            <d:propstat>
              <d:prop>
                <d:displayname>Work Meetings</d:displayname>
                <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
              </d:prop>
            </d:propstat>
          </d:response>
          <d:response>
            <d:href>/calendars/alice@example.com/team%20calendar/</d:href>
            <d:propstat>
              <d:prop>
                <d:resourcetype><d:collection /><c:calendar /></d:resourcetype>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """

        let calendars = try CalDAVCalendarService.parseCalendarList(from: Data(xml.utf8))

        XCTAssertEqual(calendars.count, 2)
        XCTAssertEqual(calendars[0].id, "events-4574505")
        XCTAssertEqual(calendars[0].displayName, "Work Meetings")
        XCTAssertEqual(calendars[1].id, "team calendar")
        XCTAssertEqual(calendars[1].displayName, "team calendar")
    }

    func testFetchEventsReusesWiderRecentResultForContainedRange() async throws {
        let counter = RequestCounter()
        let settings = makeSettings(username: "reuse@example.com", calendarName: "reuse-cache")
        let response = HTTPURLResponse(
            url: URL(string: "https://caldav.example.com")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
        let service = CalDAVCalendarService(dataLoader: { _ in
            await counter.increment()
            return (Self.calendarResponseData, response)
        })
        let dayStart = Self.iso8601.date(from: "2026-05-25T00:00:00Z")!
        let wideStart = dayStart.addingTimeInterval(-3600)
        let wideEnd = dayStart.addingTimeInterval(24 * 3600)
        let narrowEnd = dayStart.addingTimeInterval(12 * 3600)

        let wideEvents = try await service.fetchEvents(
            settings: settings,
            password: "secret",
            from: wideStart,
            to: wideEnd
        )
        let narrowEvents = try await service.fetchEvents(
            settings: settings,
            password: "secret",
            from: dayStart,
            to: narrowEnd
        )

        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(wideEvents.map(\.uid), ["event-1-20260525T090000Z"])
        XCTAssertEqual(narrowEvents.map(\.uid), ["event-1-20260525T090000Z"])
    }

    func testFetchEventsSuppressesRepeatedFailureWithinRecentWindow() async throws {
        let counter = RequestCounter()
        let settings = makeSettings(username: "failure@example.com", calendarName: "failure-cache")
        let service = CalDAVCalendarService(dataLoader: { _ in
            await counter.increment()
            throw URLError(.timedOut)
        })
        let start = Self.iso8601.date(from: "2026-05-25T00:00:00Z")!
        let end = start.addingTimeInterval(24 * 3600)

        await XCTAssertThrowsErrorAsync {
            _ = try await service.fetchEvents(
                settings: settings,
                password: "secret",
                from: start,
                to: end
            )
        } verify: { error in
            XCTAssertEqual(error.localizedDescription, URLError(.timedOut).localizedDescription)
        }

        await XCTAssertThrowsErrorAsync {
            _ = try await service.fetchEvents(
                settings: settings,
                password: "secret",
                from: start,
                to: end
            )
        } verify: { error in
            XCTAssertTrue(error is SuppressedCalendarFetchError)
            XCTAssertEqual(error.localizedDescription, URLError(.timedOut).localizedDescription)
        }

        let requestCount = await counter.value
        XCTAssertEqual(requestCount, 1)
    }

    func testAutopilotBasePollIntervalIsCappedAtThirtyMinutes() {
        var settings = AppSettings()
        settings.automation.calendarAutopilotSettings.pollIntervalSec = 7_200

        XCTAssertEqual(AutomationActionResolver.basePollInterval(for: settings), 1_800)
    }

    func testAutopilotNextWakeIntervalUsesUpcomingStartBoundaryWhenSoonerThanBaseInterval() {
        var settings = AppSettings()
        settings.automation.calendarAutopilotSettings.filter = "all"
        settings.automation.calendarAutopilotSettings.startLeadSec = 30
        settings.automation.calendarAutopilotSettings.pollIntervalSec = 1_800
        let now = Self.iso8601.date(from: "2026-05-25T12:00:00Z")!
        let event = makeEvent(
            uid: "start-boundary",
            startAt: Self.iso8601.date(from: "2026-05-25T12:10:00Z")!,
            endAt: Self.iso8601.date(from: "2026-05-25T13:00:00Z")!
        )

        let interval = AutomationActionResolver.nextWakeInterval(
            now: now,
            events: [event],
            settings: settings,
            currentSession: nil
        )

        XCTAssertEqual(interval, 570, accuracy: 0.001)
    }

    func testAutopilotNextWakeIntervalUsesCurrentCalendarSessionAutoStopWhenSoonerThanBaseInterval() {
        var settings = AppSettings()
        settings.automation.calendarAutopilotSettings.pollIntervalSec = 1_800
        let now = Self.iso8601.date(from: "2026-05-25T12:00:00Z")!
        let session = RecordingSession(
            jobId: "job-1",
            pid: 1,
            paths: makeMeetingPaths(),
            startedAt: now.addingTimeInterval(-300),
            source: "calendar",
            title: "Calendar meeting",
            autoStopDisabled: false,
            autoStopAt: now.addingTimeInterval(120)
        )

        let interval = AutomationActionResolver.nextWakeInterval(
            now: now,
            events: [],
            settings: settings,
            currentSession: session
        )

        XCTAssertEqual(interval, 120, accuracy: 0.001)
    }

    func testAutopilotDefersCalendarStartWhileManualJobIsProcessing() {
        let now = Self.iso8601.date(from: "2026-05-25T12:00:00Z")!
        let jobs = [
            Job(
                id: "calendar-job",
                meetingId: "calendar-job",
                status: "completed",
                stage: .completed,
                source: "calendar",
                createdAt: now.addingTimeInterval(-600),
                updatedAt: now.addingTimeInterval(-60),
                completedAt: now.addingTimeInterval(-60)
            ),
            Job(
                id: "manual-job",
                meetingId: "manual-job",
                status: "processing",
                stage: .summarizing,
                source: "manual",
                createdAt: now.addingTimeInterval(-1_800),
                updatedAt: now
            )
        ]

        XCTAssertEqual(AutomationActionResolver.nonCalendarActiveJob(in: jobs)?.id, "manual-job")
    }

    func testAutopilotDoesNotDeferCalendarStartForCompletedManualJob() {
        let now = Self.iso8601.date(from: "2026-05-25T12:00:00Z")!
        let jobs = [
            Job(
                id: "manual-job",
                meetingId: "manual-job",
                status: "completed",
                stage: .completed,
                source: "manual",
                createdAt: now.addingTimeInterval(-1_800),
                updatedAt: now,
                completedAt: now
            )
        ]

        XCTAssertNil(AutomationActionResolver.nonCalendarActiveJob(in: jobs))
    }

    private func makeSettings(username: String, calendarName: String) -> AppSettings {
        var settings = AppSettings()
        settings.automation.calendarAutopilotSettings.enabled = true
        settings.automation.calendarAutopilotSettings.pollIntervalSec = 30
        settings.automation.calDAVSettings.name = calendarName
        settings.automation.calDAVSettings.config.url = "https://caldav.example.com"
        settings.automation.calDAVSettings.config.username = username
        return settings
    }

    private func makeEvent(uid: String, startAt: Date, endAt: Date) -> CalendarEvent {
        CalendarEvent(
            uid: uid,
            originalUID: uid,
            calendarName: "work",
            title: "Meeting",
            startAt: startAt,
            endAt: endAt,
            timeZone: "UTC",
            location: nil,
            notes: nil,
            organizer: nil,
            attendees: [],
            meetingURLs: ["https://zoom.us/j/123"],
            participantCount: 2,
            hasMeetingURL: true,
            recurrenceRule: nil,
            recurrenceID: nil
        )
    }

    private func makeMeetingPaths() -> MeetingPaths {
        let root = URL(fileURLWithPath: "/tmp/anybrief-test", isDirectory: true)
        return MeetingPaths(
            folderURL: root.appendingPathComponent("meeting", isDirectory: true),
            tmpURL: root.appendingPathComponent("meeting/tmp", isDirectory: true),
            systemWavURL: root.appendingPathComponent("meeting/tmp/system.wav", isDirectory: false),
            micWavURL: root.appendingPathComponent("meeting/tmp/mic.wav", isDirectory: false),
            jobLogURL: root.appendingPathComponent("logs/job-1.log", isDirectory: false)
        )
    }

    private actor RequestCounter {
        private(set) var value = 0

        func increment() {
            value += 1
        }
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let calendarResponseData = Data(
        """
        <?xml version="1.0" encoding="utf-8"?>
        <d:multistatus xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav">
          <d:response>
            <d:propstat>
              <d:prop>
                <c:calendar-data><![CDATA[
        BEGIN:VCALENDAR
        VERSION:2.0
        BEGIN:VEVENT
        UID:event-1
        SUMMARY:Product Sync
        DTSTART:20260525T090000Z
        DTEND:20260525T100000Z
        END:VEVENT
        END:VCALENDAR
                ]]></c:calendar-data>
              </d:prop>
            </d:propstat>
          </d:response>
        </d:multistatus>
        """.utf8
    )
}

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    verify: (Error) -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        verify(error)
    }
}
