import Foundation

/// The listener is hard-bound to 127.0.0.1 (see LocalAPIListenerFactory);
/// there is intentionally no configurable bind host.
struct LocalHTTPAPISettings: Codable {
    var enabled = false
    var port = 47_823
    var apiKey = ""
    var apiKeyKeychainRef: String? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LocalHTTPAPISettings()
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? defaults.port
        apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
        apiKeyKeychainRef = try container.decodeIfPresent(String.self, forKey: .apiKeyKeychainRef)
    }
}

extension AutomationSourceConfiguration {
    static func localHTTPAPI(_ settings: LocalHTTPAPISettings = LocalHTTPAPISettings()) -> AutomationSourceConfiguration {
        AutomationSourceConfiguration(
            source: .localHTTPAPI,
            enabled: settings.enabled,
            payload: ConfigurationPayloadCodec.encode(settings)
        )
    }

    var localHTTPAPISettings: LocalHTTPAPISettings {
        get {
            ConfigurationPayloadCodec.decode(LocalHTTPAPISettings.self, from: payload, default: LocalHTTPAPISettings())
        }
        set {
            source = .localHTTPAPI
            enabled = newValue.enabled
            payload = ConfigurationPayloadCodec.encode(newValue)
        }
    }
}

extension AutomationSettings {
    var localHTTPAPISettings: LocalHTTPAPISettings {
        get {
            sourceConfiguration(for: .localHTTPAPI).localHTTPAPISettings
        }
        set {
            updateSourceConfiguration(for: .localHTTPAPI) {
                $0.localHTTPAPISettings = newValue
            }
        }
    }
}
