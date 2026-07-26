import Foundation

enum SummaryProvider: String, Codable, CaseIterable, Identifiable {
    case openAICompatible = "openai_compatible"
    case localOllama = "local_ollama"
    case commandLine = "cli"

    var id: String { rawValue }
}

/// LLM connection envelope: a configured provider without a prompt.
/// Provider-specific settings are stored in `payload` and decoded by provider-owned typed accessors.
struct SummaryProviderConfiguration: Codable, Identifiable, Equatable {
    static let defaultTimeoutSec = 300
    static let defaultRetryCount = 3

    var id = UUID().uuidString.lowercased()
    var provider: SummaryProvider = .openAICompatible
    var name: String?
    var enabled = true
    /// nil falls back to `defaultTimeoutSec`/`defaultRetryCount`; each connection is independent.
    var timeoutSec: Int?
    var retryCount: Int?
    var payload: ConfigurationPayload = [:]

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case name
        case enabled
        case timeoutSec
        case retryCount
        case payload
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        provider: SummaryProvider = .openAICompatible,
        name: String? = nil,
        enabled: Bool = true,
        timeoutSec: Int? = nil,
        retryCount: Int? = nil,
        payload: ConfigurationPayload = [:]
    ) {
        self.id = id
        self.provider = provider
        self.name = name
        self.enabled = enabled
        self.timeoutSec = timeoutSec
        self.retryCount = retryCount
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        provider = try container.decodeIfPresent(SummaryProvider.self, forKey: .provider) ?? .openAICompatible
        name = try container.decodeIfPresent(String.self, forKey: .name)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        timeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount)
        payload = try container.decodeIfPresent(ConfigurationPayload.self, forKey: .payload) ?? [:]
    }

    var effectiveTimeoutSec: Int {
        max(1, timeoutSec ?? Self.defaultTimeoutSec)
    }

    var effectiveRetryCount: Int {
        max(1, retryCount ?? Self.defaultRetryCount)
    }
}
