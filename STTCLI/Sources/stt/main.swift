import AVFoundation
import ArgumentParser
import Darwin
import FluidAudio
import Foundation

@available(macOS 10.15, macCatalyst 13, iOS 13, tvOS 13, watchOS 6, *)
struct STTCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stt",
        abstract:
            "A macOS CLI utility for speech-to-text with speaker diarization using Parakeet v3",
        discussion:
            "Processes audio files (MP3, WAV, M4A, FLAC, etc.) and outputs diarized transcripts with speaker identification."
    )

    @Argument(help: "Input audio file path (not required with --prepare-diarization-models)")
    var inputFile: String?

    @Option(name: .shortAndLong, help: "Output directory for results (default: same as input file)")
    var output: String?

    @Flag(name: .shortAndLong, help: "Enable verbose output")
    var verbose: Bool = false

    @Flag(name: .long, help: "Skip diarization and only perform transcription")
    var transcribeOnly: Bool = false

    @Flag(name: .long, help: "Skip transcription and only write diarization text and JSON")
    var diarizeOnly: Bool = false

    @Flag(name: .long, help: "Download and compile offline diarization models, then exit")
    var prepareDiarizationModels: Bool = false

    @Flag(name: .long, help: "Use full-audio transcription before diarization (now the default)")
    var batchFirst: Bool = false

    @Flag(name: .long, help: "Use legacy per-speaker-turn transcription")
    var turnFirst: Bool = false

    @Option(help: "Diarization clustering threshold (0.0-1.0, default: 0.65)")
    var threshold: Double = 0.65

    @Option(help: "Exact number of speakers for diarization (-1 = auto-detect)")
    var speakers: Int = -1

    @Option(
        name: [.customLong("speaker-max"), .customLong("speakerMax")],
        help: "Maximum number of speakers for diarization (fewer speakers are allowed)"
    )
    var speakerMax: Int?

    @Option(help: "Custom vocabulary file (one preferred term per line; aliases follow a colon)")
    var vocabularyFile: String?

    func run() async throws {
        setbuf(stdout, nil)
        setbuf(stderr, nil)

        guard (0...1).contains(threshold) else {
            print("Error: threshold must be between 0.0 and 1.0")
            throw ExitCode.failure
        }

        guard speakers == -1 || speakers > 0 else {
            print("Error: speakers must be -1 (auto-detect) or a positive integer")
            throw ExitCode.failure
        }

        guard speakerMax == nil || speakerMax! > 0 else {
            print("Error: speaker-max must be a positive integer")
            throw ExitCode.failure
        }

        guard speakers == -1 || speakerMax == nil else {
            print("Error: --speakers and --speaker-max cannot be used together")
            throw ExitCode.failure
        }

        guard !(transcribeOnly && diarizeOnly) else {
            print("Error: --transcribe-only and --diarize-only cannot be used together")
            throw ExitCode.failure
        }

        guard !prepareDiarizationModels || (!transcribeOnly && !diarizeOnly) else {
            print("Error: --prepare-diarization-models cannot be combined with transcription or diarization modes")
            throw ExitCode.failure
        }

        guard !(batchFirst && turnFirst) else {
            print("Error: --batch-first and --turn-first cannot be used together")
            throw ExitCode.failure
        }

        let processor = AudioProcessor(verbose: verbose)

        if prepareDiarizationModels {
            do {
                try await processor.prepareOfflineDiarizationModels()
                print("✅ Offline diarization models are ready!")
                return
            } catch {
                print("❌ Error: \(error.localizedDescription)")
                throw ExitCode.failure
            }
        }

        guard let inputFile else {
            print("Error: input audio file path is required")
            throw ExitCode.failure
        }

        do {
            let result = try await processor.processAudioFile(
                inputPath: inputFile,
                outputDirectory: output,
                transcribeOnly: transcribeOnly,
                diarizeOnly: diarizeOnly,
                batchFirst: !turnFirst,
                threshold: threshold,
                numClusters: speakers,
                maxClusters: speakerMax ?? -1,
                vocabularyFile: vocabularyFile
            )

            print("✅ Processing complete!")
            if let transcriptFile = result.transcriptFile {
                print("📄 Transcript: \(transcriptFile)")
            }
            if let diarizationFile = result.diarizationFile {
                print("👥 Diarization: \(diarizationFile)")
            }
            if let diarizationJSONFile = result.diarizationJSONFile {
                print("🧩 Diarization JSON: \(diarizationJSONFile)")
            }
            if let combinedFile = result.combinedFile {
                print("🔗 Combined: \(combinedFile)")
            }
        } catch {
            print("❌ Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
    }
}

func runAsyncRootCommand<Command: AsyncParsableCommand>(_ command: Command.Type) async {
    await command.main(nil)
}

await runAsyncRootCommand(STTCommand.self)

struct ProcessingResult {
    let transcriptFile: String?
    let diarizationFile: String?
    let diarizationJSONFile: String?
    let combinedFile: String?
}

class AudioProcessor {
    private let verbose: Bool
    private var asrManager: AsrManager?
    var vocabularyReplacements: [(from: String, to: String)] = []

    init(verbose: Bool = false) {
        self.verbose = verbose
    }

    func processAudioFile(
        inputPath: String,
        outputDirectory: String?,
        transcribeOnly: Bool,
        diarizeOnly: Bool,
        batchFirst: Bool,
        threshold: Double,
        numClusters: Int = -1,
        maxClusters: Int = -1,
        vocabularyFile: String? = nil
    ) async throws -> ProcessingResult {

        let inputURL = URL(fileURLWithPath: inputPath)

        // Validate input file exists
        guard FileManager.default.fileExists(atPath: inputPath) else {
            throw ProcessingError.fileNotFound(inputPath)
        }

        // Convert audio to 16 kHz mono samples via FluidAudio's AudioConverter
        let samples = try loadAudioSamples(from: inputURL)
        let vocabulary: RecognitionVocabulary?
        if let vocabularyFile {
            let url = URL(fileURLWithPath: vocabularyFile)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw ProcessingError.fileNotFound(url.path)
            }
            let loaded = try RecognitionVocabulary(contentsOf: url)
            vocabulary = loaded.entries.isEmpty ? nil : loaded
        } else {
            vocabulary = nil
        }

        // Determine output directory
        let outputDir = outputDirectory ?? inputURL.deletingLastPathComponent().path
        let baseName = inputURL.deletingPathExtension().lastPathComponent

        // Ensure output directory exists
        try FileManager.default.createDirectory(
            atPath: outputDir, withIntermediateDirectories: true)

        let transcriptPath = "\(outputDir)/\(baseName)_transcript.txt"
        var diarizationPath: String? = nil
        var diarizationJSONPath: String? = nil
        var combinedPath: String? = nil

        if diarizeOnly {
            verboseLog("👥 Starting speaker diarization...")
            let diarizationResult = try await diarizeAudio(
                samples: samples,
                threshold: threshold,
                numClusters: numClusters,
                maxClusters: maxClusters
            )
            diarizationPath = "\(outputDir)/\(baseName)_diarization.txt"
            try formatDiarizationText(
                diarizationResult,
                audioDuration: Double(samples.count) / 16000.0
            ).write(
                to: URL(fileURLWithPath: diarizationPath!),
                atomically: true,
                encoding: .utf8
            )
            diarizationJSONPath = "\(outputDir)/\(baseName)_diarization.json"
            try writeDiarizationJSON(
                diarizationResult,
                audioDuration: Double(samples.count) / 16000.0,
                to: URL(fileURLWithPath: diarizationJSONPath!)
            )
        } else if transcribeOnly {
            verboseLog("🗣️ Starting transcription with Parakeet v3...")
            let transcription = try await transcribeAudioResult(
                samples: samples,
                vocabularyFile: vocabularyFile
            )

            try transcription.text.write(
                to: URL(fileURLWithPath: transcriptPath), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved transcript to: \(transcriptPath)")
            combinedPath = "\(outputDir)/\(baseName)_combined.txt"
            var wordTimings = buildWordTimings(from: transcription.tokenTimings ?? [])
            wordTimings = vocabulary?.applyingAliases(to: wordTimings) ?? wordTimings
            wordTimings = RecognitionVocabulary.applying(
                vocabularyReplacements,
                to: wordTimings
            )
            let timedTranscript = combineTranscriptionWithoutDiarization(wordTimings: wordTimings)
            try (timedTranscript.isEmpty ? transcription.text : timedTranscript).write(
                to: URL(fileURLWithPath: combinedPath!), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved non-diarized result to: \(combinedPath!)")
        } else if !batchFirst {
            verboseLog("👥 Starting speaker diarization before transcription...")
            let diarizationResult = try await diarizeAudio(
                samples: samples,
                threshold: threshold,
                numClusters: numClusters,
                maxClusters: maxClusters
            )

            let diarizationText = formatDiarizationText(
                diarizationResult,
                audioDuration: Double(samples.count) / 16000.0
            )
            diarizationPath = "\(outputDir)/\(baseName)_diarization.txt"
            try diarizationText.write(
                to: URL(fileURLWithPath: diarizationPath!), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved diarization to: \(diarizationPath!)")

            verboseLog("🗣️ Transcribing diarized speaker turns...")
            let turnResult = try await transcribeDiarizedTurns(
                samples: samples,
                diarizationResult: diarizationResult
            )
            let plainTranscript = vocabulary?.applyingAliases(
                to: turnResult.plainTranscript
            ) ?? turnResult.plainTranscript
            let combinedTranscript = vocabulary?.applyingAliases(
                to: turnResult.combinedTranscript
            ) ?? turnResult.combinedTranscript

            try plainTranscript.write(
                to: URL(fileURLWithPath: transcriptPath), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved transcript to: \(transcriptPath)")

            combinedPath = "\(outputDir)/\(baseName)_combined.txt"
            try combinedTranscript.write(
                to: URL(fileURLWithPath: combinedPath!), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved combined result to: \(combinedPath!)")
        } else {
            // Perform one full-audio transcription and preserve token timestamps.
            verboseLog("🗣️ Starting transcription with Parakeet v3...")
            let transcription = try await transcribeAudioResult(
                samples: samples,
                vocabularyFile: vocabularyFile
            )

            // Save transcript
            try transcription.text.write(
                to: URL(fileURLWithPath: transcriptPath), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved transcript to: \(transcriptPath)")

            // Perform speaker diarization
            verboseLog("👥 Starting speaker diarization...")
            let diarizationResult = try await diarizeAudio(
                samples: samples,
                threshold: threshold,
                numClusters: numClusters,
                maxClusters: maxClusters
            )

            // Write human-readable diarization log
            let diarizationText = formatDiarizationText(
                diarizationResult,
                audioDuration: Double(samples.count) / 16000.0
            )
            diarizationPath = "\(outputDir)/\(baseName)_diarization.txt"
            try diarizationText.write(
                to: URL(fileURLWithPath: diarizationPath!), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved diarization to: \(diarizationPath!)")

            var wordTimings = buildWordTimings(from: transcription.tokenTimings ?? [])
            wordTimings = vocabulary?.applyingAliases(to: wordTimings) ?? wordTimings
            wordTimings = RecognitionVocabulary.applying(
                vocabularyReplacements,
                to: wordTimings
            )
            let combined: String
            if wordTimings.isEmpty, !transcription.text.isEmpty {
                verboseLog("⚠️ Batch transcription returned no token timings; falling back to per-turn ASR")
                combined = try await transcribeDiarizedTurns(
                    samples: samples,
                    diarizationResult: diarizationResult
                ).combinedTranscript
            } else {
                verboseLog("🔗 Aligning \(wordTimings.count) timed words with speaker information...")
                combined = combineTranscriptionWithDiarization(
                    wordTimings: wordTimings,
                    diarizationResult: diarizationResult
                )
            }

            combinedPath = "\(outputDir)/\(baseName)_combined.txt"
            try combined.write(
                to: URL(fileURLWithPath: combinedPath!), atomically: true, encoding: .utf8)
            verboseLog("💾 Saved combined result to: \(combinedPath!)")
        }

        return ProcessingResult(
            transcriptFile: diarizeOnly ? nil : transcriptPath,
            diarizationFile: diarizationPath,
            diarizationJSONFile: diarizationJSONPath,
            combinedFile: combinedPath
        )
    }

    func verboseLog(_ message: String) {
        if verbose {
            print(message)
        }
    }

    func cachedAsrManager() async throws -> AsrManager {
        if let asrManager {
            return asrManager
        }

        verboseLog("🤖 Initializing Parakeet v3 ASR model...")
        let models = try await AsrModels.downloadAndLoad()
        verboseLog("✅ ASR models loaded successfully")

        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        verboseLog("✅ ASR manager initialized")

        self.asrManager = asrManager
        return asrManager
    }

}

enum ProcessingError: LocalizedError {
    case fileNotFound(String)
    case unsupportedFormat
    case transcriptionFailed(Error)
    case diarizationFailed

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .unsupportedFormat:
            return "Unsupported audio format"
        case .transcriptionFailed(let error):
            return "Transcription failed: \(error.localizedDescription)"
        case .diarizationFailed:
            return "Speaker diarization failed"
        }
    }
}
