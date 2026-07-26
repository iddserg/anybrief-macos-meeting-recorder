import Foundation

/// Participant details parsed from CalDAV attendee and organizer fields.
struct CalendarParticipant: Codable, Equatable, Sendable {
    let name: String?
    let email: String?
    let role: String?
    let status: String?
    let rsvp: Bool?
}
