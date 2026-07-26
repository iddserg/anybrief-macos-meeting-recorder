import Foundation

struct TranscriptionProviderRegistry {
    let modules: [any TranscriptionProviderModule]

    static let `default` = TranscriptionProviderRegistry(modules: [
        FluidAudioSTTModule(),
        WhisperCppModule(),
    ])

    private let modulesByID: [TranscriptionProviderID: any TranscriptionProviderModule]

    init(modules: [any TranscriptionProviderModule]) {
        self.modules = modules
        modulesByID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
    }

    func module(for provider: TranscriptionProviderID) throws -> any TranscriptionProviderModule {
        guard let module = modulesByID[provider] else {
            throw TranscriptionError(message: "Missing transcription provider \(provider.rawValue).")
        }
        return module
    }

    func defaultConfiguration(for provider: TranscriptionProviderID) throws -> TranscriptionProviderConfiguration {
        try module(for: provider).defaultConfiguration()
    }

    func normalize(_ configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration {
        (try? module(for: configuration.provider).normalize(configuration)) ?? configuration
    }
}
