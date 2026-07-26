import Foundation

struct OpenAICompatibleConfig: Codable, Equatable {
    var apiURL: String? = nil
    var apiKey = ""
    var apiKeyKeychainRef: String? = nil
    var model: String? = nil
}

extension SummaryProviderConfiguration {
    static func openAI() -> SummaryProviderConfiguration {
        var configuration = SummaryProviderConfiguration(provider: .openAICompatible)
        configuration.openAICompatibleConfig = OpenAICompatibleConfig()
        return configuration
    }

    var openAICompatibleConfig: OpenAICompatibleConfig {
        get {
            ConfigurationPayloadCodec.decode(OpenAICompatibleConfig.self, from: payload, default: OpenAICompatibleConfig())
        }
        set {
            provider = .openAICompatible
            payload = ConfigurationPayloadCodec.encode(newValue)
        }
    }

    var openAIEffectiveAPIURLString: String {
        openAICompatibleConfig.apiURL ?? ""
    }

    var openAIEffectiveModel: String {
        openAICompatibleConfig.model ?? ""
    }

    var openAIAPIURL: String? {
        get { openAICompatibleConfig.apiURL }
        set {
            var config = openAICompatibleConfig
            config.apiURL = newValue
            openAICompatibleConfig = config
        }
    }

    var openAIAPIKey: String {
        get { openAICompatibleConfig.apiKey }
        set {
            var config = openAICompatibleConfig
            config.apiKey = newValue
            openAICompatibleConfig = config
        }
    }

    var openAIAPIKeyKeychainRef: String? {
        get { openAICompatibleConfig.apiKeyKeychainRef }
        set {
            var config = openAICompatibleConfig
            config.apiKeyKeychainRef = newValue
            openAICompatibleConfig = config
        }
    }

    var openAIModel: String? {
        get { openAICompatibleConfig.model }
        set {
            var config = openAICompatibleConfig
            config.model = newValue
            openAICompatibleConfig = config
        }
    }

}
