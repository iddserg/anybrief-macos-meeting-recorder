import Foundation

struct CalDAVAutomationSettings: Codable, Equatable {
    var enabled = false
    var name = ""
    var config = CalDAVConfig()
    var passwordKeychainRef: String? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = CalDAVAutomationSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? defaults.name
        config = try container.decodeIfPresent(CalDAVConfig.self, forKey: .config) ?? defaults.config
        passwordKeychainRef = try container.decodeIfPresent(String.self, forKey: .passwordKeychainRef)
    }
}

struct AutopilotSettings: Codable, Equatable {
    var enabled = false
    var filter = "meeting_url_or_multiparticipant"
    var preEndNotificationSec = 120
    var muteMicrophone = false
    var participantCountMode = "calendar"
    var participantCount = 2
    var pollIntervalSec = 30
    var excludedEventUIDs: [String] = []
    var excludedSeriesUIDs: [String] = []

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AutopilotSettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        filter = try container.decodeIfPresent(String.self, forKey: .filter) ?? defaults.filter
        preEndNotificationSec = try container.decodeIfPresent(Int.self, forKey: .preEndNotificationSec)
            ?? defaults.preEndNotificationSec
        muteMicrophone = try container.decodeIfPresent(Bool.self, forKey: .muteMicrophone) ?? defaults.muteMicrophone
        participantCountMode = try container.decodeIfPresent(String.self, forKey: .participantCountMode)
            ?? defaults.participantCountMode
        participantCount = try container.decodeIfPresent(Int.self, forKey: .participantCount)
            ?? defaults.participantCount
        pollIntervalSec = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSec) ?? defaults.pollIntervalSec
        excludedEventUIDs = try container.decodeIfPresent([String].self, forKey: .excludedEventUIDs)
            ?? defaults.excludedEventUIDs
        excludedSeriesUIDs = try container.decodeIfPresent([String].self, forKey: .excludedSeriesUIDs)
            ?? defaults.excludedSeriesUIDs
    }

    func includes(_ event: CalendarEvent) -> Bool {
        !excludedEventUIDs.contains(event.uid) && !excludedSeriesUIDs.contains(event.originalUID)
    }

    mutating func setIncluded(_ included: Bool, eventUID: String, originalUID: String, isRecurring: Bool) {
        if isRecurring {
            excludedSeriesUIDs.removeAll { $0 == originalUID }
            if !included {
                excludedSeriesUIDs.append(originalUID)
            }
        } else {
            excludedEventUIDs.removeAll { $0 == eventUID }
            if !included {
                excludedEventUIDs.append(eventUID)
            }
        }
    }
}

extension AutomationSourceConfiguration {
    static func calDAV(_ settings: CalDAVAutomationSettings = CalDAVAutomationSettings()) -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(
            source: .calDAV,
            enabled: settings.enabled,
            payload: ConfigurationPayloadCodec.encode(settings)
        )
    }

    var calDAVSettings: CalDAVAutomationSettings {
        get {
            ConfigurationPayloadCodec.decode(CalDAVAutomationSettings.self, from: payload, default: CalDAVAutomationSettings())
        }
        set {
            source = .calDAV
            enabled = newValue.enabled
            payload = ConfigurationPayloadCodec.encode(newValue)
        }
    }
}

extension AutomationRuleConfiguration {
    static func calendarAutopilot(_ settings: AutopilotSettings = AutopilotSettings()) -> AutomationRuleConfiguration {
        AutomationRuleConfiguration(
            kind: .calendarAutopilot,
            source: .calDAV,
            enabled: settings.enabled,
            payload: ConfigurationPayloadCodec.encode(settings)
        )
    }

    var calendarAutopilotSettings: AutopilotSettings {
        get {
            ConfigurationPayloadCodec.decode(AutopilotSettings.self, from: payload, default: AutopilotSettings())
        }
        set {
            kind = .calendarAutopilot
            source = .calDAV
            enabled = newValue.enabled
            payload = ConfigurationPayloadCodec.encode(newValue)
        }
    }
}

extension AutomationSettings {
    var calDAVSettings: CalDAVAutomationSettings {
        get {
            sourceConfiguration(for: .calDAV).calDAVSettings
        }
        set {
            updateSourceConfiguration(for: .calDAV) {
                $0.calDAVSettings = newValue
            }
        }
    }

    var calendarAutopilotSettings: AutopilotSettings {
        get {
            ruleConfiguration(for: .calendarAutopilot).calendarAutopilotSettings
        }
        set {
            updateRuleConfiguration(for: .calendarAutopilot) {
                $0.calendarAutopilotSettings = newValue
            }
        }
    }
}
