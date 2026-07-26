import Foundation

struct WindowObserverConfig: Codable, Equatable {
    enum ActionMode: String, Codable, CaseIterable, Identifiable {
        case notify = "notify"
        case recordAndNotify = "record_and_notify"

        var id: String { rawValue }

        var startsRecording: Bool {
            self == .recordAndNotify
        }

        var sendsNotification: Bool {
            self == .notify || self == .recordAndNotify
        }
    }

    enum Scope: String, Codable, CaseIterable, Identifiable {
        case activeApplication = "active_application"
        case allVisibleWindows = "all_visible_windows"

        var id: String { rawValue }
    }

    var enabled = false
    var actionMode: ActionMode = .recordAndNotify
    var scope: Scope = .activeApplication
    var stableMatchSec = 8
    var pollIntervalSec = 30
    var rules: [WindowObserverRule] = WindowObserverRule.defaultRules

    func normalized() -> WindowObserverConfig {
        var copy = self
        copy.stableMatchSec = max(1, min(120, stableMatchSec))
        copy.pollIntervalSec = max(1, min(60, pollIntervalSec))
        copy.rules = rules.map(\.normalized)
        if copy.rules.isEmpty {
            copy.rules = WindowObserverRule.defaultRules
        }
        return copy
    }
}

struct WindowObserverRule: Codable, Equatable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var enabled = true
    var name: String
    var applicationPattern: String
    var titlePattern: String

    init(
        id: String = UUID().uuidString.lowercased(),
        enabled: Bool = true,
        name: String,
        applicationPattern: String,
        titlePattern: String = ""
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.applicationPattern = applicationPattern
        self.titlePattern = titlePattern
    }

    var normalized: WindowObserverRule {
        WindowObserverRule(
            id: id.isEmpty ? UUID().uuidString.lowercased() : id,
            enabled: enabled,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            applicationPattern: applicationPattern.trimmingCharacters(in: .whitespacesAndNewlines),
            titlePattern: titlePattern.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    static let defaultRules: [WindowObserverRule] = [
        WindowObserverRule(name: "Zoom", applicationPattern: "zoom"),
    ]
}

struct ObservedWindow: Equatable {
    let applicationName: String
    let title: String
    let processIdentifier: Int32

    var identity: String {
        [
            applicationName.lowercased(),
            title.lowercased(),
            String(processIdentifier),
        ].joined(separator: "\u{1F}")
    }
}

struct WindowObserverMatch: Equatable {
    let ruleID: String
    let ruleName: String
    let applicationName: String
    let windowTitle: String
    let processIdentifier: Int32

    var recordingTitle: String {
        let trimmedTitle = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return "\(applicationName) - \(trimmedTitle)"
        }
        return applicationName
    }

    var stableIdentity: String {
        [
            ruleID,
            applicationName.lowercased(),
            windowTitle.lowercased(),
            String(processIdentifier),
        ].joined(separator: "\u{1F}")
    }
}

extension AutomationSourceConfiguration {
    static func windowObserver(_ config: WindowObserverConfig = WindowObserverConfig()) -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(
            source: .windowObserver,
            enabled: config.enabled,
            payload: ConfigurationPayloadCodec.encode(config.normalized())
        )
    }

    var windowObserverSettings: WindowObserverConfig {
        get {
            ConfigurationPayloadCodec.decode(WindowObserverConfig.self, from: payload, default: WindowObserverConfig())
                .normalized()
        }
        set {
            source = .windowObserver
            enabled = newValue.enabled
            payload = ConfigurationPayloadCodec.encode(newValue.normalized())
        }
    }
}

extension AutomationSettings {
    var windowObserverSettings: WindowObserverConfig {
        get {
            sourceConfiguration(for: .windowObserver).windowObserverSettings
        }
        set {
            updateSourceConfiguration(for: .windowObserver) {
                $0.windowObserverSettings = newValue
            }
        }
    }
}
