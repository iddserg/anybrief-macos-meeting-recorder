import Foundation

public final class WhisperSTTRunner: @unchecked Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func run(options: WhisperSTTOptions, ownExecutableURL: URL) throws {
        let inputURL = URL(fileURLWithPath: options.inputFile).standardizedFileURL
        let modelURL = URL(fileURLWithPath: options.model).standardizedFileURL
        guard fileManager.fileExists(atPath: inputURL.path) else {
            throw WhisperSTTError.fileNotFound(inputURL.path)
        }
        guard fileManager.fileExists(atPath: modelURL.path) else {
            throw WhisperSTTError.fileNotFound(modelURL.path)
        }
        let vadModelURL = options.vadModelPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        }
        if let vadModelURL,
           !fileManager.fileExists(atPath: vadModelURL.path) {
            throw WhisperSTTError.fileNotFound(vadModelURL.path)
        }
        let vocabulary: RecognitionVocabulary?
        if let vocabularyPath = options.vocabularyFile {
            let vocabularyURL = URL(fileURLWithPath: vocabularyPath).standardizedFileURL
            guard fileManager.fileExists(atPath: vocabularyURL.path) else {
                throw WhisperSTTError.fileNotFound(vocabularyURL.path)
            }
            let loaded = try RecognitionVocabulary(contentsOf: vocabularyURL)
            vocabulary = loaded.entries.isEmpty ? nil : loaded
        } else {
            vocabulary = nil
        }

        let outputDirectory = options.outputDirectory.map {
            URL(fileURLWithPath: $0, isDirectory: true)
        } ?? inputURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let baseName = inputURL.deletingPathExtension().lastPathComponent
        let whisperPrefix = outputDirectory.appendingPathComponent("\(baseName)_whisper")
        let whisperJSONURL = options.whisperJSONPath.map {
            URL(fileURLWithPath: $0).standardizedFileURL
        } ?? whisperPrefix.appendingPathExtension("json")
        let logURL = outputDirectory.appendingPathComponent("\(baseName)_whisper-stt.log")

        if !options.transcribeOnly, options.diarizationJSONPath == nil {
            let sttURL = try resolveExecutable(
                explicitPath: options.sttPath,
                siblingName: "stt",
                ownExecutableURL: ownExecutableURL
            )
            var arguments = [
                inputURL.path,
                "--output=\(outputDirectory.path)",
                "--diarize-only",
                "--threshold=\(String(format: "%.2f", options.threshold))",
            ]
            if let speakerMax = options.speakerMax {
                arguments.append("--speaker-max=\(speakerMax)")
            } else {
                arguments.append("--speakers=\(options.speakers)")
            }
            if options.verbose {
                arguments.append("--verbose")
            }
            try execute(sttURL, arguments: arguments, logURL: logURL, verbose: options.verbose)
        }

        if options.whisperJSONPath == nil {
            let whisperCoreURL = try resolveExecutable(
                explicitPath: options.whisperCorePath,
                siblingName: "whisper-cli-core",
                ownExecutableURL: ownExecutableURL
            )
            let arguments = Self.makeWhisperCoreArguments(
                inputURL: inputURL,
                modelURL: modelURL,
                outputPrefix: whisperPrefix,
                options: options,
                vadModelURL: vadModelURL,
                prompt: vocabulary?.prompt
            )
            try execute(
                whisperCoreURL,
                arguments: arguments,
                logURL: logURL,
                verbose: options.verbose
            )
        }

        guard fileManager.fileExists(atPath: whisperJSONURL.path) else {
            throw WhisperSTTError.invalidOutput("Missing whisper.cpp JSON at \(whisperJSONURL.path)")
        }
        let decoder = JSONDecoder()
        let whisper = try decoder.decode(WhisperDocument.self, from: Data(contentsOf: whisperJSONURL))
        let merger = TemporalMerger()
        let transcriptURL = outputDirectory.appendingPathComponent("\(baseName)_transcript.txt")
        let plainTranscript = vocabulary?.applyingAliases(
            to: merger.transcript(from: whisper)
        ) ?? merger.transcript(from: whisper)
        try plainTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)

        if !options.transcribeOnly {
            let diarizationURL = options.diarizationJSONPath.map {
                URL(fileURLWithPath: $0).standardizedFileURL
            } ?? outputDirectory.appendingPathComponent("\(baseName)_diarization.json")
            guard fileManager.fileExists(atPath: diarizationURL.path) else {
                throw WhisperSTTError.invalidOutput(
                    "Missing FluidAudio diarization JSON at \(diarizationURL.path)"
                )
            }
            let diarization = try decoder.decode(
                DiarizationDocument.self,
                from: Data(contentsOf: diarizationURL)
            )
            let turns = merger.merge(whisper: whisper, diarization: diarization).map { turn in
                SpeakerTurn(
                    start: turn.start,
                    end: turn.end,
                    speaker: turn.speaker,
                    text: vocabulary?.applyingAliases(to: turn.text) ?? turn.text
                )
            }
            let combinedURL = outputDirectory.appendingPathComponent("\(baseName)_combined.txt")
            try merger.combinedText(from: turns).write(
                to: combinedURL,
                atomically: true,
                encoding: .utf8
            )
        } else {
            let combinedURL = outputDirectory.appendingPathComponent("\(baseName)_combined.txt")
            let timedTranscript = merger.combinedText(
                from: merger.turnsWithoutDiarization(from: whisper).map { turn in
                    SpeakerTurn(
                        start: turn.start,
                        end: turn.end,
                        speaker: turn.speaker,
                        text: vocabulary?.applyingAliases(to: turn.text) ?? turn.text
                    )
                }
            )
            try (timedTranscript.isEmpty ? plainTranscript : timedTranscript).write(
                to: combinedURL,
                atomically: true,
                encoding: .utf8
            )
        }
    }

    static func makeWhisperCoreArguments(
        inputURL: URL,
        modelURL: URL,
        outputPrefix: URL,
        options: WhisperSTTOptions,
        vadModelURL: URL?,
        prompt: String?
    ) -> [String] {
        var arguments = [
            "--model", modelURL.path,
            "--file", inputURL.path,
            "--language", options.language,
            "--output-json-full",
            "--output-file", outputPrefix.path,
            "--no-prints",
            "--split-on-word",
        ]
        if let threads = options.threads {
            arguments += ["--threads", String(threads)]
        }
        if options.noGPU {
            arguments.append("--no-gpu")
        }
        if let vadModelURL {
            arguments += ["--vad", "--vad-model", vadModelURL.path]
        }
        if let prompt, !prompt.isEmpty {
            arguments += ["--prompt", prompt, "--carry-initial-prompt"]
        }
        return arguments
    }

    private func resolveExecutable(
        explicitPath: String?,
        siblingName: String,
        ownExecutableURL: URL
    ) throws -> URL {
        if let explicitPath, !explicitPath.isEmpty {
            let url = URL(fileURLWithPath: explicitPath).standardizedFileURL
            guard fileManager.isExecutableFile(atPath: url.path) else {
                throw WhisperSTTError.fileNotFound(url.path)
            }
            return url
        }

        let sibling = ownExecutableURL.deletingLastPathComponent().appendingPathComponent(siblingName)
        if fileManager.isExecutableFile(atPath: sibling.path) {
            return sibling
        }
        if let path = findOnPATH(siblingName) {
            return URL(fileURLWithPath: path)
        }
        throw WhisperSTTError.fileNotFound(sibling.path)
    }

    private func findOnPATH(_ name: String) -> String? {
        let paths = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        return paths
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name).path }
            .first(where: fileManager.isExecutableFile)
    }

    private func execute(
        _ executableURL: URL,
        arguments: [String],
        logURL: URL,
        verbose: Bool
    ) throws {
        if !fileManager.fileExists(atPath: logURL.path) {
            fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        defer { try? logHandle.close() }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = verbose ? FileHandle.standardOutput : logHandle
        process.standardError = verbose ? FileHandle.standardError : logHandle
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WhisperSTTError.processFailed(
                name: executableURL.lastPathComponent,
                status: process.terminationStatus
            )
        }
    }
}
