import Foundation

/// Recording metadata carried from calendar automation into summaries and artifacts.
struct AutopilotRecordingMetadata: Codable {
    let calendarEventUID: String?
    /// Legacy key name retained on disk. For calendar-driven diarization this is
    /// an upper bound, not an exact speaker count.
    let systemSpeakersOverride: Int?
    let calendarEvent: CalendarEvent?
}
