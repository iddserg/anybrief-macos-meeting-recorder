import Foundation
import SwiftUI

struct WhisperCppModule: TranscriptionProviderModule {
    let modelService = WhisperCppModelService()
    let id: TranscriptionProviderID = .whisperCpp
    let title = "whisper.cpp"
    let systemImage = "waveform.badge.magnifyingglass"

    func defaultConfiguration() -> TranscriptionProviderConfiguration {
        .whisperCpp()
    }

    func normalize(_ configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration {
        var configuration = configuration
        configuration.provider = .whisperCpp
        configuration.whisperCppConfig = configuration.whisperCppConfig.normalized()
        return configuration
    }

    func metadata(configuration: TranscriptionProviderConfiguration, diarizationEnabled: Bool) -> TranscriptionMetadata {
        let config = configuration.whisperCppConfig
        let systemSpeakers: String
        switch config.speakersMode {
        case "fixed": systemSpeakers = String(config.speakersCount)
        case "max": systemSpeakers = "max:\(config.speakersCount)"
        default: systemSpeakers = "auto"
        }
        return TranscriptionMetadata(
            provider: id.rawValue, model: config.model, language: config.language,
            acceleration: config.useGPU ? "metal" : "cpu", diarizationEnabled: diarizationEnabled,
            speakersMode: config.speakersMode, speakersCount: config.speakersCount,
            systemSpeakers: diarizationEnabled ? systemSpeakers : "disabled",
            microphoneSpeakers: diarizationEnabled ? 1 : 0, threshold: config.threshold
        )
    }

    func applyingSpeakerLimit(_ count: Int, to configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration {
        var configuration = configuration
        var config = configuration.whisperCppConfig
        config.speakersMode = "max"
        config.speakersCount = max(1, min(10, count))
        configuration.whisperCppConfig = config
        return configuration
    }

    func modelStatus(configuration: TranscriptionProviderConfiguration, diarizationEnabled: Bool) -> TranscriptionModelStatus {
        let status = modelService.status(model: configuration.whisperCppConfig.model)
        let missing = status.missingRelativePaths + (diarizationEnabled ? DiarizationModelService().missingRelativePaths : [])
        return TranscriptionModelStatus(modelsDirectoryURL: status.modelsDirectoryURL, isInstalled: missing.isEmpty,
                                        installedSizeBytes: status.installedSizeBytes, missingRelativePaths: missing)
    }
    func downloadModels(configuration: TranscriptionProviderConfiguration, diarizationEnabled: Bool) async throws {
        try await modelService.downloadModel(named: configuration.whisperCppConfig.model)
        if diarizationEnabled { try await DiarizationModelService().downloadModels() }
    }
    @MainActor func makeSettingsView(configuration: Binding<TranscriptionProviderConfiguration>, diarizationEnabled: Bool) -> AnyView {
        AnyView(WhisperCppSettingsView(config: configuration.whisperCppConfig, diarizationEnabled: diarizationEnabled))
    }

    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider {
        WhisperCppProvider(fileManager: context.fileManager)
    }

    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics {
        WhisperCppDiagnostics(fileManager: context.fileManager)
    }
}
