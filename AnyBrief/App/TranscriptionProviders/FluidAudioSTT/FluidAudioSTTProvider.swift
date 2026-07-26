import AVFoundation
import Foundation

/// Runs the `stt` CLI and parses its `<name>_combined.txt` output.
final class FluidAudioSTTProvider: TranscriptionProvider {
    let id: TranscriptionProviderID = .fluidAudioSTT

    private let fileManager: FileManager
    private let parser: CombinedTxtParser
    private let sttURLResolver: () throws -> URL
    private let timeoutResolver: (URL) async throws -> TimeInterval
    private let statusPollIntervalNanoseconds: UInt64
    private let terminationGracePeriodNanoseconds: UInt64

    init(
        fileManager: FileManager = .default,
        parser: CombinedTxtParser = CombinedTxtParser(),
        sttURLResolver: @escaping () throws -> URL = CLIPathResolver.resolveStt,
        timeoutResolver: @escaping (URL) async throws -> TimeInterval = { try await FluidAudioSTTProvider.transcriptionTimeoutSeconds(for: $0) },
        statusPollIntervalNanoseconds: UInt64 = 100_000_000,
        terminationGracePeriodNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.fileManager = fileManager
        self.parser = parser
        self.sttURLResolver = sttURLResolver
        self.timeoutResolver = timeoutResolver
        self.statusPollIntervalNanoseconds = statusPollIntervalNanoseconds
        self.terminationGracePeriodNanoseconds = terminationGracePeriodNanoseconds
    }

    func transcribe(input: TranscriptionInput) async throws -> TranscriptionResult {
        let segments = try await transcribe(
            wavURL: input.wavURL,
            outputDir: input.outputDir,
            sourceTrack: input.sourceTrack,
            settings: input.settings,
            logURL: input.logURL
        )
        return TranscriptionResult(
            segments: segments,
            outputDir: input.outputDir,
            combinedTxtURL: Self.combinedTxtURL(for: input.wavURL, outputDir: input.outputDir)
        )
    }

    func transcribe(
        wavURL: URL,
        outputDir: URL,
        sourceTrack: SourceTrack,
        settings: AppSettings,
        logURL: URL
    ) async throws -> [TranscriptSegment] {
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let sttURL = try sttURLResolver()
        try Self.writeVocabularyFileIfNeeded(
            settings.transcription.fluidAudioSTTConfig.customVocabulary.normalizedRecognitionVocabulary,
            outputDir: outputDir
        )
        let logHandle = try Self.openLogHandle(at: logURL)
        defer {
            try? logHandle.close()
        }

        let process = Process()
        process.executableURL = sttURL
        process.arguments = Self.makeArguments(
            wavURL: wavURL,
            outputDir: outputDir,
            settings: settings,
            sourceTrack: sourceTrack
        )
        process.standardOutput = logHandle
        process.standardError = logHandle

        let timeout = try await timeoutResolver(wavURL)
        let status = try await run(process, timeout: timeout, wavURL: wavURL)
        guard status == 0 else {
            throw TranscriptionError(message: "stt exited with status \(status) for \(wavURL.path).")
        }

        let combinedTxtURL = Self.combinedTxtURL(for: wavURL, outputDir: outputDir)
        guard fileManager.fileExists(atPath: combinedTxtURL.path) else {
            throw TranscriptionError(message: "stt output is missing at \(combinedTxtURL.path).")
        }
        // Empty combined.txt = stt found no speech — not an error, return zero segments
        let attrs = try? combinedTxtURL.resourceValues(forKeys: [.fileSizeKey])
        guard let size = attrs?.fileSize, size > 0 else {
            return []
        }
        return try parser.parse(fileURL: combinedTxtURL, sourceTrack: sourceTrack)
    }

    static func outputDir(for paths: MeetingPaths, track: TranscriptionTrack) -> URL {
        paths.tmpURL.appendingPathComponent(track.outputDirectoryName, isDirectory: true)
    }

    static func combinedTxtURL(for wavURL: URL, outputDir: URL) -> URL {
        outputDir.appendingPathComponent(
            "\(wavURL.deletingPathExtension().lastPathComponent)_combined.txt",
            isDirectory: false
        )
    }

    static func makeArguments(wavURL: URL, outputDir: URL, settings: AppSettings, sourceTrack: SourceTrack) -> [String] {
        // Use --key=value format to avoid ArgumentParser treating negative numbers (e.g. -1) as flags.
        // Mic track is always 1 speaker (local user); system track uses user settings.
        let config = settings.transcription.fluidAudioSTTConfig
        var arguments = [
            wavURL.path,
            "--output=\(outputDir.path)",
            speakerConstraintArgument(from: settings, sourceTrack: sourceTrack),
            "--threshold=\(String(format: "%.2f", config.threshold))",
        ]
        if !settings.transcription.diarizationEnabled
            || (sourceTrack == .mic && settings.transcription.skipMicrophoneDiarization) {
            arguments.append("--transcribe-only")
        }
        if !config.customVocabulary.normalizedRecognitionVocabulary.isEmpty {
            arguments.append(
                "--vocabulary-file=\(vocabularyFileURL(outputDir: outputDir).path)"
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

    static func transcriptionTimeoutSeconds(audioDuration: TimeInterval) -> TimeInterval {
        max(300, ceil(audioDuration / 60) * 120)
    }

    static func transcriptionTimeoutSeconds(for wavURL: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: wavURL)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw TranscriptionError(message: "Unable to determine audio duration for \(wavURL.path).")
        }

        return transcriptionTimeoutSeconds(audioDuration: seconds)
    }

    private static func speakerConstraintArgument(
        from settings: AppSettings,
        sourceTrack: SourceTrack
    ) -> String {
        if sourceTrack == .mic {
            return "--speakers=1"
        }
        let config = settings.transcription.fluidAudioSTTConfig
        switch config.speakersMode {
        case "fixed":
            return "--speakers=\(config.speakersCount)"
        case "max":
            return "--speaker-max=\(config.speakersCount)"
        default:
            return "--speakers=-1"
        }
    }

    private func run(_ process: Process, timeout: TimeInterval, wavURL: URL) async throws -> Int32 {
        do {
            try process.run()
        } catch {
            throw TranscriptionError(message: "stt did not start for \(wavURL.path).")
        }

        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeout * 1_000_000_000))
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                await terminateTimedOutProcess(process)
                throw TranscriptionTimeoutError(timeout: timeout, wavPath: wavURL.path)
            }

            await sleepIgnoringCancellation(nanoseconds: statusPollIntervalNanoseconds)
        }

        return process.terminationStatus
    }

    func runForTesting(_ process: Process, timeout: TimeInterval, wavURL: URL) async throws -> Int32 {
        try await run(process, timeout: timeout, wavURL: wavURL)
    }

    private func terminateTimedOutProcess(_ process: Process) async {
        guard process.isRunning else {
            return
        }

        kill(process.processIdentifier, SIGTERM)
        let graceDeadline = ContinuousClock.now + .nanoseconds(Int64(terminationGracePeriodNanoseconds))

        while process.isRunning, ContinuousClock.now < graceDeadline {
            await sleepIgnoringCancellation(nanoseconds: statusPollIntervalNanoseconds)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }

        while process.isRunning {
            await sleepIgnoringCancellation(nanoseconds: statusPollIntervalNanoseconds)
        }
    }

    private func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        try? await Task.sleep(nanoseconds: nanoseconds)
    }

    private static func openLogHandle(at url: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }
}
