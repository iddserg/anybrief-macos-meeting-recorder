import Darwin
import XCTest
@testable import AnyBrief

/// Tests `stt` invocation details for the FluidAudio STT provider.
final class FluidAudioSTTProviderTests: XCTestCase {
    func testModelStatusUsesFluidAudioSpeakerDiarizationCacheDirectory() throws {
        let fileManager = FileManager.default
        let modelsURL = fileManager.temporaryDirectory
            .appendingPathComponent("fluid-audio-model-layout-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelsURL) }

        let expectedDiarizationPaths = [
            "speaker-diarization/Segmentation.mlmodelc",
            "speaker-diarization/FBank.mlmodelc",
            "speaker-diarization/Embedding.mlmodelc",
            "speaker-diarization/PldaRho.mlmodelc",
            "speaker-diarization/plda-parameters.json",
        ]
        for relativePath in FluidAudioSTTModelService.asrRelativePaths + expectedDiarizationPaths {
            let url = modelsURL.appendingPathComponent(relativePath)
            if url.pathExtension == "mlmodelc" {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("{}".utf8).write(to: url)
            }
        }

        let service = FluidAudioSTTModelService(
            fileManager: fileManager,
            sttURLResolver: { URL(fileURLWithPath: "/bin/echo") },
            modelsDirectoryURL: modelsURL,
            coreMLModelLoader: { _ in }
        )

        XCTAssertEqual(FluidAudioSTTModelService.diarizationRelativePaths, expectedDiarizationPaths)
        XCTAssertTrue(service.status().isInstalled)
        XCTAssertTrue(service.status().missingRelativePaths.isEmpty)
    }

    func testTechnologyChecksReportReadyRequiredDependencies() async throws {
        let fileManager = FileManager.default
        let modelsURL = fileManager.temporaryDirectory
            .appendingPathComponent("fluid-audio-technology-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelsURL) }

        for relativePath in FluidAudioSTTModelService.asrRelativePaths
            + FluidAudioSTTModelService.diarizationRelativePaths {
            let url = modelsURL.appendingPathComponent(relativePath)
            if url.pathExtension == "mlmodelc" {
                try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data("{}".utf8).write(to: url)
            }
        }

        let service = FluidAudioSTTModelService(
            fileManager: fileManager,
            sttURLResolver: { URL(fileURLWithPath: "/bin/echo") },
            modelsDirectoryURL: modelsURL,
            coreMLModelLoader: { _ in }
        )

        let checks = await service.technologyChecks()

        XCTAssertEqual(
            Set(checks.map(\.id)),
            Set(["stt-cli", "model-storage", "asr-models", "diarization-models", "core-ml", "ane"])
        )
        XCTAssertFalse(checks.contains { $0.isRequired && $0.status == .unavailable })
        XCTAssertEqual(checks.first(where: { $0.id == "core-ml" })?.status, .ready)
    }

    func testTechnologyChecksExplainMissingModelsBeforeCoreMLProbe() async {
        let fileManager = FileManager.default
        let modelsURL = fileManager.temporaryDirectory
            .appendingPathComponent("missing-fluid-audio-models-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: modelsURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: modelsURL) }

        let service = FluidAudioSTTModelService(
            fileManager: fileManager,
            sttURLResolver: { URL(fileURLWithPath: "/bin/echo") },
            modelsDirectoryURL: modelsURL,
            coreMLModelLoader: { _ in
                XCTFail("Core ML loader must not run before the probe model is installed")
            }
        )

        let checks = await service.technologyChecks()

        XCTAssertEqual(checks.first(where: { $0.id == "asr-models" })?.status, .unavailable)
        XCTAssertEqual(checks.first(where: { $0.id == "diarization-models" })?.status, .unavailable)
        XCTAssertEqual(checks.first(where: { $0.id == "core-ml" })?.status, .warning)
    }

    func testBuildsSttArgumentsForAutoSpeakers() {
        let wavURL = URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav")
        let outputDir = URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true)

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: wavURL,
            outputDir: outputDir,
            settings: .default,
            sourceTrack: .system
        )

        XCTAssertEqual(arguments, [
            "/tmp/meeting/tmp/system.wav",
            "--output=/tmp/meeting/tmp/stt-system",
            "--speakers=-1",
            "--threshold=0.65",
        ])
    }

    func testBuildsSttArgumentsForFixedSpeakers() {
        var settings = AppSettings.default
        settings.transcription.fluidAudioSTTConfig = FluidAudioSTTConfig(
            speakersMode: "fixed",
            speakersCount: 3,
            threshold: 0.7
        )

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true),
            settings: settings,
            sourceTrack: .system
        )

