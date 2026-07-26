import XCTest
@testable import AnyBrief

final class TranscriptionServiceTests: XCTestCase {
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
