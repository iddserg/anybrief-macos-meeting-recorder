import Foundation

/// Diagnostics for the bundled FluidAudio `stt` provider.
struct FluidAudioSTTDiagnostics: TranscriptionDiagnostics {
    let modelService: FluidAudioSTTModelService

    func diagnose(
        configuration: TranscriptionProviderConfiguration,
        settings: AppSettings
    ) async -> TranscriptionDiagnosticResult {
        let diarizationEnabled = settings.transcription.diarizationEnabled
        let technologyChecks = await modelService.technologyChecks(
            diarizationEnabled: diarizationEnabled
        )
        let status = modelService.status(diarizationEnabled: diarizationEnabled)
        let requiredTechnologyIsUnavailable = technologyChecks.contains {
            $0.isRequired && $0.status == .unavailable
        }
        if status.isInstalled, !requiredTechnologyIsUnavailable {
            return TranscriptionDiagnosticResult(
                status: .success,
                message: String(localized: "FluidAudio STT is ready."),
                technologyChecks: technologyChecks
            )
        }
        return TranscriptionDiagnosticResult(
            status: .failure,
            message: String(localized: "FluidAudio STT is not ready. Check the required technologies below."),
            technologyChecks: technologyChecks
        )
    }
}
