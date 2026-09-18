import XCTest
@testable import AnyBrief

final class TranscriptionServiceTests: XCTestCase {
    func testProviderModulesOwnMetadataAndCalendarSpeakerLimits() async throws {
        let service = TranscriptionService()
        for provider in TranscriptionProviderID.allCases {
            var settings = AppSettings.default
            let configuration = try TranscriptionProviderRegistry.default.defaultConfiguration(for: provider)
            settings.transcription.providers = [configuration]
            let overridden = await service.applyingSpeakerLimit(20, to: settings)
            let metadata = try await service.metadata(settings: overridden)
            XCTAssertEqual(metadata.provider, provider.rawValue)
            XCTAssertEqual(metadata.speakersMode, "max")
            XCTAssertEqual(metadata.speakersCount, 10)
            XCTAssertEqual(metadata.systemSpeakers, "max:10")
            XCTAssertFalse(metadata.model.isEmpty)
            XCTAssertEqual(overridden.transcription.providers[0].id, configuration.id)
            XCTAssertEqual(settings.transcription.providers[0], configuration)
            var noDiarization = overridden
            noDiarization.transcription.diarizationEnabled = false
            let disabled = try await service.metadata(settings: noDiarization)
            XCTAssertEqual(disabled.systemSpeakers, "disabled")
            XCTAssertEqual(disabled.microphoneSpeakers, 0)
        }
    }

    func testTranscribeDispatchesThroughConfiguredProvider() async throws {
        let service = TranscriptionService(providerRegistry: TranscriptionProviderRegistry(modules: [
            FakeTranscriptionModule(),
        ]))
        let wavURL = URL(fileURLWithPath: "/tmp/system.wav")
        let outputDir = URL(fileURLWithPath: "/tmp/stt-system", isDirectory: true)

        let result = try await service.transcribe(input: TranscriptionInput(
            wavURL: wavURL,
            outputDir: outputDir,
            sourceTrack: .system,
            settings: .default,
            logURL: URL(fileURLWithPath: "/tmp/job.log")
        ))

        XCTAssertEqual(result.outputDir, outputDir)
        XCTAssertEqual(result.combinedTxtURL.lastPathComponent, "system_combined.txt")
        XCTAssertEqual(result.segments, [
            TranscriptSegment(
                startTime: 1,
                endTime: 2,
                speaker: "Speaker A",
                text: "hello",
                sourceTrack: .system
            ),
        ])
    }
}

private struct FakeTranscriptionModule: TranscriptionProviderModule {
    let id: TranscriptionProviderID = .fluidAudioSTT
    let title = "Fake"
    let systemImage = "waveform"

    func defaultConfiguration() -> TranscriptionProviderConfiguration {
        .fluidAudioSTT()
    }

    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider {
        FakeTranscriptionProvider()
    }

    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics {
        FakeTranscriptionDiagnostics()
    }
}

private struct FakeTranscriptionProvider: TranscriptionProvider {
    let id: TranscriptionProviderID = .fluidAudioSTT

    func transcribe(input: TranscriptionInput) async throws -> TranscriptionResult {
        TranscriptionResult(
            segments: [
                TranscriptSegment(
                    startTime: 1,
                    endTime: 2,
                    speaker: "Speaker A",
                    text: "hello",
                    sourceTrack: input.sourceTrack
                ),
            ],
            outputDir: input.outputDir,
            combinedTxtURL: input.outputDir.appendingPathComponent("system_combined.txt", isDirectory: false)
        )
    }
}

private struct FakeTranscriptionDiagnostics: TranscriptionDiagnostics {
    func diagnose(
        configuration: TranscriptionProviderConfiguration,
        settings: AppSettings
    ) async -> TranscriptionDiagnosticResult {
        TranscriptionDiagnosticResult(status: .success, message: "ok")
    }
}
