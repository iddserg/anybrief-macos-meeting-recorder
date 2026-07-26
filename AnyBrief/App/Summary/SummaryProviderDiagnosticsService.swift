import Foundation

struct SummaryProviderDiagnosticResult: Equatable {
    enum Status: Equatable {
        case success
        case warning
        case failure
    }

    let status: Status
    let message: String
}

actor SummaryProviderDiagnosticsService {
    private let registry: SummaryProviderRegistry
    private let context: SummaryProviderDiagnosticsContext
    private let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?

    init(
        registry: SummaryProviderRegistry = .default,
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)? = nil
    ) {
        self.registry = registry
        context = SummaryProviderDiagnosticsContext(session: session, fileManager: fileManager)
        self.logger = logger
    }

    func diagnose(
        configuration: SummaryProviderConfiguration,
        settings: AppSettings,
        openAIAPIKey: String
    ) async -> SummaryProviderDiagnosticResult {
        await log(
            "Summary provider diagnostic started: provider=\(configuration.provider.rawValue)",
            level: .info
        )
        do {
            let diagnostics = try registry.module(for: configuration.provider)
                .makeDiagnostics(context: context)
            let result = try await diagnostics.diagnose(
                configuration: configuration,
                settings: settings,
                openAIAPIKey: openAIAPIKey
            )
            await log(
                "Summary provider diagnostic completed: provider=\(configuration.provider.rawValue), status=\(result.status.logValue), message=\(result.message)",
                level: result.status == .failure ? .warn : .info
            )
            return result
        } catch {
            let result = SummaryProviderDiagnosticResult(status: .failure, message: error.localizedDescription)
            await log(
                "Summary provider diagnostic failed: provider=\(configuration.provider.rawValue), error=\(error.localizedDescription)",
                level: .warn
            )
            return result
        }
    }

    private func log(_ message: String, level: LoggingService.LogLevel) async {
        await logger?(message, level)
    }
}

enum SummaryProviderDiagnosticSupport {
    static func validateURL(_ value: String, field: String) throws -> URL {
        try validateNoSurroundingWhitespace(value, field: field)
        guard !value.isEmpty else {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ is empty."), field))
        }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ contains whitespace."), field))
        }
        if value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ contains control characters."), field))
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host?.isEmpty == false,
              let url = components.url else {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ must be a valid http(s) URL."), field))
        }
        return url
    }

    static func validateToken(_ value: String, field: String, allowSlash: Bool) throws -> String {
        try validateNoSurroundingWhitespace(value, field: field)
        guard !value.isEmpty else {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ is empty."), field))
        }
        if value.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ contains whitespace."), field))
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "._:-+")
        if allowSlash {
            allowed.insert("/")
        }
        if value.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ contains unsupported special characters."), field))
        }
        return value
    }

    static func validateSecret(_ value: String, field: String) throws -> String {
        try validateNoSurroundingWhitespace(value, field: field)
        guard !value.isEmpty else {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ is empty."), field))
        }
        if value.rangeOfCharacter(from: .newlines) != nil {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ contains a line break."), field))
        }
        return value
    }

    static func validateCommand(_ command: String) throws {
        try validateNoSurroundingWhitespace(command, field: String(localized: "Command"))
        guard !command.isEmpty else {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(localized: "Command is empty."))
        }
        if command.rangeOfCharacter(from: .newlines) != nil {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(localized: "Command contains a line break."))
        }
    }

    static func postJSON(
        _ body: Data,
        to url: URL,
        apiKey: String,
        timeout: TimeInterval,
        session: URLSession
    ) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SummaryProviderDiagnosticError.network(String(
                format: String(localized: "Network error for %@: %@"),
                HTTPJSONClient.safeURLDescription(url),
                error.localizedDescription
            ))
        }
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryProviderDiagnosticError.invalidResponse(String(localized: "Response is not HTTP."))
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let bodySnippet = String(data: data.prefix(500), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let suffix = bodySnippet?.isEmpty == false ? ": \(bodySnippet!)" : ""
            throw SummaryProviderDiagnosticError.http(String(
                format: String(localized: "HTTP %d from %@%@"),
                httpResponse.statusCode,
                HTTPJSONClient.safeURLDescription(url),
                suffix
            ))
        }
        return data
    }

    private static func validateNoSurroundingWhitespace(_ value: String, field: String) throws {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw SummaryProviderDiagnosticError.invalidConfiguration(String(format: String(localized: "%@ has leading or trailing whitespace."), field))
        }
    }
}

enum SummaryProviderDiagnosticError: LocalizedError {
    case invalidConfiguration(String)
    case invalidResponse(String)
    case network(String)
    case http(String)
    case timeout(String)
    case cli(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message),
             .invalidResponse(let message),
             .network(let message),
             .http(let message),
             .timeout(let message),
             .cli(let message):
            return message
        }
    }
}

private extension SummaryProviderDiagnosticResult.Status {
    var logValue: String {
        switch self {
        case .success:
            return "success"
        case .warning:
            return "warning"
        case .failure:
            return "failure"
        }
    }
}
