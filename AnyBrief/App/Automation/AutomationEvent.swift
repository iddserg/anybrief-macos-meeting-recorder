import Foundation

struct AutomationEvent: Identifiable {
    let id: String
    let sourceID: AutomationSourceID
    let emittedAt: Date
    let kind: AutomationEventKind

    init(
        id: String = UUID().uuidString.lowercased(),
        sourceID: AutomationSourceID,
        emittedAt: Date = Date(),
        kind: AutomationEventKind
    ) {
        self.id = id
        self.sourceID = sourceID
        self.emittedAt = emittedAt
        self.kind = kind
    }
}

enum AutomationEventKind {
    case calendarEventsRefreshed(events: [CalendarEvent], settings: AppSettings)
    case windowMatched(match: WindowObserverMatch, config: WindowObserverConfig, settings: AppSettings)
    case sourceFailed(message: String)
}
