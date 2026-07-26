import Foundation

/// LLM connections are provider envelopes without prompts; prompts and task
/// assignments live in `PromptsSettings`. The envelope type is shared with the
/// historical summary-provider modules.
typealias LLMConnectionConfiguration = SummaryProviderConfiguration

/// Connection pool for every LLM call in the app. Timeout and retry count are
/// configured per connection (`SummaryProviderConfiguration.timeoutSec`/`retryCount`).
struct LLMSettings: Codable {
    var connections: [LLMConnectionConfiguration] = []

    /// Pre-per-connection global defaults. Decode-only: applied to connections
    /// that don't have their own explicit value, then dropped on next save.
    var legacyTimeoutSec: Int?
    var legacyRetryCount: Int?

    enum CodingKeys: String, CodingKey {
        case connections
        case timeoutSec
        case retryCount
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LLMSettings()
        connections = try container.decodeIfPresent([LLMConnectionConfiguration].self, forKey: .connections)
            ?? defaults.connections
        legacyTimeoutSec = try container.decodeIfPresent(Int.self, forKey: .timeoutSec)
        legacyRetryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(connections, forKey: .connections)
    }
}

extension LLMSettings {
    var enabledConnections: [LLMConnectionConfiguration] {
        connections.filter(\.enabled)
    }

    func connection(withID id: String?) -> LLMConnectionConfiguration? {
        guard let id else {
            return nil
        }
        return connections.first { $0.id == id }
    }
}

extension AppSettings {
    /// Ordered fallback chain for summarization. An empty explicit selection
    /// means Auto: all enabled connections in pool order.
    var summaryLLMChain: [LLMConnectionConfiguration] {
        llmChain(for: prompts.summary.connectionIDs)
    }

    /// Ordered fallback chain for transcript cleanup. An empty explicit selection
    /// means Auto: all enabled connections in pool order.
    var transcriptCleanupLLMChain: [LLMConnectionConfiguration] {
        llmChain(for: prompts.transcriptCleanup.connectionIDs)
    }

    /// The explicitly selected Live connection, or nil when Live is on Auto.
    var liveLLMConnection: LLMConnectionConfiguration? {
        guard let connection = llm.connection(withID: prompts.live.connectionID), connection.enabled else {
            return nil
        }
        return connection
    }

    /// Ordered fallback chain for Live transcript processing. No explicit
    /// selection means Auto: all enabled connections in pool order.
    var liveLLMChain: [LLMConnectionConfiguration] {
        guard let connection = liveLLMConnection else {
            return llm.enabledConnections
        }
        return [connection]
    }

    /// Resolves an explicit connection-ID selection against the pool.
    /// Empty selection or a selection that matches nothing falls back to Auto.
    private func llmChain(for connectionIDs: [String]) -> [LLMConnectionConfiguration] {
        let enabled = llm.enabledConnections
        guard !connectionIDs.isEmpty else {
            return enabled
        }
        let byID = Dictionary(uniqueKeysWithValues: enabled.map { ($0.id, $0) })
        let chain = connectionIDs.compactMap { byID[$0] }
        return chain.isEmpty ? enabled : chain
    }
}
