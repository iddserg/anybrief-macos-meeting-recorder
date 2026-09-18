import Foundation
import SwiftUI

struct FluidAudioSTTModule: TranscriptionProviderModule {
    var modelService = FluidAudioSTTModelService()
    let id: TranscriptionProviderID = .fluidAudioSTT
    let title = "FluidAudio STT"
    let systemImage = "waveform.and.person.filled"

    func defaultConfiguration() -> TranscriptionProviderConfiguration {
        .fluidAudioSTT()
    }

    func normalize(_ configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration {
        var configuration = configuration
        configuration.provider = .fluidAudioSTT
        configuration.fluidAudioSTTConfig = configuration.fluidAudioSTTConfig.normalized()
        return configuration
    }

    func metadata(configuration: TranscriptionProviderConfiguration, diarizationEnabled: Bool) -> TranscriptionMetadata {
        let config = configuration.fluidAudioSTTConfig
        let systemSpeakers: String
        switch config.speakersMode {
        case "fixed": systemSpeakers = String(config.speakersCount)
        case "max": systemSpeakers = "max:\(config.speakersCount)"
        default: systemSpeakers = "auto"
        }
        return TranscriptionMetadata(
            provider: id.rawValue, model: "nvidia-parakeet-tdt-0.6b-v3", language: nil,
            acceleration: "core_ml", diarizationEnabled: diarizationEnabled,
            speakersMode: config.speakersMode, speakersCount: config.speakersCount,
            systemSpeakers: diarizationEnabled ? systemSpeakers : "disabled",
            microphoneSpeakers: diarizationEnabled ? 1 : 0, threshold: config.threshold
        )
    }

    func applyingSpeakerLimit(_ count: Int, to configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration {
        var configuration = configuration
        var config = configuration.fluidAudioSTTConfig
        config.speakersMode = "max"
        config.speakersCount = max(1, min(10, count))
        configuration.fluidAudioSTTConfig = config
        return configuration
    }

    func modelStatus(configuration: TranscriptionProviderConfiguration, diarizationEnabled: Bool) -> TranscriptionModelStatus {
        modelService.status(diarizationEnabled: diarizationEnabled)
    }
    func downloadModels(configuration: TranscriptionProviderConfiguration, diarizationEnabled: Bool) async throws {
        try await modelService.downloadModels(diarizationEnabled: diarizationEnabled)
    }
    @MainActor func makeSettingsView(configuration: Binding<TranscriptionProviderConfiguration>, diarizationEnabled: Bool) -> AnyView {
        AnyView(FluidAudioSTTSettingsView(config: configuration.fluidAudioSTTConfig, diarizationEnabled: diarizationEnabled))
    }

    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider {
        FluidAudioSTTProvider(fileManager: context.fileManager)
    }

    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics {
        FluidAudioSTTDiagnostics(
            modelService: FluidAudioSTTModelService(fileManager: context.fileManager)
        )
    }
}
