import Foundation

struct CalDAVModule: AutomationSourceModule {
    var settingsPayloadCodec: ModuleSettingsPayloadCodec {
        ModuleSettingsPayloadCodec(CalDAVAutomationSettings.self, includesEnabled: true, secrets: [ConfigurationSecretField(valuePath: ["config", "password"], referencePath: ["passwordKeychainRef"])])
    }
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

    func importRuleConfiguration(_ configuration: AutomationRuleConfiguration) throws -> AutomationRuleConfiguration {
        guard configuration.kind == .calendarAutopilot, configuration.source == id else {
            throw ModuleSettingsPayloadError.unsupportedRule
        }
        let data = try JSONEncoder().encode(configuration.payload)
        var settings: AutopilotSettings
        do { settings = try JSONDecoder().decode(AutopilotSettings.self, from: data) }
        catch { throw ModuleSettingsPayloadError.invalidPayload }
        settings.enabled = configuration.enabled
        var result = configuration
        result.payload = ConfigurationPayloadCodec.encode(settings)
        return result
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
