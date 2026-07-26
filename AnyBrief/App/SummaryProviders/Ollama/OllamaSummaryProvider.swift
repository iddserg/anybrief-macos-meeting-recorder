import Foundation

struct OllamaSummaryProvider: SummaryProviderRunner {
    let provider: SummaryProvider = .localOllama

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
        let apiKey = summaryAPIKey(from: input.configuration)
        let chunkThreshold = normalizedContextThreshold(input.configuration.ollamaEffectiveChunkThreshold)
        if input.transcript.count > chunkThreshold {
            return try await summarizeInChunks(
                transcript: input.transcript,
                configuration: input.configuration,
                basePrompt: input.systemPrompt,
                apiURL: apiURL,
                apiKey: apiKey
            )
        }

        let summary = try await summarizeOnce(
            transcript: input.transcript,
            configuration: input.configuration,
            apiURL: apiURL,
            apiKey: apiKey,
            model: input.configuration.ollamaEffectiveModel,
            contextLength: input.configuration.ollamaEffectiveContextLength,
            systemPrompt: input.systemPrompt
        )
        try validate(summary: summary, for: input.transcript)
        return summary
    }

    private func summarizeInChunks(
        transcript: String,
        configuration: SummaryProviderConfiguration,
        basePrompt: String,
        apiURL: URL,
        apiKey: String
    ) async throws -> String {
        let chunkSize = normalizedChunkSize(configuration.ollamaEffectiveChunkSize)
        let chunks = transcriptChunks(from: transcript, maxCharacters: chunkSize)
        var chunkSummaries: [String] = []

        for index in chunks.indices {
            let prompt = """
            \(basePrompt)

            You are summarizing part \(index + 1) of \(chunks.count) of one meeting transcript.
            Produce concise Markdown notes for this part only.
            Include decisions, action items, risks, blockers, and important context.
            Do not copy raw timestamps or transcript lines.
            """
            let chunkSummary = try await summarizeOnce(
                transcript: chunks[index],
                configuration: configuration,
                apiURL: apiURL,
                apiKey: apiKey,
                model: configuration.ollamaEffectiveModel,
                contextLength: configuration.ollamaEffectiveContextLength,
                systemPrompt: prompt
            )
            try validate(summary: chunkSummary, for: chunks[index])
            chunkSummaries.append(chunkSummary)
        }

        let finalPrompt = """
        \(basePrompt)

        Combine these partial meeting summaries into one final concise Markdown summary.
        Remove duplicates. Preserve concrete decisions, action items, risks, blockers, and names when present.
        Do not mention that the source was split into parts.
        """
        let combinedSummary = try await summarizeOnce(
            transcript: chunkSummaries.enumerated().map { index, summary in
                "## Part \(index + 1)\n\(summary)"
            }.joined(separator: "\n\n"),
            configuration: configuration,
            apiURL: apiURL,
            apiKey: apiKey,
            model: configuration.ollamaEffectiveModel,
            contextLength: configuration.ollamaEffectiveContextLength,
            systemPrompt: finalPrompt
        )
        try validate(summary: combinedSummary, for: transcript)
        return combinedSummary
    }

    private func summarizeOnce(
        transcript: String,
        configuration: SummaryProviderConfiguration,
        apiURL: URL,
        apiKey: String,
        model: String,
        contextLength: Int,
        systemPrompt: String
    ) async throws -> String {
        let messages = [
            SummaryMessage(role: "system", content: systemPrompt),
            SummaryMessage(role: "user", content: transcript),
        ]
        let requestBody = try JSONEncoder().encode(OllamaChatRequest(
            model: model,
            messages: messages,
            stream: false,
            options: OllamaChatOptions(numCtx: normalizedContextLength(contextLength))
        ))
        let response = try await httpClient.sendSummary(
            requestBody: requestBody,
            apiURL: apiURL,
            apiKey: apiKey,
            timeout: TimeInterval(configuration.effectiveTimeoutSec),
            provider: provider,
            model: model,
            maxAttempts: configuration.effectiveRetryCount
        )
        return try parseSummary(from: response)
    }

    private func summaryAPIURL(from configuration: SummaryProviderConfiguration) throws -> URL {
        let value = configuration.ollamaEffectiveAPIURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), !value.isEmpty else {
            throw SummarizationError.missingConfiguration("summary.providers[].apiURL")
        }
        return url
    }

    private func summaryAPIKey(from configuration: SummaryProviderConfiguration) -> String {
        ""
    }

    private func parseSummary(from data: Data) throws -> String {
        let response = try JSONDecoder().decode(OllamaChatResponse.self, from: data)
        let summary = response.message.content
        guard !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummarizationError.emptySummary
        }

        return summary
    }

    private func validate(summary: String, for transcript: String) throws {
        let trimmed = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard transcript.count > 2_000 else {
            return
        }

        if trimmed.count < 120 {
            throw SummarizationError.lowQualitySummary(reason: "Summary is too short for the transcript size.")
        }

        let letterCount = trimmed.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        if letterCount < 40 {
            throw SummarizationError.lowQualitySummary(reason: "Summary does not contain enough natural language content.")
        }
    }

    private func transcriptChunks(from transcript: String, maxCharacters: Int) -> [String] {
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var chunks: [String] = []
        var current = ""

        for line in lines {
            if current.count + line.count + 1 > maxCharacters, !current.isEmpty {
                chunks.append(current)
                current = ""
            }

            if line.count > maxCharacters {
                var remainder = line
                while remainder.count > maxCharacters {
                    let splitIndex = remainder.index(remainder.startIndex, offsetBy: maxCharacters)
                    chunks.append(String(remainder[..<splitIndex]))
                    remainder = String(remainder[splitIndex...])
                }
                if !remainder.isEmpty {
                    current = current.isEmpty ? remainder : "\(current)\n\(remainder)"
                }
            } else {
                current = current.isEmpty ? line : "\(current)\n\(line)"
            }
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks.isEmpty ? [transcript] : chunks
    }

    static func normalizedContextLength(_ value: Int) -> Int {
        min(max(value, 4_096), 256_000)
    }

    static func normalizedContextThreshold(_ value: Int) -> Int {
        let resolved = value == 0 ? OllamaDefaults.chunkThreshold : value
        return min(max(resolved, 4_000), 120_000)
    }

    static func normalizedChunkSize(_ value: Int) -> Int {
        let resolved = value == 0 ? OllamaDefaults.chunkSize : value
        return min(max(resolved, 2_000), 60_000)
    }

    private func normalizedContextLength(_ value: Int) -> Int {
        Self.normalizedContextLength(value)
    }

    private func normalizedContextThreshold(_ value: Int) -> Int {
        Self.normalizedContextThreshold(value)
    }

    private func normalizedChunkSize(_ value: Int) -> Int {
        Self.normalizedChunkSize(value)
    }
}
