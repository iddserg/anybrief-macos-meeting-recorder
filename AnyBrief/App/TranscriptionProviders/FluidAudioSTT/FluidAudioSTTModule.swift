import Foundation

struct FluidAudioSTTModule: TranscriptionProviderModule {
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

    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider {
        FluidAudioSTTProvider(fileManager: context.fileManager)
    }

    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics {
        FluidAudioSTTDiagnostics(
            modelService: FluidAudioSTTModelService(fileManager: context.fileManager)
        )
    }
}
