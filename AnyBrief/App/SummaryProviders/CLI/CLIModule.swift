import Foundation
import SwiftUI

struct CLIModule: SummaryProviderModule {
    let id: SummaryProvider = .commandLine
    let title = "CLI"
    let systemImage = "terminal"
    let allowsMultipleConfigurations = true

    func defaultConfiguration() -> SummaryProviderConfiguration {
        .cli()
    }

    func normalize(_ configuration: SummaryProviderConfiguration) -> SummaryProviderConfiguration {
        var normalized = configuration
        var config = normalized.cliConfig
        if config.commandPreset.isEmpty {
            config.commandPreset = CLIDefaults.preset
        }
        if config.commandPreset != "custom" {
            config.commandLine = ""
        }
        normalized.cliConfig = config
        return normalized
    }

    func makeRunner(context: SummaryProviderRuntimeContext) -> any SummaryProviderRunner {
        CLISummaryProvider(
            session: context.session,
            fileManager: context.fileManager,
            logger: context.logger
        )
    }

    func makeDiagnostics(context: SummaryProviderDiagnosticsContext) -> any SummaryProviderDiagnostics {
        CLIDiagnostics(session: context.session, fileManager: context.fileManager)
    }

    @MainActor
    func makeSettingsView(context: SummaryProviderSettingsViewContext) -> AnyView {
        AnyView(CLISettingsView(configuration: context.configuration))
    }

    func metadata(from configuration: SummaryProviderConfiguration, settings: AppSettings) -> SummaryProviderMetadata {
        SummaryProviderMetadata(
            type: configuration.provider,
            title: title,
            model: configuration.cliEffectiveModel,
            apiURL: nil,
            timeoutSec: configuration.effectiveTimeoutSec,
            retryCount: nil,
            commandPreset: configuration.cliCommandPreset,
            commandLine: configuration.cliCommandPreset == "custom"
                ? CLISummaryProvider.resolvedCommand(configuration)
                : nil,
            ollamaContextLength: nil,
            ollamaChunkThreshold: nil,
            ollamaChunkSize: nil
        )
    }

    func runtimeLogMessage(
        configuration: SummaryProviderConfiguration,
        workingDirectory: URL?,
        transcriptURL: URL?
    ) -> String? {
        guard let workingDirectory, let transcriptURL else {
            return nil
        }
        return "Summary CLI launch: command=\(CLISummaryProvider.resolvedCommand(configuration)), cwd=\(workingDirectory.path), transcript=\(transcriptURL.path)"
    }
}
