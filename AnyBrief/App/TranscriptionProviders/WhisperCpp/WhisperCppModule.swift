import Foundation

struct WhisperCppModule: TranscriptionProviderModule {
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

    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider {
        WhisperCppProvider(fileManager: context.fileManager)
    }

    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics {
        WhisperCppDiagnostics(fileManager: context.fileManager)
    }
}
