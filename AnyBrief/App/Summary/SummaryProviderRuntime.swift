import Foundation

extension HTTPJSONClient {
    func sendSummary(
        requestBody: Data,
        apiURL: URL,
        apiKey: String,
        timeout: TimeInterval,
        provider: SummaryProvider,
        model: String,
        maxAttempts: Int
    ) async throws -> Data {
        let logContext = HTTPJSONClientLogContext(
            requestMessage: { url, attempt, attempts, requestBytes, timeout in
                "Summary API POST: provider=\(provider.rawValue), url=\(Self.safeURLDescription(url)), model=\(model), attempt=\(attempt)/\(attempts), request_bytes=\(requestBytes), timeout_sec=\(Int(max(1, timeout)))"
            },
            responseMessage: { url, statusCode, responseBytes in
                "Summary API response: url=\(Self.safeURLDescription(url)), status=\(statusCode), response_bytes=\(responseBytes)"
            },
            attemptFailureMessage: { attempt, attempts, error in
                "Summary API attempt failed: provider=\(provider.rawValue), attempt=\(attempt)/\(attempts), error=\(Self.summaryError(from: error).localizedDescription)"
            }
        )
        do {
            return try await send(
                requestBody: requestBody,
                apiURL: apiURL,
                apiKey: apiKey,
                timeout: timeout,
                retryPolicy: HTTPRetryPolicy(maxAttempts: maxAttempts),
                logContext: logContext
            )
        } catch {
            throw Self.summaryError(from: error)
        }
    }

    private static func summaryError(from error: Error) -> SummarizationError {
        switch error {
        case let error as SummarizationError:
            return error
        case let HTTPJSONClientError.network(error, apiURL):
            return .network(error, apiURL: apiURL)
        case let HTTPJSONClientError.server(statusCode, apiURL):
            return .server(statusCode: statusCode, apiURL: apiURL)
        case let HTTPJSONClientError.http(statusCode, apiURL):
            return .http(statusCode: statusCode, apiURL: apiURL)
        case HTTPJSONClientError.invalidResponse:
            return .invalidResponse
        case HTTPJSONClientError.unavailable:
            return .apiUnavailable
        default:
            return .apiUnavailable
        }
    }
}

enum SummaryPromptBuilder {
    static func systemPrompt(prompt: String, speakerContext: String = "", settings: AppSettings) -> String {
        let resolvedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let localizedPrompt = resolvedPrompt.replacingOccurrences(
            of: "%lang%",
            with: promptLanguageName(from: settings)
        )
        let trimmedContext = speakerContext.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContext.isEmpty else {
            return localizedPrompt
        }
        return """
        \(localizedPrompt)

        Additional speaker context:
        \(trimmedContext)
        """
    }

    private static func promptLanguageName(from settings: AppSettings) -> String {
        let languageIdentifier: String
        if settings.application.locale == "system" {
            languageIdentifier = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first
                ?? Locale.preferredLanguages.first
                ?? Locale.current.language.languageCode?.identifier
                ?? "en"
        } else {
            languageIdentifier = settings.application.locale
        }

        if languageIdentifier.hasPrefix("ru") {
            return "Russian"
        }
        if languageIdentifier.hasPrefix("en") {
            return "English"
        }

        let locale = Locale(identifier: "en")
        return locale.localizedString(forIdentifier: languageIdentifier)
            ?? Locale(identifier: languageIdentifier).localizedString(forIdentifier: languageIdentifier)
            ?? languageIdentifier
    }
}
