import Foundation

enum AutomationAction {
    case startCalendarRecording(event: CalendarEvent, settings: AppSettings, systemSpeakersOverride: Int?)
    case startWindowRecording(match: WindowObserverMatch, settings: AppSettings)
    case notifyWindowMatch(match: WindowObserverMatch)
    case stopCalendarRecording(session: RecordingSession, reason: String)
    case skip(reason: String)
    case log(message: String, level: LoggingService.LogLevel)
}
