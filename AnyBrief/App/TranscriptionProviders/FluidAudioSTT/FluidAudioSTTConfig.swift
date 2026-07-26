import Foundation

struct FluidAudioSTTConfig: Codable, Equatable {
    var speakersMode = "auto"
    var speakersCount = 2
    var threshold = 0.65
    var customVocabulary = ""

    enum CodingKeys: String, CodingKey {
        case speakersMode
        case speakersCount
        case threshold
        case customVocabulary
    }

    init(
        speakersMode: String = "auto",
        speakersCount: Int = 2,
        threshold: Double = 0.65,
        customVocabulary: String = ""
    ) {
        self.speakersMode = speakersMode
        self.speakersCount = speakersCount
        self.threshold = threshold
        self.customVocabulary = customVocabulary
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        speakersMode = try container.decodeIfPresent(String.self, forKey: .speakersMode) ?? "auto"
        speakersCount = try container.decodeIfPresent(Int.self, forKey: .speakersCount) ?? 2
        threshold = try container.decodeIfPresent(Double.self, forKey: .threshold) ?? 0.65
        customVocabulary = try container.decodeIfPresent(String.self, forKey: .customVocabulary) ?? ""
    }

    func normalized() -> FluidAudioSTTConfig {
        FluidAudioSTTConfig(
            speakersMode: ["auto", "calendar", "fixed", "max"].contains(speakersMode) ? speakersMode : "auto",
            speakersCount: max(1, min(10, speakersCount)),
            threshold: max(0.1, min(1.0, threshold)),
            customVocabulary: customVocabulary
        )
    }
}

extension TranscriptionProviderConfiguration {
    static func fluidAudioSTT(
        id: String = UUID().uuidString.lowercased(),
        enabled: Bool = true,
        config: FluidAudioSTTConfig = FluidAudioSTTConfig()
    ) -> TranscriptionProviderConfiguration {
        TranscriptionProviderConfiguration(
            id: id,
            provider: .fluidAudioSTT,
            enabled: enabled,
            payload: ConfigurationPayloadCodec.encode(config.normalized())
        )
    }

    var fluidAudioSTTConfig: FluidAudioSTTConfig {
        get {
            ConfigurationPayloadCodec.decode(
                FluidAudioSTTConfig.self,
                from: payload,
                default: FluidAudioSTTConfig()
            ).normalized()
        }
        set {
            payload = ConfigurationPayloadCodec.encode(newValue.normalized())
        }
    }
}

extension TranscriptionSettings {
    var fluidAudioSTTConfiguration: TranscriptionProviderConfiguration {
        get {
            providers.first { $0.provider == .fluidAudioSTT } ?? .fluidAudioSTT()
        }
        set {
            let index = providers.firstIndex { $0.provider == .fluidAudioSTT }
            var configuration = newValue
            configuration.provider = .fluidAudioSTT
            if let index {
                providers[index] = configuration
            } else {
                providers.append(configuration)
            }
        }
    }

    var fluidAudioSTTConfig: FluidAudioSTTConfig {
        get {
            fluidAudioSTTConfiguration.fluidAudioSTTConfig
        }
        set {
            var configuration = fluidAudioSTTConfiguration
            configuration.fluidAudioSTTConfig = newValue
            fluidAudioSTTConfiguration = configuration
        }
    }
}
