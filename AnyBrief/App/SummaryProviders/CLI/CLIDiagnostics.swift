import Foundation

struct CLIDiagnostics: SummaryProviderDiagnostics {
    private let session: URLSession
    private let fileManager: FileManager

    init(session: URLSession = .shared, fileManager: FileManager = .default) {
        self.session = session
        self.fileManager = fileManager
    }

    func diagnose(
        configuration: SummaryProviderConfiguration,
        settings: AppSettings,
        openAIAPIKey: String
    ) async throws -> SummaryProviderDiagnosticResult {
        let command = CLISummaryProvider.resolvedCommand(configuration)
        try SummaryProviderDiagnosticSupport.validateCommand(command)
        let diagnosticPrompt = """
        This is an AnyBrief CLI provider health check.
        Return only OK.
        """
        let diagnosticSettings = settings
        let workingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("anybrief-summary-diagnostic-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: workingDirectory)
        }
        let transcriptURL = workingDirectory.appendingPathComponent("transcript.txt", isDirectory: false)
        let transcript = "AnyBrief diagnostic transcript. The correct response is OK."
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let input = SummaryProviderInput(
            transcript: transcript,
            systemPrompt: diagnosticPrompt,
            settings: diagnosticSettings,
            configuration: configuration,
            workingDirectory: workingDirectory,
            transcriptURL: transcriptURL
        )
        let producedOutput: String
        do {
            let summary = try await CLISummaryProvider(
                session: session,
                fileManager: fileManager
            ).summarize(input: input)
            producedOutput = summary
                .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch let error as SummarizationError {
            throw diagnosticError(from: error)
        }
        guard !producedOutput.isEmpty else {
            throw SummaryProviderDiagnosticError.invalidResponse(String(localized: "CLI finished but returned an empty response."))
        }
        guard producedOutput.localizedCaseInsensitiveContains("OK") else {
            throw SummaryProviderDiagnosticError.invalidResponse(String(localized: "CLI finished but did not return the expected OK response."))
        }
        return SummaryProviderDiagnosticResult(
            status: .success,
            message: String(localized: "CLI OK. Command executed and returned OK.")
        )
    }

    private func diagnosticError(from error: SummarizationError) -> SummaryProviderDiagnosticError {
        switch error {
        case let .cliTimeout(timeout, _, _):
            return .timeout(String(format: String(localized: "CLI check timed out after %d seconds."), Int(timeout)))
        case let .cliFailed(exitCode, stdout, stderr, _, _):
            let details = stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                : stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if let message = claudeAuthenticationHint(from: details) {
                return .cli(message)
            }
            return .cli(String(
                format: String(localized: "CLI exited with %d: %@"),
                exitCode,
                details.isEmpty ? "<empty>" : details
            ))
        case .emptySummary:
            return .invalidResponse(String(localized: "CLI finished but returned an empty response."))
        case let .missingConfiguration(name):
            return .invalidConfiguration(String(format: String(localized: "Missing summarization configuration: %@."), name))
        default:
            return .cli(error.localizedDescription)
        }
    }

    private func claudeAuthenticationHint(from details: String) -> String? {
        let plain = details
            .replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard plain.localizedCaseInsensitiveContains("not logged in"),
              plain.localizedCaseInsensitiveContains("login") else {
            return nil
        }
        return String(localized: "Claude CLI is not authenticated for non-interactive runs. Run `claude auth login` in Terminal, or `claude setup-token` for a long-lived Claude subscription token, then try again.")
    }
}
