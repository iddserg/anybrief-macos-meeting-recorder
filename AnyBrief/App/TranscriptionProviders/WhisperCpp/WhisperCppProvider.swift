import Foundation

final class WhisperCppProvider: TranscriptionProvider {
    let id: TranscriptionProviderID = .whisperCpp

    private let fileManager: FileManager
    private let parser: CombinedTxtParser
    private let executableResolver: () throws -> URL
    private let modelService: WhisperCppModelService

    init(
        fileManager: FileManager = .default,
        parser: CombinedTxtParser = CombinedTxtParser(),
        executableResolver: @escaping () throws -> URL = CLIPathResolver.resolveWhisperSTT,
        modelService: WhisperCppModelService = WhisperCppModelService()
    ) {
        self.fileManager = fileManager
        self.parser = parser
        self.executableResolver = executableResolver
        self.modelService = modelService
    }

    func transcribe(input: TranscriptionInput) async throws -> TranscriptionResult {
        try fileManager.createDirectory(at: input.outputDir, withIntermediateDirectories: true)
        try await modelService.ensureVADModel()
        try Self.writeVocabularyFileIfNeeded(
            input.settings.transcription.whisperCppConfig.customVocabulary.normalizedRecognitionVocabulary,
            outputDir: input.outputDir
        )
        let executableURL = try executableResolver()
        let process = Process()
        process.executableURL = executableURL
        process.arguments = try Self.makeArguments(
            input: input,
            modelService: modelService
        )
        let logHandle = try Self.openLogHandle(at: input.logURL)
        defer { try? logHandle.close() }
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            throw TranscriptionError(message: "whisper-stt did not start for \(input.wavURL.path).")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw TranscriptionError(
                message: "whisper-stt exited with status \(process.terminationStatus) for \(input.wavURL.path)."
            )
        }

        let combinedURL = input.outputDir.appendingPathComponent(
            "\(input.wavURL.deletingPathExtension().lastPathComponent)_combined.txt",
            isDirectory: false
        )
        guard fileManager.fileExists(atPath: combinedURL.path) else {
            throw TranscriptionError(message: "whisper-stt output is missing at \(combinedURL.path).")
        }
        let size = (try? combinedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let segments = size > 0
            ? try parser.parse(fileURL: combinedURL, sourceTrack: input.sourceTrack)
            : []
        return TranscriptionResult(
            segments: segments,
            outputDir: input.outputDir,
            combinedTxtURL: combinedURL
        )
    }

    static func makeArguments(
        input: TranscriptionInput,
        modelService: WhisperCppModelService
    ) throws -> [String] {
        let config = input.settings.transcription.whisperCppConfig
        let speakerConstraint: String
        if input.sourceTrack == .mic {
            speakerConstraint = "--speakers=1"
        } else if config.speakersMode == "fixed" {
            speakerConstraint = "--speakers=\(config.speakersCount)"
        } else if config.speakersMode == "max" {
            speakerConstraint = "--speaker-max=\(config.speakersCount)"
        } else {
            speakerConstraint = "--speakers=-1"
        }
        var arguments = [
            input.wavURL.path,
            "--output=\(input.outputDir.path)",
            "--model=\(try modelService.modelURL(named: config.model).path)",
            "--vad-model=\(modelService.vadModelURL().path)",
            "--language=\(config.language)",
            speakerConstraint,
            "--threshold=\(String(format: "%.2f", config.threshold))",
        ]
        if !config.useGPU {
            arguments.append("--no-gpu")
        }
        if !input.settings.transcription.diarizationEnabled
            || (input.sourceTrack == .mic
                && input.settings.transcription.skipMicrophoneDiarization) {
            arguments.append("--transcribe-only")
        }
        if !config.customVocabulary.normalizedRecognitionVocabulary.isEmpty {
            arguments.append(
                "--vocabulary-file=\(vocabularyFileURL(outputDir: input.outputDir).path)"
            )
        }
        return arguments
    }

    private static func vocabularyFileURL(outputDir: URL) -> URL {
        outputDir.appendingPathComponent("custom_vocabulary.txt", isDirectory: false)
    }

    private static func writeVocabularyFileIfNeeded(
        _ vocabulary: String,
        outputDir: URL
    ) throws {
        guard !vocabulary.isEmpty else { return }
        try vocabulary.write(
            to: vocabularyFileURL(outputDir: outputDir),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func openLogHandle(at url: URL) throws -> FileHandle {
        let directoryURL = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
