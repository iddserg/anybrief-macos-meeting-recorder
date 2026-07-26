import Foundation

struct SummaryProviderRegistry {
    let modules: [any SummaryProviderModule]

    static let `default` = SummaryProviderRegistry(modules: [
        OpenAICompatibleModule(),
        OllamaModule(),
        CLIModule(),
    ])

    private let modulesByID: [SummaryProvider: any SummaryProviderModule]

    init(modules: [any SummaryProviderModule]) {
        self.modules = modules
        modulesByID = Dictionary(uniqueKeysWithValues: modules.map { ($0.id, $0) })
    }

    func module(for provider: SummaryProvider) throws -> any SummaryProviderModule {
        guard let module = modulesByID[provider] else {
            throw SummarizationError.missingConfiguration("summary provider \(provider.rawValue)")
        }
        return module
    }

    func defaultConfiguration(for provider: SummaryProvider) throws -> SummaryProviderConfiguration {
        try module(for: provider).defaultConfiguration()
    }

    func normalize(_ configuration: SummaryProviderConfiguration) -> SummaryProviderConfiguration {
        (try? module(for: configuration.provider).normalize(configuration)) ?? configuration
    }
}
