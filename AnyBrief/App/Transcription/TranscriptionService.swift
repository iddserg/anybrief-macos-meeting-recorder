import Foundation

/// Dispatches transcription work through the selected provider module.
actor TranscriptionService {
    private let providerRegistry: TranscriptionProviderRegistry
    private let providerContext: TranscriptionRuntimeContext

    init(
        providerRegistry: TranscriptionProviderRegistry = .default,
        fileManager: FileManager = .default
    ) {
        self.providerRegistry = providerRegistry
        providerContext = TranscriptionRuntimeContext(fileManager: fileManager)
    }

    func transcribe(
        input: TranscriptionInput,
        configuration: TranscriptionProviderConfiguration? = nil
    ) async throws -> TranscriptionResult {
        let normalized = providerRegistry.normalize(configuration ?? input.settings.transcription.activeProviderConfiguration)
        let module = try providerRegistry.module(for: normalized.provider)
        let provider = module.makeProvider(context: providerContext)
        return try await provider.transcribe(input: input)
    }
}
