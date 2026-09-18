
import Foundation

extension DashboardViewModel {
    func refreshTranscriptionModelStatus() {
        if let module = try? transcriptionProviderRegistry.module(for: selectedTranscriptionProvider) {
            transcriptionModelStatus = module.modelStatus(configuration: draftTranscriptionConfiguration(),
                                                         diarizationEnabled: transcriptionDiarizationEnabled)
        }
        checkTranscriptionTechnologies()
    }

    var selectedTranscriptionProvider: TranscriptionProviderID {
        TranscriptionProviderID(rawValue: transcriptionProviderSelection) ?? .fluidAudioSTT
    }

    func transcriptionProviderDidChange() {
        transcriptionModelMessage = nil
        transcriptionTechnologyChecks = []
        transcriptionTechnologyMessage = nil
        refreshTranscriptionModelStatus()
    }

    func checkTranscriptionTechnologies() {
        guard !isCheckingTranscriptionTechnologies else { return }
        isCheckingTranscriptionTechnologies = true

        Task {
            var settings = await appSettingsStore.load(using: loggingService)
            settings.transcription.diarizationEnabled = transcriptionDiarizationEnabled
            let configuration = draftTranscriptionConfiguration()
            do {
                let module = try transcriptionProviderRegistry.module(for: configuration.provider)
                transcriptionTechnologyProviderTitle = module.title
                let diagnostics = module.makeDiagnostics(
                    context: TranscriptionDiagnosticsContext(fileManager: fileManager)
                )
                let result = await diagnostics.diagnose(
                    configuration: configuration,
                    settings: settings
                )
                transcriptionTechnologyChecks = result.technologyChecks
                transcriptionTechnologyMessage = result.message
                transcriptionTechnologyMessageIsError = result.status == .failure
            } catch {
                transcriptionTechnologyChecks = []
                transcriptionTechnologyMessage = error.localizedDescription
                transcriptionTechnologyMessageIsError = true
            }
            isCheckingTranscriptionTechnologies = false
        }
    }

    func downloadTranscriptionModels() {
        guard !isDownloadingTranscriptionModels else { return }

        isDownloadingTranscriptionModels = true
        transcriptionModelMessage = String(localized: "Downloading and preparing transcription models. This can take several minutes.")
        transcriptionModelMessageIsError = false

        Task {
            do {
                await loggingService.log(
                    "Starting transcription model download/warm-up.",
                    level: .info,
                    component: "Transcription"
                )
                let module = try transcriptionProviderRegistry.module(for: selectedTranscriptionProvider)
                try await module.downloadModels(configuration: draftTranscriptionConfiguration(),
                                                diarizationEnabled: transcriptionDiarizationEnabled)
                await MainActor.run {
                    refreshTranscriptionModelStatus()
                    isDownloadingTranscriptionModels = false
                    if transcriptionModelStatus.isInstalled {
                        transcriptionModelMessage = String(localized: "Transcription models are ready.")
                        transcriptionModelMessageIsError = false
                    } else {
                        transcriptionModelMessage = String(
                            format: String(localized: "Missing files: %d"),
                            transcriptionModelStatus.missingRelativePaths.count
                        )
                        transcriptionModelMessageIsError = true
                    }
                }
                await loggingService.log(
                    "Transcription model download/warm-up completed.",
                    level: .info,
                    component: "Transcription"
                )
            } catch {
                await MainActor.run {
                    refreshTranscriptionModelStatus()
                    isDownloadingTranscriptionModels = false
                    transcriptionModelMessage = error.localizedDescription
                    transcriptionModelMessageIsError = true
                }
                await loggingService.log(
                    "Transcription model download/warm-up failed: \(error.localizedDescription)",
                    level: .error,
                    component: "Transcription"
                )
            }
        }
    }

    func draftTranscriptionConfiguration() -> TranscriptionProviderConfiguration {
        transcriptionProviderEntries.first { $0.provider == selectedTranscriptionProvider }
            ?? (try? transcriptionProviderRegistry.defaultConfiguration(for: selectedTranscriptionProvider))
            ?? TranscriptionProviderConfiguration(provider: selectedTranscriptionProvider)
    }

    func updateTranscriptionConfiguration(_ configuration: TranscriptionProviderConfiguration) {
        if let index = transcriptionProviderEntries.firstIndex(where: { $0.provider == configuration.provider }) {
            transcriptionProviderEntries[index] = configuration
        } else {
            transcriptionProviderEntries.append(configuration)
        }
        refreshTranscriptionModelStatus()
    }
}
