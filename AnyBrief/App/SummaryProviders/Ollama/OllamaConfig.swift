import Foundation

struct OllamaConfig: Codable, Equatable {
    var model: String? = ""
    var contextLength: Int? = OllamaDefaults.contextLength
    var chunkThreshold: Int? = OllamaDefaults.chunkThreshold
    var chunkSize: Int? = OllamaDefaults.chunkSize

    var effectiveContextLength: Int {
        contextLength ?? OllamaDefaults.contextLength
    }

    var effectiveChunkThreshold: Int {
        chunkThreshold ?? OllamaDefaults.chunkThreshold
    }

    var effectiveChunkSize: Int {
        chunkSize ?? OllamaDefaults.chunkSize
    }
}

extension SummaryProviderConfiguration {
    static func ollama() -> SummaryProviderConfiguration {
        var configuration = SummaryProviderConfiguration(provider: .localOllama)
        configuration.ollamaConfig = OllamaConfig()
        return configuration
    }

    var ollamaConfig: OllamaConfig {
        get {
            ConfigurationPayloadCodec.decode(OllamaConfig.self, from: payload, default: OllamaConfig())
        }
        set {
            provider = .localOllama
            payload = ConfigurationPayloadCodec.encode(newValue)
        }
    }

    var ollamaEffectiveAPIURLString: String {
        OllamaDefaults.chatURLString
    }

    var ollamaEffectiveModel: String {
        ollamaConfig.model ?? ""
    }

    var ollamaEffectiveContextLength: Int {
        ollamaConfig.effectiveContextLength
    }

    var ollamaEffectiveChunkThreshold: Int {
        ollamaConfig.effectiveChunkThreshold
    }

    var ollamaEffectiveChunkSize: Int {
        ollamaConfig.effectiveChunkSize
    }

    var ollamaModel: String? {
        get { ollamaConfig.model }
        set {
            var config = ollamaConfig
            config.model = newValue
            ollamaConfig = config
        }
    }

    var ollamaContextLength: Int? {
        get { ollamaConfig.contextLength }
        set {
            var config = ollamaConfig
            config.contextLength = newValue
            ollamaConfig = config
        }
    }

    var ollamaChunkThreshold: Int? {
        get { ollamaConfig.chunkThreshold }
        set {
            var config = ollamaConfig
            config.chunkThreshold = newValue
            ollamaConfig = config
        }
    }

    var ollamaChunkSize: Int? {
        get { ollamaConfig.chunkSize }
        set {
            var config = ollamaConfig
            config.chunkSize = newValue
            ollamaConfig = config
        }
    }
}
