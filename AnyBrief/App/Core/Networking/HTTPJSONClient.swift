import Foundation

/// Neutral JSON-over-HTTP client for provider modules.
struct HTTPJSONClient {
    private let session: URLSession
    private let sleep: @Sendable (UInt64) async throws -> Void
    private let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?

    init(
        session: URLSession = .shared,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)? = nil
    ) {
        self.session = session
        self.sleep = sleep
        self.logger = logger
    }

    func send(
        requestBody: Data,
        apiURL: URL,
        apiKey: String,
        timeout: TimeInterval,
        retryPolicy: HTTPRetryPolicy,
        logContext: HTTPJSONClientLogContext? = nil
    ) async throws -> Data {
        let attempts = retryPolicy.attempts
        var lastError: Error?

        for attempt in 1...attempts {
            do {
                if let logContext {
                    await log(
                        logContext.requestMessage(
                            apiURL,
                            attempt,
                            attempts,
                            requestBody.count,
                            timeout
                        ),
                        level: .info
                    )
                }
                return try await sendOnce(
                    requestBody: requestBody,
                    apiURL: apiURL,
                    apiKey: apiKey,
                    timeout: timeout,
                    logContext: logContext
                )
            } catch {
                if let logContext {
                    await log(
                        logContext.attemptFailureMessage(attempt, attempts, error),
                        level: .warn
                    )
                }
                lastError = error
                guard attempt < attempts, retryPolicy.isRetryable(error) else {
                    throw error
                }
                try await sleep(retryPolicy.delayNanoseconds(afterFailedAttempt: attempt))
            }
        }

        throw lastError ?? HTTPJSONClientError.unavailable
    }

    private func sendOnce(
        requestBody: Data,
        apiURL: URL,
        apiKey: String,
        timeout: TimeInterval,
        logContext: HTTPJSONClientLogContext?
    ) async throws -> Data {
        var request = URLRequest(url: apiURL, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = requestBody

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HTTPJSONClientError.network(error, apiURL: apiURL)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw HTTPJSONClientError.invalidResponse
        }
        if let logContext {
            await log(
                logContext.responseMessage(apiURL, httpResponse.statusCode, data.count),
                level: (200...299).contains(httpResponse.statusCode) ? .info : .warn
            )
        }
        guard !(500...599).contains(httpResponse.statusCode) else {
            throw HTTPJSONClientError.server(statusCode: httpResponse.statusCode, apiURL: apiURL)
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            throw HTTPJSONClientError.http(statusCode: httpResponse.statusCode, apiURL: apiURL)
        }

        return data
    }

    static func safeURLDescription(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private func log(_ message: String, level: LoggingService.LogLevel) async {
        await logger?(message, level)
    }
}

struct HTTPJSONClientLogContext {
    let requestMessage: (URL, Int, Int, Int, TimeInterval) -> String
    let responseMessage: (URL, Int, Int) -> String
    let attemptFailureMessage: (Int, Int, Error) -> String
}

enum HTTPJSONClientError: Error {
    case network(Error, apiURL: URL)
    case server(statusCode: Int, apiURL: URL)
    case http(statusCode: Int, apiURL: URL)
    case invalidResponse
    case unavailable
}
