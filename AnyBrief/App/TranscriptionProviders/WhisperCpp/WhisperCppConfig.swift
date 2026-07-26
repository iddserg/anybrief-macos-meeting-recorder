import Foundation

struct WhisperCppConfig: Codable, Equatable {
    var model = "small"
    var language = "auto"
    var useGPU = true
    var speakersMode = "auto"
    var speakersCount = 2
    var threshold = 0.65
    var customVocabulary = ""

    enum CodingKeys: String, CodingKey {
        case model
        case language
        case useGPU
        case speakersMode
        case speakersCount
        case threshold
        case customVocabulary
    }

    init(
        model: String = "small",
        language: String = "auto",
        useGPU: Bool = true,
        speakersMode: String = "auto",
        speakersCount: Int = 2,
        threshold: Double = 0.65,
        customVocabulary: String = ""
    ) {
        self.model = model
        self.language = language
        self.useGPU = useGPU
        self.speakersMode = speakersMode
        self.speakersCount = speakersCount
        self.threshold = threshold
        self.customVocabulary = customVocabulary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? "small"
        language = try container.decodeIfPresent(String.self, forKey: .language) ?? "auto"
        useGPU = try container.decodeIfPresent(Bool.self, forKey: .useGPU) ?? true
        speakersMode = try container.decodeIfPresent(String.self, forKey: .speakersMode) ?? "auto"
        speakersCount = try container.decodeIfPresent(Int.self, forKey: .speakersCount) ?? 2
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.65
        customVocabulary = try container.decodeIfPresent(String.self, forKey: .customVocabulary) ?? ""
    }

    func normalized() -> WhisperCppConfig {
        WhisperCppConfig(
            model: WhisperCppModelService.model(named: model)?.id ?? "small",
            language: WhisperCppModelService.supportedLanguageCodes.contains(language) ? language : "auto",
            useGPU: useGPU,
            speakersMode: ["auto", "calendar", "fixed", "max"].contains(speakersMode) ? speakersMode : "auto",
            speakersCount: max(1, min(10, speakersCount)),
            threshold: max(0.1, min(1.0, threshold)),
            customVocabulary: customVocabulary
        )
    }
}

extension TranscriptionProviderConfiguration {
    static func whisperCpp(
        id: String = UUID().uuidString.lowercased(),
        enabled: Bool = false,
        config: WhisperCppConfig = WhisperCppConfig()
    ) -> TranscriptionProviderConfiguration {
        TranscriptionProviderConfiguration(
            id: id,
            provider: .whisperCpp,
            enabled: enabled,
            payload: ConfigurationPayloadCodec.encode(config.normalized())
        )
    }

    var whisperCppConfig: WhisperCppConfig {
        get {
            ConfigurationPayloadCodec.decode(
                WhisperCppConfig.self,
                from: payload,
                default: WhisperCppConfig()
            ).normalized()
        }
        set {
            payload = ConfigurationPayloadCodec.encode(newValue.normalized())
        }
    }
}

extension TranscriptionSettings {
    var whisperCppConfiguration: TranscriptionProviderConfiguration {
        get {
            providers.first { $0.provider == .whisperCpp } ?? .whisperCpp()
        }
        set {
            let index = providers.firstIndex { $0.provider == .whisperCpp }
            var configuration = newValue
            configuration.provider = .whisperCpp
            if let index {
                providers[index] = configuration
            } else {
                providers.append(configuration)
            }
        }
    }

    var whisperCppConfig: WhisperCppConfig {
        get {
            whisperCppConfiguration.whisperCppConfig
        }
        set {
            var configuration = whisperCppConfiguration
            configuration.whisperCppConfig = newValue
            whisperCppConfiguration = configuration
        }
    }

    mutating func selectProvider(_ provider: TranscriptionProviderID) {
        for index in providers.indices {
            providers[index].enabled = providers[index].provider == provider
        }
        if !providers.contains(where: { $0.provider == provider }) {
            switch provider {
            case .fluidAudioSTT:
                providers.append(.fluidAudioSTT())
            case .whisperCpp:
                providers.append(.whisperCpp(enabled: true))
            }
        }
    }
}
