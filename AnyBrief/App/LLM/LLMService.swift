import Foundation

struct LLMProgressEvent: Sendable {
    enum Kind: Sendable {
        case started
        case failed
        case completed
    }

    let kind: Kind
    let connectionName: String
    let connectionIndex: Int
    let connectionCount: Int
    let fallbackFrom: String?
}

/// Shared entry point for every LLM call in the app: text + prompt +
/// connection chain -> output. Owns the fallback across connections and the
/// runner runtime context. Summarization, live transcript processing, and
/// future text features all go through this service.
actor LLMService {
    struct Output {
        let text: String
        let provider: SummaryProviderMetadata
    }

    private let providerRegistry: SummaryProviderRegistry
    private let runtimeContext: SummaryProviderRuntimeContext
    private let fileManager: FileManager
    private let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?

    init(
        providerRegistry: SummaryProviderRegistry = .default,
        keychainStore: SecretStoreProtocol = SecretStoreFactory.makeDefault(),
        session: URLSession = .shared,
        fileManager: FileManager = .default,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { nanoseconds in
            try await Task.sleep(nanoseconds: nanoseconds)
        },
        logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)? = nil
    ) {
        self.providerRegistry = providerRegistry
        self.fileManager = fileManager
        self.logger = logger
        let httpClient = HTTPJSONClient(session: session, sleep: sleep, logger: logger)
        runtimeContext = SummaryProviderRuntimeContext(
            keychainStore: keychainStore,
            httpClient: httpClient,
            session: session,
            fileManager: fileManager,
            logger: logger
        )
    }

    func process(
        text: String,
        prompt: String,
        speakerContext: String = "",
        connections: [LLMConnectionConfiguration],
        settings: AppSettings,
        workingDirectory: URL? = nil,
        transcriptURL: URL? = nil,
        progress: (@Sendable (LLMProgressEvent) async -> Void)? = nil
    ) async throws -> Output {
        let systemPrompt = SummaryPromptBuilder.systemPrompt(
            prompt: prompt,
            speakerContext: speakerContext,
            settings: settings
        )

        // CLI runners need a working directory and an input file on disk.
        // Callers without a meeting folder (live transcript) get a temporary one.
        var scratchDirectory: URL?
        defer {
            if let scratchDirectory {
                try? fileManager.removeItem(at: scratchDirectory)
            }
        }
        var effectiveWorkingDirectory = workingDirectory
        var effectiveTranscriptURL = transcriptURL
        if effectiveWorkingDirectory == nil,
           connections.contains(where: { $0.enabled && $0.provider == .commandLine }) {
            let directory = fileManager.temporaryDirectory
                .appendingPathComponent("anybrief-llm", isDirectory: true)
                .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
                let inputURL = directory.appendingPathComponent("input.txt", isDirectory: false)
                try Data(text.utf8).write(to: inputURL, options: .atomic)
                scratchDirectory = directory
                effectiveWorkingDirectory = directory
                effectiveTranscriptURL = effectiveTranscriptURL ?? inputURL
            } catch {
                await log(
                    "LLM scratch directory unavailable for CLI connection: \(error.localizedDescription)",
                    level: .warn
                )
            }
        }

        var lastError: Error?
        var fallbackFrom: String?
        let enabledConnections = connections.filter(\.enabled)
        for (offset, configuration) in enabledConnections.enumerated() {
            var connectionName = configuration.name?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                let module = try providerRegistry.module(for: configuration.provider)
                let providerMetadata = module.metadata(from: configuration, settings: settings)
                if connectionName?.isEmpty != false {
                    connectionName = [providerMetadata.title, providerMetadata.model]
                        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                        .joined(separator: " · ")
                }
                let effectiveConnectionName = connectionName ?? configuration.provider.rawValue
                await progress?(LLMProgressEvent(
                    kind: .started,
                    connectionName: effectiveConnectionName,
                    connectionIndex: offset + 1,
                    connectionCount: enabledConnections.count,
                    fallbackFrom: fallbackFrom
                ))
                await log(
                    "LLM request started: provider=\(configuration.provider.rawValue), model=\(providerMetadata.model), text_chars=\(text.count), timeout_sec=\(configuration.effectiveTimeoutSec)",
                    level: .info
                )
                let runner = module.makeRunner(context: runtimeContext)
                if let message = module.runtimeLogMessage(
                    configuration: configuration,
                    workingDirectory: effectiveWorkingDirectory,
                    transcriptURL: effectiveTranscriptURL
                ) {
                    await log(message, level: .info)
                }
                let output = try await runner.summarize(input: SummaryProviderInput(
                    transcript: text,
                    systemPrompt: systemPrompt,
                    settings: settings,
                    configuration: configuration,
                    workingDirectory: effectiveWorkingDirectory,
                    transcriptURL: effectiveTranscriptURL
                ))
                await log(
                    "LLM request completed: provider=\(configuration.provider.rawValue), model=\(providerMetadata.model), output_chars=\(output.count)",
                    level: .info
                )
                await progress?(LLMProgressEvent(
                    kind: .completed,
                    connectionName: effectiveConnectionName,
                    connectionIndex: offset + 1,
                    connectionCount: enabledConnections.count,
                    fallbackFrom: fallbackFrom
                ))
                return Output(text: output, provider: providerMetadata)
            } catch {
                let effectiveConnectionName = connectionName ?? configuration.provider.rawValue
                await log(
                    "LLM request failed: provider=\(configuration.provider.rawValue), error=\(error.localizedDescription)",
                    level: .warn
                )
                await progress?(LLMProgressEvent(
                    kind: .failed,
                    connectionName: effectiveConnectionName,
                    connectionIndex: offset + 1,
                    connectionCount: enabledConnections.count,
                    fallbackFrom: fallbackFrom
                ))
                fallbackFrom = effectiveConnectionName
                lastError = error
            }
        }
        throw lastError ?? SummarizationError.apiUnavailable
    }

    private func log(_ message: String, level: LoggingService.LogLevel) async {
        await logger?(message, level)
    }
}