        XCTAssertEqual(arguments, [
            "/tmp/meeting/tmp/system.wav",
            "--output=/tmp/meeting/tmp/stt-system",
            "--speakers=3",
            "--threshold=0.70",
        ])
    }

    func testBuildsSttArgumentsForMaximumSpeakers() {
        var settings = AppSettings.default
        settings.transcription.fluidAudioSTTConfig = FluidAudioSTTConfig(
            speakersMode: "max",
            speakersCount: 4,
            threshold: 0.65
        )

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true),
            settings: settings,
            sourceTrack: .system
        )

        XCTAssertTrue(arguments.contains("--speaker-max=4"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("--speakers=") })
    }

    func testBuildsSttArgumentsFormatsThresholdToTwoDecimals() {
        var settings = AppSettings.default
        settings.transcription.fluidAudioSTTConfig = FluidAudioSTTConfig(threshold: 0.35000000000000003)

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true),
            settings: settings,
            sourceTrack: .system
        )

        XCTAssertEqual(arguments, [
            "/tmp/meeting/tmp/system.wav",
            "--output=/tmp/meeting/tmp/stt-system",
            "--speakers=-1",
            "--threshold=0.35",
        ])
    }

    func testBuildsSttArgumentsMicSkipsDiarizationByDefault() {
        var settings = AppSettings.default
        settings.transcription.fluidAudioSTTConfig = FluidAudioSTTConfig(
            speakersMode: "fixed",
            speakersCount: 5
        )

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/mic.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-mic", isDirectory: true),
            settings: settings,
            sourceTrack: .mic
        )

        XCTAssertEqual(arguments, [
            "/tmp/meeting/tmp/mic.wav",
            "--output=/tmp/meeting/tmp/stt-mic",
            "--speakers=1",
            "--threshold=0.65",
            "--transcribe-only",
        ])
    }

    func testBuildsSttArgumentsMicCanEnableDiarization() {
        var settings = AppSettings.default
        settings.transcription.skipMicrophoneDiarization = false

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/mic.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-mic", isDirectory: true),
            settings: settings,
            sourceTrack: .mic
        )

        XCTAssertFalse(arguments.contains("--transcribe-only"))
        XCTAssertTrue(arguments.contains("--speakers=1"))
    }

    func testBuildsTranscribeOnlyArgumentsWhenSpeakerSeparationIsDisabled() {
        var settings = AppSettings.default
        settings.transcription.diarizationEnabled = false

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true),
            settings: settings,
            sourceTrack: .system
        )

        XCTAssertTrue(arguments.contains("--transcribe-only"))
    }

    func testBuildsVocabularyArguments() {
        var settings = AppSettings.default
        settings.transcription.fluidAudioSTTConfig.customVocabulary = "Admon\nMGCom: сам же ком"

        let arguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true),
            settings: settings,
            sourceTrack: .system
        )

        XCTAssertTrue(
            arguments.contains(
                "--vocabulary-file=/tmp/meeting/tmp/stt-system/custom_vocabulary.txt"
            )
        )
    }

    func testDiagnosticsDoNotRequireDiarizationModelsWhenSpeakerSeparationIsDisabled() async {
        let fileManager = FileManager.default
        let modelsURL = fileManager.temporaryDirectory
            .appendingPathComponent("fluid-audio-asr-only-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: modelsURL) }

        for relativePath in FluidAudioSTTModelService.asrRelativePaths {
            let url = modelsURL.appendingPathComponent(relativePath)
            if url.pathExtension == "mlmodelc" {
                try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try? fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? Data("{}".utf8).write(to: url)
            }
        }
        let modelService = FluidAudioSTTModelService(
            fileManager: fileManager,
            sttURLResolver: { URL(fileURLWithPath: "/bin/echo") },
            modelsDirectoryURL: modelsURL,
            coreMLModelLoader: { _ in }
        )
        var settings = AppSettings.default
        settings.transcription.diarizationEnabled = false

        let result = await FluidAudioSTTDiagnostics(modelService: modelService).diagnose(
            configuration: .fluidAudioSTT(),
            settings: settings
        )

        XCTAssertEqual(result.status, .success)
        XCTAssertFalse(result.technologyChecks.contains { $0.id == "diarization-models" })
    }

    func testCombinedTxtURLUsesInputStem() {
        let combinedURL = FluidAudioSTTProvider.combinedTxtURL(
            for: URL(fileURLWithPath: "/tmp/meeting/tmp/system.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/meeting/tmp/stt-system", isDirectory: true)
        )

        XCTAssertEqual(combinedURL.path, "/tmp/meeting/tmp/stt-system/system_combined.txt")
    }

    func testTranscriptionTimeoutUsesMinimumForShortAudio() {
        XCTAssertEqual(
            FluidAudioSTTProvider.transcriptionTimeoutSeconds(audioDuration: 60),
            300
        )
    }

    func testTranscriptionTimeoutRoundsUpByMinute() {
        XCTAssertEqual(
            FluidAudioSTTProvider.transcriptionTimeoutSeconds(audioDuration: 241),
            600
        )
    }

    func testTranscriptionTimeoutAllowsLongRecordingsToRunSlowerThanRealtime() {
        XCTAssertEqual(
            FluidAudioSTTProvider.transcriptionTimeoutSeconds(audioDuration: 36 * 60),
            72 * 60
        )
    }

    func testTimeoutKillsProcessThatIgnoresSIGTERM() async throws {
        let adapter = FluidAudioSTTProvider(
            statusPollIntervalNanoseconds: 10_000_000,
            terminationGracePeriodNanoseconds: 100_000_000
        )
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", "trap '' TERM; while true; do :; done"]
        let wavURL = URL(fileURLWithPath: "/tmp/system.wav")

        await XCTAssertThrowsErrorAsync(
            try await adapter.runForTesting(process, timeout: 0.2, wavURL: wavURL)
        ) { error in
            XCTAssertTrue(error is TranscriptionTimeoutError)
        }

        XCTAssertFalse(process.isRunning)
        XCTAssertEqual(kill(process.processIdentifier, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }
}

private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ errorHandler: (Error) -> Void = { _ in },
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error to be thrown", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
