import Foundation

struct OpenAICompatibleDiagnostics: SummaryProviderDiagnostics {
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
            configuration.openAIEffectiveAPIURLString,
            field: String(localized: "API URL")
        )
        let model = try SummaryProviderDiagnosticSupport.validateToken(
            configuration.openAIEffectiveModel,
            field: String(localized: "Model"),
            allowSlash: true
        )
        let key = try SummaryProviderDiagnosticSupport.validateSecret(
            openAIAPIKey,
            field: String(localized: "API key")
        )
        let requestBody = try JSONEncoder().encode(SummaryRequest(
            model: model,
            messages: [
                SummaryMessage(role: "system", content: "You are a health-check endpoint."),
                SummaryMessage(role: "user", content: "Reply with OK."),
            ]
        ))
        let data = try await SummaryProviderDiagnosticSupport.postJSON(
            requestBody,
            to: apiURL,
            apiKey: key,
            timeout: 20,
            session: session
        )
        let response = try JSONDecoder().decode(SummaryResponse.self, from: data)
        guard response.choices.first?.message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw SummaryProviderDiagnosticError.invalidResponse(String(localized: "Provider returned an empty message."))
        }
        return SummaryProviderDiagnosticResult(
            status: .success,
            message: String(localized: "Connection OK. Model answered successfully.")
        )
    }
}
