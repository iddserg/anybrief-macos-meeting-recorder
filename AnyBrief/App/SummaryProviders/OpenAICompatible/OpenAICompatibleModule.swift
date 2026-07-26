import Foundation
import SwiftUI

struct OpenAICompatibleModule: SummaryProviderModule {
    let id: SummaryProvider = .openAICompatible
    let title = "OpenAI-compatible"
    let systemImage = "network"
    let allowsMultipleConfigurations = true

    func defaultConfiguration() -> SummaryProviderConfiguration {
        .openAI()
    }

    func makeRunner(context: SummaryProviderRuntimeContext) -> any SummaryProviderRunner {
        OpenAICompatibleRunner(
            keychainStore: context.keychainStore,
            httpClient: context.httpClient
        )
    }

    func makeDiagnostics(context: SummaryProviderDiagnosticsContext) -> any SummaryProviderDiagnostics {
        OpenAICompatibleDiagnostics(session: context.session)
    }

    @MainActor
    func makeSettingsView(context: SummaryProviderSettingsViewContext) -> AnyView {
        AnyView(OpenAICompatibleSettingsView(
            configuration: context.configuration,
            apiKey: context.apiKey
        ))
    }

    func metadata(from configuration: SummaryProviderConfiguration, settings: AppSettings) -> SummaryProviderMetadata {
        SummaryProviderMetadata(
            type: configuration.provider,
            title: title,
            model: configuration.openAIEffectiveModel,
            apiURL: configuration.openAIEffectiveAPIURLString,
            timeoutSec: configuration.effectiveTimeoutSec,
            retryCount: configuration.effectiveRetryCount,
            commandPreset: nil,
            commandLine: nil,
            ollamaContextLength: nil,
            ollamaChunkThreshold: nil,
            ollamaChunkSize: nil
        )
    }
}
