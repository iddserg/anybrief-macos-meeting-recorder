import Foundation

enum SummarizationError: LocalizedError {
    case missingConfiguration(String)
    case apiUnavailable
    case network(Error, apiURL: URL)
    case server(statusCode: Int, apiURL: URL)
    case http(statusCode: Int, apiURL: URL)
    case invalidResponse
    case emptySummary
    case lowQualitySummary(reason: String)
    case cliAPIPreflightFailed(service: String, apiURL: URL, reason: String)
    case cliFailed(exitCode: Int32, stdout: String, stderr: String, transcriptPath: String, command: String)
    case cliTimeout(timeout: TimeInterval, transcriptPath: String, command: String)

    var errorDescription: String? {
        switch self {
        case let .missingConfiguration(name):
            return "Missing summarization configuration: \(name)."
        case .apiUnavailable:
            return "Summary API is unavailable."
        case let .network(error, apiURL):
            return "Summary API network error for \(Self.safeURLDescription(apiURL)): \(Self.networkErrorDescription(error))"
        case let .server(statusCode, apiURL):
            return "Summary API server error for \(Self.safeURLDescription(apiURL)): HTTP \(statusCode)."
        case let .http(statusCode, apiURL):
            return "Summary API request failed for \(Self.safeURLDescription(apiURL)): HTTP \(statusCode)."
        case .invalidResponse:
            return "Summary API returned an invalid response."
        case .emptySummary:
            return "Summary API returned an empty summary."
        case let .lowQualitySummary(reason):
            return "Summary API returned an unusable summary: \(reason)"
        case let .cliAPIPreflightFailed(service, apiURL, reason):
            return "\(service) API preflight failed for \(Self.safeURLDescription(apiURL)): \(reason)"
        case let .cliFailed(exitCode, stdout, stderr, transcriptPath, command):
            return "Summary CLI failed: exit_code=\(exitCode), stderr=\(Self.cliOutputExcerpt(stderr)), stdout=\(Self.cliOutputExcerpt(stdout)), transcript=\(transcriptPath), command=\(command)"
        case let .cliTimeout(timeout, transcriptPath, command):
            return "Summary CLI timed out after \(Int(timeout))s: transcript=\(transcriptPath), command=\(command)"
        }
    }

    private static func safeURLDescription(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.query = nil
        components.fragment = nil
        return components.string ?? url.absoluteString
    }

    private static func networkErrorDescription(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return "\(urlError.localizedDescription) (URLError \(urlError.code.rawValue))"
        }
        return error.localizedDescription
    }

    private static func cliOutputExcerpt(_ value: String, maxLength: Int = 4_000) -> String {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        guard normalized.count > maxLength else {
            return normalized.isEmpty ? "<empty>" : normalized
        }
        let start = normalized.index(normalized.endIndex, offsetBy: -maxLength)
        return "... " + normalized[start...]
    }
}
