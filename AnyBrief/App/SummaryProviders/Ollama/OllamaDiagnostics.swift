import Foundation

struct OllamaDiagnostics: SummaryProviderDiagnostics {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func diagnose(
        configuration: SummaryProviderConfiguration,
        settings: AppSettings,
        openAIAPIKey: String
    ) async throws -> SummaryProviderDiagnosticResult {
        let apiURL = try SummaryProviderDiagnosticSupport.validateURL(
            OllamaDefaults.chatURLString,
            field: String(localized: "Local Endpoint")
        )
        let model = try SummaryProviderDiagnosticSupport.validateToken(
            configuration.ollamaEffectiveModel,
            field: String(localized: "Model"),
            allowSlash: true
        )
        let requestBody = try JSONEncoder().encode(OllamaChatRequest(
            model: model,
            messages: [
                SummaryMessage(role: "system", content: "You are a health-check endpoint."),
                SummaryMessage(role: "user", content: "Reply with OK."),
            ],
            stream: false,
            options: OllamaChatOptions(numCtx: OllamaSummaryProvider.normalizedContextLength(configuration.ollamaEffectiveContextLength))
        ))
        let data = try await SummaryProviderDiagnosticSupport.postJSON(
            requestBody,
            to: apiURL,
            apiKey: "",
            timeout: 20,
            session: session
        )
        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        guard !response.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryProviderDiagnosticError.invalidResponse(String(localized: "Ollama returned an empty message."))
        }
        return SummaryProviderDiagnosticResult(
            status: .success,
            message: String(localized: "Ollama OK. Model answered successfully.")
        )
    }
}
