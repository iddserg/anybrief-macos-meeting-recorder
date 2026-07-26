import Foundation
import SwiftUI

struct OllamaModule: SummaryProviderModule {
    let id: SummaryProvider = .localOllama
    let title = "Local Ollama"
    let systemImage = "desktopcomputer"
    let allowsMultipleConfigurations = true

    func defaultConfiguration() -> SummaryProviderConfiguration {
        .ollama()
    }

    func normalize(_ configuration: SummaryProviderConfiguration) -> SummaryProviderConfiguration {
        var normalized = configuration
        var config = normalized.ollamaConfig
        if config.contextLength == nil {
            config.contextLength = OllamaDefaults.contextLength
        }
        if config.chunkThreshold == nil {
            config.chunkThreshold = OllamaDefaults.chunkThreshold
        }
        if config.chunkSize == nil {
            config.chunkSize = OllamaDefaults.chunkSize
        }
        normalized.ollamaConfig = config
        return normalized
    }

    func makeRunner(context: SummaryProviderRuntimeContext) -> any SummaryProviderRunner {
        OllamaSummaryProvider(
            keychainStore: context.keychainStore,
            httpClient: context.httpClient
        )
    }

    func makeDiagnostics(context: SummaryProviderDiagnosticsContext) -> any SummaryProviderDiagnostics {
        OllamaDiagnostics(session: context.session)
    }

    @MainActor
    func makeSettingsView(context: SummaryProviderSettingsViewContext) -> AnyView {
        AnyView(OllamaSettingsView(configuration: context.configuration))
    }

    func metadata(from configuration: SummaryProviderConfiguration, settings: AppSettings) -> SummaryProviderMetadata {
        SummaryProviderMetadata(
            type: configuration.provider,
            title: title,
            model: configuration.ollamaEffectiveModel,
            apiURL: configuration.ollamaEffectiveAPIURLString,
            timeoutSec: configuration.effectiveTimeoutSec,
            retryCount: configuration.effectiveRetryCount,
            commandPreset: nil,
            commandLine: nil,
            ollamaContextLength: OllamaSummaryProvider.normalizedContextLength(configuration.ollamaEffectiveContextLength),
            ollamaChunkThreshold: OllamaSummaryProvider.normalizedContextThreshold(configuration.ollamaEffectiveChunkThreshold),
            ollamaChunkSize: OllamaSummaryProvider.normalizedChunkSize(configuration.ollamaEffectiveChunkSize)
        )
    }
}
