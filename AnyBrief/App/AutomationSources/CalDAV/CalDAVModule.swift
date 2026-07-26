import Foundation

struct CalDAVModule: AutomationSourceModule {
    let id: AutomationSourceID = .calDAV
    let title = "CalDAV"
    let systemImage = "calendar.badge.clock"
    private let calendarService: CalDAVCalendarService

    init(calendarService: CalDAVCalendarService = CalDAVCalendarService()) {
        self.calendarService = calendarService
    }

    func defaultConfiguration() -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(source: id)
    }

    func makeSource(context: AutomationRuntimeContext) -> any AutomationSource {
        CalDAVAutomationSource(
            appSettingsStore: context.appSettingsStore,
            keychainStore: context.keychainStore,
            calendarService: calendarService,
            loggingService: context.loggingService,
            currentSessionProvider: context.currentSessionProvider,
            sleep: context.sleep
        )
    }

    func makeDiagnostics(context: AutomationDiagnosticsContext) -> any AutomationDiagnostics {
        CalDAVDiagnostics(keychainStore: context.keychainStore)
    }
}
