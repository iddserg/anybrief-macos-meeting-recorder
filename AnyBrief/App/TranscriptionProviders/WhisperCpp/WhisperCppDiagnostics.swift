import Foundation

struct WhisperCppDiagnostics: TranscriptionDiagnostics {
    let fileManager: FileManager

    func diagnose(
        configuration: TranscriptionProviderConfiguration,
        settings: AppSettings
    ) async -> TranscriptionDiagnosticResult {
        let config = configuration.whisperCppConfig
        let modelService = WhisperCppModelService(fileManager: fileManager)
        var checks = [
            executableCheck(
                id: "whisper-stt",
                title: String(localized: "whisper-stt command-line tool"),
                resolver: CLIPathResolver.resolveWhisperSTT
            ),
            executableCheck(
                id: "whisper-core",
                title: String(localized: "whisper.cpp runtime"),
                resolver: CLIPathResolver.resolveWhisperCore
            ),
        ]
        if settings.transcription.diarizationEnabled {
            checks += [
                executableCheck(
                id: "fluid-diarizer",
                title: String(localized: "FluidAudio diarization runtime"),
                resolver: CLIPathResolver.resolveStt
                ),
                diarizationModelsCheck(),
            ]
        }
        checks += [
            modelCheck(
                installed: modelService.isModelInstalled(named: config.model),
                model: config.model
            ),
            vadModelCheck(installed: modelService.isVADModelInstalled()),
            TranscriptionTechnologyCheck(
                id: "metal",
                title: String(localized: "Metal acceleration"),
                detail: config.useGPU
                    ? String(localized: "Enabled. whisper.cpp can use the Apple GPU.")
                    : String(localized: "Disabled in settings; whisper.cpp will use the CPU."),
                status: config.useGPU ? .ready : .warning,
                isRequired: false
            ),
        ]
        let unavailable = checks.contains { $0.isRequired && $0.status == .unavailable }
        return TranscriptionDiagnosticResult(
            status: unavailable ? .failure : .success,
            message: unavailable
                ? String(localized: "whisper.cpp is not ready. Check the required technologies below.")
                : String(localized: "whisper.cpp is ready."),
            technologyChecks: checks
        )
    }

    private func diarizationModelsCheck() -> TranscriptionTechnologyCheck {
        let missing = FluidAudioSTTModelService.diarizationRelativePaths.filter { relativePath in
            !fileManager.fileExists(
                atPath: FluidAudioSTTModelService.modelsDirectoryURL
                    .appendingPathComponent(relativePath)
                    .path
            )
        }
        return TranscriptionTechnologyCheck(
            id: "fluid-diarization-models",
            title: String(localized: "Speaker diarization models"),
            detail: missing.isEmpty
                ? String(localized: "Installed and ready.")
                : String(format: String(localized: "Missing files: %d"), missing.count),
            status: missing.isEmpty ? .ready : .unavailable,
            isRequired: true
        )
    }

    private func executableCheck(
        id: String,
        title: String,
        resolver: () throws -> URL
    ) -> TranscriptionTechnologyCheck {
        do {
            let url = try resolver()
            return TranscriptionTechnologyCheck(
                id: id,
                title: title,
                detail: url.path,
                status: fileManager.isExecutableFile(atPath: url.path) ? .ready : .unavailable,
                isRequired: true
            )
        } catch {
            return TranscriptionTechnologyCheck(
                id: id,
                title: title,
                detail: error.localizedDescription,
                status: .unavailable,
                isRequired: true
            )
        }
    }

    private func modelCheck(
        installed: Bool,
        model: String
    ) -> TranscriptionTechnologyCheck {
        TranscriptionTechnologyCheck(
            id: "whisper-model",
            title: String(localized: "Whisper recognition model"),
            detail: installed
                ? String(format: String(localized: "Model %@ is installed and ready."), model)
                : String(format: String(localized: "Model %@ has not been downloaded."), model),
            status: installed ? .ready : .unavailable,
            isRequired: true
        )
    }

    private func vadModelCheck(installed: Bool) -> TranscriptionTechnologyCheck {
        TranscriptionTechnologyCheck(
            id: "whisper-vad-model",
            title: String(localized: "Voice activity detection model"),
            detail: installed
                ? String(localized: "Silero VAD is installed and filters silence before Whisper recognition.")
                : String(localized: "Silero VAD has not been downloaded."),
            status: installed ? .ready : .unavailable,
            isRequired: true
        )
    }
}
