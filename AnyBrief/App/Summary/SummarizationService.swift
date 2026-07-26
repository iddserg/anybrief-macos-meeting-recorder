import Foundation

/// Orchestrates summarization: picks the prompt and connection chain from
/// settings, calls `LLMService`, and writes `summary.md`. All LLM traffic
/// happens in `LLMService`; this actor owns only summary-specific behavior.
actor SummarizationService {
    static let summaryFooter = "Recorded with [AnyBrief](https://anybrief.pro)"

    let fileManager: FileManager
    let isoFormatter: ISO8601DateFormatter
    let llmService: LLMService
    private let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?

    init(
        providerRegistry: SummaryProviderRegistry = .default,
        keychainStore: SecretStoreProtocol = SecretStoreFactory.makeDefault(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        llmService: LLMService? = nil,
        logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.logger = logger
        self.llmService = llmService ?? LLMService(
            providerRegistry: providerRegistry,
            keychainStore: keychainStore,
            session: session,
            fileManager: fileManager,
            sleep: sleep,
            logger: logger
        )
        isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func summarize(
        transcript: String,
        settings: AppSettings,
        meetingTitle: String? = nil,
        workingDirectory: URL? = nil,
        transcriptURL: URL? = nil
    ) async throws -> String {
        try await summarizeWithMetadata(
            transcript: transcript,
            settings: settings,
            meetingTitle: meetingTitle,
            workingDirectory: workingDirectory,
            transcriptURL: transcriptURL
        ).summary
    }

    func summarizeWithMetadata(
        transcript: String,
        settings: AppSettings,
        meetingTitle: String? = nil,
        workingDirectory: URL? = nil,
        transcriptURL: URL? = nil,
        progress: (@Sendable (LLMProgressEvent) async -> Void)? = nil
    ) async throws -> SummarizationResult {
        guard let prompt = settings.prompts.summaryPrompt(forMeetingTitle: meetingTitle) else {
            throw SummarizationError.missingConfiguration("summary prompt")
        }
        if let meetingTitle, prompt.id != settings.prompts.summary.promptID, prompt.matchesTitle(meetingTitle) {
            await log(
                "Summary prompt selected by title pattern: prompt=\(prompt.name.isEmpty ? prompt.id : prompt.name), title=\(meetingTitle)",
                level: .info
            )
        }
        let output = try await llmService.process(
            text: transcript,
            prompt: prompt.text,
            speakerContext: settings.prompts.trimmedSpeakerContext,
            connections: settings.summaryLLMChain,
            settings: settings,
            workingDirectory: workingDirectory,
            transcriptURL: transcriptURL,
            progress: progress
        )
        return SummarizationResult(
            summary: output.text,
            provider: output.provider
        )
    }

    func summarizationInput(transcript: String, metadata: SummaryMetadata?) -> String {
        guard let metadata else {
            return transcript
        }
        let frontmatter = metadataFrontmatter(metadata).joined(separator: "\n")
        guard !frontmatter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return transcript
        }
        return """
        Meeting metadata frontmatter:
        ```yaml
        \(frontmatter)
        ```

        Transcript:
        \(transcript)
        """
    }

    private func log(_ message: String, level: LoggingService.LogLevel) async {
        await logger?(message, level)
    }
}
