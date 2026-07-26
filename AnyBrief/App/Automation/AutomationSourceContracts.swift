import Foundation
import SwiftUI

enum AutomationSourceID: String, Codable, CaseIterable, Identifiable {
    case calDAV = "caldav"
    case localHTTPAPI = "local_http_api"
    case windowObserver = "window_observer"

    var id: String { rawValue }
}

struct AutomationSourceConfiguration: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var source: AutomationSourceID = .calDAV
    var enabled = true
    var payload: ConfigurationPayload = [:]

    enum CodingKeys: String, CodingKey {
        case id
        case source
        case enabled
        case payload
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        source: AutomationSourceID = .calDAV,
        enabled: Bool = true,
        payload: ConfigurationPayload = [:]
    ) {
        self.id = id
        self.source = source
        self.enabled = enabled
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        source = try container.decodeIfPresent(AutomationSourceID.self, forKey: .source) ?? .calDAV
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        payload = try container.decodeIfPresent(ConfigurationPayload.self, forKey: .payload) ?? [:]
    }
}

enum AutomationRuleKind: String, Codable, CaseIterable, Identifiable {
    case calendarAutopilot = "calendar_autopilot"

    var id: String { rawValue }
}

struct AutomationRuleConfiguration: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var kind: AutomationRuleKind = .calendarAutopilot
    var source: AutomationSourceID = .calDAV
    var enabled = false
    var payload: ConfigurationPayload = [:]

    enum CodingKeys: String, CodingKey {
        case id
        case kind
        case source
        case enabled
        case payload
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        kind: AutomationRuleKind = .calendarAutopilot,
        source: AutomationSourceID = .calDAV,
        enabled: Bool = false,
        payload: ConfigurationPayload = [:]
    ) {
        self.id = id
        self.kind = kind
        self.source = source
        self.enabled = enabled
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        kind = try container.decodeIfPresent(AutomationRuleKind.self, forKey: .kind) ?? .calendarAutopilot
        source = try container.decodeIfPresent(AutomationSourceID.self, forKey: .source) ?? .calDAV
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        payload = try container.decodeIfPresent(ConfigurationPayload.self, forKey: .payload) ?? [:]
    }
}

struct AutomationRuntimeContext {
    let appSettingsStore: AppSettingsStoreProtocol
    let keychainStore: SecretStoreProtocol
    let loggingService: LoggingService
    let currentSessionProvider: @Sendable () async -> RecordingSession?
    let sleep: @Sendable (UInt64) async -> Void
}

struct AutomationDiagnosticsContext {
    let appSettingsStore: AppSettingsStoreProtocol
    let keychainStore: SecretStoreProtocol
}

struct AutomationSourceSettingsViewContext {
    let settings: Binding<AppSettings>
}

struct AutomationDiagnosticResult: Equatable {
    enum Status: Equatable {
        case success
        case failure
    }

    let status: Status
    let message: String
}

protocol AutomationDiagnostics {
    func diagnose(configuration: AutomationSourceConfiguration, settings: AppSettings) async -> AutomationDiagnosticResult
}

protocol AutomationSource: AnyObject {
    var id: AutomationSourceID { get }
    var events: AsyncStream<AutomationEvent> { get }

    func start() async
    func stop() async
}

protocol AutomationSourceModule {
    var id: AutomationSourceID { get }
    var title: String { get }
    var systemImage: String { get }
    var hasSettingsView: Bool { get }

    func defaultConfiguration() -> AutomationSourceConfiguration
    func normalize(_ configuration: AutomationSourceConfiguration) -> AutomationSourceConfiguration
    func makeSource(context: AutomationRuntimeContext) -> any AutomationSource
    func makeDiagnostics(context: AutomationDiagnosticsContext) -> any AutomationDiagnostics
    @MainActor func makeSettingsView(context: AutomationSourceSettingsViewContext) -> AnyView
}

extension AutomationSourceModule {
    var hasSettingsView: Bool {
        false
    }

    func normalize(_ configuration: AutomationSourceConfiguration) -> AutomationSourceConfiguration {
        configuration
    }

    @MainActor func makeSettingsView(context: AutomationSourceSettingsViewContext) -> AnyView {
        AnyView(EmptyView())
    }
}

struct AutomationSourceError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
