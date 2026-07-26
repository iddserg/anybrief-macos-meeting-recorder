import XCTest
@testable import AnyBrief

final class TranscriptionProviderRegistryTests: XCTestCase {
    func testLegacySharedVocabularyMigratesIntoProviderPayloads() throws {
        let data = Data(
            """
            {
              "transcription": {
                "customVocabulary": "Admon\\nАРИР",
                "providers": [
                  {
                    "id": "fluid",
                    "provider": "fluid_audio_stt",
                    "enabled": true,
                    "payload": {
                      "threshold": 0.65
                    }
                  }
                ]
              }
            }
            """.utf8
        )

        let settings = try JSONDecoder().decode(AppSettings.self, from: data)

        XCTAssertEqual(settings.transcription.customVocabulary, "")
        XCTAssertEqual(settings.transcription.fluidAudioSTTConfig.customVocabulary, "Admon\nАРИР")
        XCTAssertEqual(settings.transcription.whisperCppConfig.customVocabulary, "Admon\nАРИР")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings))
        let transcription = try XCTUnwrap(
            (encoded as? [String: Any])?["transcription"] as? [String: Any]
        )
        XCTAssertNil(transcription["customVocabulary"])
    }

    func testDefaultRegistryContainsCurrentTranscriptionProviders() throws {
        let registry = TranscriptionProviderRegistry.default

        XCTAssertEqual(registry.modules.map(\.id), [.fluidAudioSTT, .whisperCpp])
        XCTAssertEqual(try registry.module(for: .fluidAudioSTT).title, "FluidAudio STT")
        XCTAssertTrue(try registry.module(for: .whisperCpp).title.contains("whisper.cpp"))
    }

    func testRegistryBuildsProviderDefaultsWithoutChangingSettingsShape() throws {
        let configuration = try TranscriptionProviderRegistry.default.defaultConfiguration(for: .fluidAudioSTT)

        XCTAssertEqual(configuration.provider, .fluidAudioSTT)
        XCTAssertTrue(configuration.enabled)
        XCTAssertEqual(configuration.fluidAudioSTTConfig.threshold, 0.65)
        XCTAssertEqual(WhisperCppConfig().threshold, 0.65)
    }

    func testWhisperConfigurationNormalizesAndCanBeSelected() {
        var settings = TranscriptionSettings()
        settings.whisperCppConfig = WhisperCppConfig(
            model: "not-a-model",
            language: "not-a-language",
            useGPU: false,
            speakersMode: "fixed",
            speakersCount: 20,
            threshold: 2
        )
        settings.selectProvider(.whisperCpp)

        XCTAssertEqual(settings.activeProviderConfiguration.provider, .whisperCpp)
        XCTAssertEqual(settings.whisperCppConfig.model, "small")
        XCTAssertEqual(settings.whisperCppConfig.language, "auto")
        XCTAssertFalse(settings.whisperCppConfig.useGPU)
        XCTAssertEqual(settings.whisperCppConfig.speakersCount, 10)
        XCTAssertEqual(settings.whisperCppConfig.threshold, 1)
    }

    func testWhisperProviderBuildsOnePassArguments() throws {
        var settings = AppSettings.default
        settings.transcription.whisperCppConfig = WhisperCppConfig(
            model: "small",
            language: "ru",
            useGPU: false,
            speakersMode: "fixed",
            speakersCount: 3,
            threshold: 0.35
        )
        let modelRoot = URL(fileURLWithPath: "/tmp/whisper-models", isDirectory: true)
        let modelService = WhisperCppModelService(
            modelsDirectoryURL: modelRoot,
            download: { _ in modelRoot.appendingPathComponent("download.bin") }
        )
        let arguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
                sourceTrack: .system,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: modelService
        )

        XCTAssertTrue(arguments.contains("--model=/tmp/whisper-models/ggml-small.bin"))
        XCTAssertTrue(arguments.contains("--vad-model=/tmp/whisper-models/ggml-silero-v6.2.0.bin"))
        XCTAssertTrue(arguments.contains("--language=ru"))
        XCTAssertTrue(arguments.contains("--speakers=3"))
        XCTAssertTrue(arguments.contains("--threshold=0.35"))
        XCTAssertTrue(arguments.contains("--no-gpu"))
    }

    func testWhisperProviderBuildsMaximumSpeakerArgument() throws {
        var settings = AppSettings.default
        settings.transcription.whisperCppConfig = WhisperCppConfig(
            model: "small",
            speakersMode: "max",
            speakersCount: 4
        )
        let modelRoot = URL(fileURLWithPath: "/tmp/whisper-models", isDirectory: true)
        let arguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
                sourceTrack: .system,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: WhisperCppModelService(
                modelsDirectoryURL: modelRoot,
                download: { _ in modelRoot.appendingPathComponent("download.bin") }
            )
        )

        XCTAssertTrue(arguments.contains("--speaker-max=4"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("--speakers=") })
    }

    func testWhisperModelStatusRequiresRecognitionAndVADModels() throws {
        let fileManager = FileManager.default
        let modelRoot = fileManager.temporaryDirectory.appendingPathComponent(
            "whisper-model-status-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: modelRoot) }
        try fileManager.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let service = WhisperCppModelService(
            fileManager: fileManager,
            modelsDirectoryURL: modelRoot,
            download: { _ in modelRoot.appendingPathComponent("unused.bin") }
        )
        try Data(repeating: 0, count: 1_000_001).write(
            to: try service.modelURL(named: "small")
        )

        XCTAssertFalse(service.status(model: "small").isInstalled)
        XCTAssertEqual(
            service.status(model: "small").missingRelativePaths,
            [WhisperCppModelService.vadModelFilename]
        )

        try Data(repeating: 0, count: 100_001).write(to: service.vadModelURL())

        XCTAssertTrue(service.status(model: "small").isInstalled)
        XCTAssertTrue(service.status(model: "small").missingRelativePaths.isEmpty)
    }

    func testWhisperModelDownloadIncludesSileroVAD() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent(
            "whisper-model-download-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: root) }
        let modelRoot = root.appendingPathComponent("models", isDirectory: true)
        let downloader = WhisperModelDownloadStub(
            directory: root.appendingPathComponent("downloads", isDirectory: true)
        )
        let service = WhisperCppModelService(
            fileManager: fileManager,
            modelsDirectoryURL: modelRoot,
            download: { url in
                try await downloader.download(url)
            }
        )

        try await service.downloadModel(named: "small")

        let requested = await downloader.requestedFilenames()
        XCTAssertEqual(requested, [
            "ggml-small.bin",
            WhisperCppModelService.vadModelFilename,
        ])
        XCTAssertTrue(service.status(model: "small").isInstalled)
    }

    func testWhisperProviderSkipsDiarizationWhenSpeakerSeparationIsDisabled() throws {
        var settings = AppSettings.default
        settings.transcription.diarizationEnabled = false
        settings.transcription.whisperCppConfig = WhisperCppConfig(model: "small")
        let modelRoot = URL(fileURLWithPath: "/tmp/whisper-models", isDirectory: true)
        let arguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
                sourceTrack: .system,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: WhisperCppModelService(
                modelsDirectoryURL: modelRoot,
                download: { _ in modelRoot.appendingPathComponent("download.bin") }
            )
        )

        XCTAssertTrue(arguments.contains("--transcribe-only"))
    }

    func testWhisperProviderSkipsMicrophoneDiarizationByDefault() throws {
        var settings = AppSettings.default
        settings.transcription.whisperCppConfig = WhisperCppConfig(model: "small")
        let modelRoot = URL(fileURLWithPath: "/tmp/whisper-models", isDirectory: true)
        let arguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/microphone.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
                sourceTrack: .mic,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: WhisperCppModelService(
                modelsDirectoryURL: modelRoot,
                download: { _ in modelRoot.appendingPathComponent("download.bin") }
            )
        )

        XCTAssertTrue(arguments.contains("--transcribe-only"))
        XCTAssertTrue(arguments.contains("--speakers=1"))
    }

    func testWhisperProviderCanEnableMicrophoneDiarization() throws {
        var settings = AppSettings.default
        settings.transcription.skipMicrophoneDiarization = false
        settings.transcription.whisperCppConfig = WhisperCppConfig(model: "small")
        let modelRoot = URL(fileURLWithPath: "/tmp/whisper-models", isDirectory: true)
        let arguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/microphone.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
                sourceTrack: .mic,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: WhisperCppModelService(
                modelsDirectoryURL: modelRoot,
                download: { _ in modelRoot.appendingPathComponent("download.bin") }
            )
        )

        XCTAssertFalse(arguments.contains("--transcribe-only"))
        XCTAssertTrue(arguments.contains("--speakers=1"))
    }

    func testWhisperProviderBuildsVocabularyArguments() throws {
        var settings = AppSettings.default
        settings.transcription.whisperCppConfig = WhisperCppConfig(
            model: "small",
            customVocabulary: "Admon"
        )
        let modelRoot = URL(fileURLWithPath: "/tmp/whisper-models", isDirectory: true)
        let arguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/output", isDirectory: true),
                sourceTrack: .system,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: WhisperCppModelService(
                modelsDirectoryURL: modelRoot,
                download: { _ in modelRoot.appendingPathComponent("download.bin") }
            )
        )

        XCTAssertTrue(
            arguments.contains("--vocabulary-file=/tmp/output/custom_vocabulary.txt")
        )
    }

    func testProviderDictionariesAreIndependent() throws {
        var settings = AppSettings.default
        settings.transcription.fluidAudioSTTConfig.customVocabulary = ""
        settings.transcription.whisperCppConfig = WhisperCppConfig(
            model: "small",
            customVocabulary: "Admon"
        )

        let fluidArguments = FluidAudioSTTProvider.makeArguments(
            wavURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
            outputDir: URL(fileURLWithPath: "/tmp/fluid", isDirectory: true),
            settings: settings,
            sourceTrack: .system
        )
        let whisperArguments = try WhisperCppProvider.makeArguments(
            input: TranscriptionInput(
                wavURL: URL(fileURLWithPath: "/tmp/meeting.wav"),
                outputDir: URL(fileURLWithPath: "/tmp/whisper", isDirectory: true),
                sourceTrack: .system,
                settings: settings,
                logURL: URL(fileURLWithPath: "/tmp/job.log")
            ),
            modelService: WhisperCppModelService(
                modelsDirectoryURL: URL(fileURLWithPath: "/tmp/models", isDirectory: true),
                download: { _ in URL(fileURLWithPath: "/tmp/download.bin") }
            )
        )

        XCTAssertFalse(fluidArguments.contains { $0.hasPrefix("--vocabulary-file=") })
        XCTAssertTrue(whisperArguments.contains("--vocabulary-file=/tmp/whisper/custom_vocabulary.txt"))
    }
}

private actor WhisperModelDownloadStub {
    private let directory: URL
    private var filenames: [String] = []

    init(directory: URL) {
        self.directory = directory
    }

    func download(_ sourceURL: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        filenames.append(sourceURL.lastPathComponent)
        let destination = directory.appendingPathComponent(
            "\(filenames.count)-\(sourceURL.lastPathComponent)",
            isDirectory: false
        )
        let size = sourceURL.lastPathComponent == WhisperCppModelService.vadModelFilename
            ? 100_001
            : 1_000_001
        try Data(repeating: 0, count: size).write(to: destination)
        return destination
    }

    func requestedFilenames() -> [String] {
        filenames
    }
}
