import Foundation

/// Calendar event payload used by CalDAV automation and summary metadata.
struct CalendarEvent: Codable, Equatable, Sendable {
    let uid: String
    let originalUID: String
    let calendarName: String
    let title: String
    let startAt: Date
    let endAt: Date
    let timeZone: String
    let location: String?
    let notes: String?
    let organizer: CalendarParticipant?
    let attendees: [CalendarParticipant]
    let meetingURLs: [String]
    let participantCount: Int
    let hasMeetingURL: Bool
    let recurrenceRule: String?
    let recurrenceID: Date?
}
