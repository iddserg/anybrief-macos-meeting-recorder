import Foundation

struct OpenAICompatibleRunner: SummaryProviderRunner {
    let provider: SummaryProvider = .openAICompatible

    private let keychainStore: SecretStoreProtocol
    private let httpClient: HTTPJSONClient

    init(
        keychainStore: SecretStoreProtocol = SecretStoreFactory.makeDefault(),
        httpClient: HTTPJSONClient = HTTPJSONClient()
    ) {
        self.keychainStore = keychainStore
        self.httpClient = httpClient
    }

    func summarize(input: SummaryProviderInput) async throws -> String {
        let apiURL = try summaryAPIURL(from: input.configuration)
        let apiKey = try summaryAPIKey(from: input.configuration)
        let model = input.configuration.openAIEffectiveModel
        let messages = [
            SummaryMessage(role: "system", content: input.systemPrompt),
            SummaryMessage(role: "user", content: input.transcript),
        ]
        let requestBody = try JSONEncoder().encode(SummaryRequest(model: model, messages: messages))
        let response = try await httpClient.sendSummary(
            requestBody: requestBody,
            apiURL: apiURL,
            apiKey: apiKey,
            timeout: TimeInterval(input.configuration.effectiveTimeoutSec),
            provider: provider,
            model: model,
            maxAttempts: input.configuration.effectiveRetryCount
        )
        return try parseSummary(from: response)
    }

    private func summaryAPIURL(from configuration: SummaryProviderConfiguration) throws -> URL {
        let value = configuration.openAIEffectiveAPIURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), !value.isEmpty else {
            throw SummarizationError.missingConfiguration("summary.providers[].apiURL")
        }
        return url
    }

    private func summaryAPIKey(from configuration: SummaryProviderConfiguration) throws -> String {
        guard let ref = configuration.openAIAPIKeyKeychainRef?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ref.isEmpty else {
            throw SummarizationError.missingConfiguration("summary.providers[].automation.localHTTPAPISettings.apiKey")
        }
        guard let apiKey = keychainStore.load(key: ref), !apiKey.isEmpty else {
            throw SummarizationError.missingConfiguration("summary API key")
        }
        return apiKey
    }

    private func parseSummary(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(SummaryResponse.self, from: data)
        guard let summary = response.choices.first?.message.content,
              !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.emptySummary
        }

        return summary
    }
}

typealias OpenAISummaryProvider = OpenAICompatibleRunner
