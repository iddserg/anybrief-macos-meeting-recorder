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

    func metadata(settings: AppSettings) throws -> TranscriptionMetadata {
        let configuration = settings.transcription.activeProviderConfiguration
        return try providerRegistry.module(for: configuration.provider).metadata(
            configuration: configuration, diarizationEnabled: settings.transcription.diarizationEnabled
        )
    }

    func applyingSpeakerLimit(_ count: Int, to settings: AppSettings) -> AppSettings {
        var settings = settings
        let configuration = settings.transcription.activeProviderConfiguration
        guard let module = try? providerRegistry.module(for: configuration.provider) else { return settings }
        let overridden = module.applyingSpeakerLimit(count, to: configuration)
        if let index = settings.transcription.providers.firstIndex(where: { $0.id == configuration.id }) {
            settings.transcription.providers[index] = overridden
        } else {
            settings.transcription.providers.append(overridden)
        }
        return settings
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
