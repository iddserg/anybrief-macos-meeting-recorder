import Foundation

/// CalDAV synchronization errors used by calendar automation.
enum CalendarSyncError: LocalizedError {
    case missingConfiguration
    case requestFailed(Int)
    case invalidResponse
    case noCalendarsFound

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "CalDAV URL, username, calendar ID, or password is missing."
        case let .requestFailed(status):
            return "CalDAV request failed with HTTP \(status)."
        case .invalidResponse:
            return "CalDAV response could not be parsed."
        case .noCalendarsFound:
            return "No CalDAV calendars were found for this account."
        }
    }

    var shouldThrottleAutomaticRetries: Bool {
        switch self {
        case .missingConfiguration, .noCalendarsFound:
            return true
        case let .requestFailed(status):
            return status == 401 || status == 403
        case .invalidResponse:
            return false
        }
    }
}

struct SuppressedCalendarFetchError: LocalizedError, Sendable {
    let message: String

    var errorDescription: String? { message }
}

let maxAutopilotBackgroundPollInterval: TimeInterval = 30 * 60
