import AVFoundation
import CoreML
import Foundation

struct TranscriptionModelStatus: Equatable {
    let modelsDirectoryURL: URL
    let isInstalled: Bool
    let installedSizeBytes: Int64
    let missingRelativePaths: [String]

    var installedSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: installedSizeBytes, countStyle: .file)
    }
}

enum FluidAudioSTTModelServiceError: LocalizedError {
    case audioPreparationFailed
    case downloadFailed(detail: String)

    var errorDescription: String? {
        switch self {
        case .audioPreparationFailed:
            return String(localized: "Failed to prepare audio for model download.")
        case .downloadFailed(let detail):
            return String(format: String(localized: "Failed to download models: %@"), detail)
        }
    }
}

/// Checks and warms FluidAudio ASR/diarization model cache used by the bundled `stt` CLI.
final class FluidAudioSTTModelService {
    static let modelsDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)

    static let asrRelativePaths = [
        "parakeet-tdt-0.6b-v3/Preprocessor.mlmodelc",
        "parakeet-tdt-0.6b-v3/Encoder.mlmodelc",
        "parakeet-tdt-0.6b-v3/Decoder.mlmodelc",
        "parakeet-tdt-0.6b-v3/JointDecisionv3.mlmodelc",
        "parakeet-tdt-0.6b-v3/parakeet_vocab.json",
    ]

    static let diarizationRelativePaths = [
        "speaker-diarization/Segmentation.mlmodelc",
        "speaker-diarization/FBank.mlmodelc",
        "speaker-diarization/Embedding.mlmodelc",
        "speaker-diarization/PldaRho.mlmodelc",
        "speaker-diarization/plda-parameters.json",
    ]

    private let fileManager: FileManager
    private let sttURLResolver: () throws -> URL
    private let modelsDirectoryURL: URL
    private let coreMLModelLoader: (URL) async throws -> Void

    init(
        fileManager: FileManager = .default,
        sttURLResolver: @escaping () throws -> URL = CLIPathResolver.resolveStt,
        modelsDirectoryURL: URL = FluidAudioSTTModelService.modelsDirectoryURL,
        coreMLModelLoader: @escaping (URL) async throws -> Void = { url in
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            _ = try await MLModel.load(contentsOf: url, configuration: configuration)
        }
    ) {
        self.fileManager = fileManager
        self.sttURLResolver = sttURLResolver
        self.modelsDirectoryURL = modelsDirectoryURL
        self.coreMLModelLoader = coreMLModelLoader
    }

    func status(diarizationEnabled: Bool = true) -> TranscriptionModelStatus {
        let rootURL = modelsDirectoryURL
        let requiredPaths = Self.asrRelativePaths
            + (diarizationEnabled ? Self.diarizationRelativePaths : [])
        let missing = requiredPaths.filter { relativePath in
            !fileManager.fileExists(atPath: rootURL.appendingPathComponent(relativePath).path)
        }
        return TranscriptionModelStatus(
            modelsDirectoryURL: rootURL,
            isInstalled: missing.isEmpty,
            installedSizeBytes: directorySize(at: rootURL),
            missingRelativePaths: missing
        )
    }

    func technologyChecks(diarizationEnabled: Bool = true) async -> [TranscriptionTechnologyCheck] {
        let modelStatus = status(diarizationEnabled: diarizationEnabled)
        let missingASR = Self.asrRelativePaths.filter(modelStatus.missingRelativePaths.contains)
        let missingDiarization = Self.diarizationRelativePaths.filter(modelStatus.missingRelativePaths.contains)

        let cliCheck: TranscriptionTechnologyCheck
        do {
            let sttURL = try sttURLResolver()
            if fileManager.isExecutableFile(atPath: sttURL.path) {
                cliCheck = check(
                    id: "stt-cli",
                    title: String(localized: "STT command-line tool"),
                    detail: sttURL.path,
                    status: .ready
                )
            } else {
                cliCheck = check(
                    id: "stt-cli",
                    title: String(localized: "STT command-line tool"),
                    detail: String(localized: "The bundled stt file is not executable."),
                    status: .unavailable
                )
            }
        } catch {
            cliCheck = check(
                id: "stt-cli",
                title: String(localized: "STT command-line tool"),
                detail: error.localizedDescription,
                status: .unavailable
            )
        }

        let storageCheck = check(
            id: "model-storage",
            title: String(localized: "Model storage"),
            detail: writableDirectoryDescription(),
            status: isModelStorageWritable() ? .ready : .unavailable
        )

        let asrCheck = modelFilesCheck(
            id: "asr-models",
            title: String(localized: "Recognition models"),
            missingPaths: missingASR
        )
        let diarizationCheck = modelFilesCheck(
            id: "diarization-models",
            title: String(localized: "Speaker diarization models"),
            missingPaths: missingDiarization
        )
        let coreMLCheck = await coreMLCheck(missingASR: missingASR)

        #if arch(arm64)
        let aneCheck = check(
            id: "ane",
            title: String(localized: "Apple Neural Engine"),
            detail: String(localized: "Apple Silicon detected. Core ML can select ANE automatically."),
            status: .ready,
            isRequired: false
        )
        #else
        let aneCheck = check(
            id: "ane",
            title: String(localized: "Apple Neural Engine"),
            detail: String(localized: "Not available on this Mac. Recognition will use CPU or GPU."),
            status: .warning,
            isRequired: false
        )
        #endif

        var checks = [cliCheck, storageCheck, asrCheck]
        if diarizationEnabled {
            checks.append(diarizationCheck)
        }
        checks += [coreMLCheck, aneCheck]
        return checks
    }

    /// Warms ASR with a short silent WAV and prepares offline diarization
    /// through its dedicated CLI mode. FluidAudio reuses the local model cache.
    func downloadModels(diarizationEnabled: Bool = true) async throws {
        try await warmModels(mode: "--transcribe-only")
        if diarizationEnabled {
            try await prepareDiarizationModels()
        }
    }

    func downloadDiarizationModels() async throws {
        try await prepareDiarizationModels()
    }

    private func prepareDiarizationModels() async throws {
        let sttURL = try sttURLResolver()
        let process = Process()
        process.executableURL = sttURL
        process.arguments = ["--prepare-diarization-models"]
        try await run(process)
    }

    private func warmModels(mode: String) async throws {
        let sttURL = try sttURLResolver()
        let workDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("anybrief-transcription-models-\(UUID().uuidString.lowercased())", isDirectory: true)
        let inputURL = workDirectory.appendingPathComponent("warmup.wav", isDirectory: false)

        try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        try makeSilentWAV(at: inputURL)

        defer {
            try? fileManager.removeItem(at: workDirectory)
        }

        let process = Process()
        process.executableURL = sttURL
        process.arguments = [inputURL.path, "--output", workDirectory.path, mode]

        try await run(process)
    }

    private func run(_ process: Process) async throws {
        let minimumRuntime: TimeInterval = 0.25
        let startedAt = Date()

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { process in
                let runtime = Date().timeIntervalSince(startedAt)
                if process.terminationReason != .exit {
                    continuation.resume(throwing: FluidAudioSTTModelServiceError.downloadFailed(
                        detail: "stt terminated unexpectedly."
                    ))
                    return
                }

                if process.terminationStatus != 0, runtime < minimumRuntime {
                    continuation.resume(throwing: FluidAudioSTTModelServiceError.downloadFailed(
                        detail: "stt exited with status \(process.terminationStatus) too quickly."
                    ))
                    return
                }

                continuation.resume()
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func makeSilentWAV(at url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
        guard let format else {
            throw FluidAudioSTTModelServiceError.audioPreparationFailed
        }

        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCapacity: AVAudioFrameCount = 16_000
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else {
            throw FluidAudioSTTModelServiceError.audioPreparationFailed
        }

        buffer.frameLength = frameCapacity
        if let channelData = buffer.floatChannelData {
            channelData[0].initialize(repeating: 0, count: Int(frameCapacity))
        }

        try file.write(from: buffer)
    }

    private func directorySize(at url: URL) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true,
                  let fileSize = values.fileSize else {
                continue
            }
            total += Int64(fileSize)
        }
        return total
    }

    private func coreMLCheck(missingASR: [String]) async -> TranscriptionTechnologyCheck {
        let title = String(localized: "Core ML runtime")
        let probeRelativePath = Self.asrRelativePaths[0]
        guard !missingASR.contains(probeRelativePath) else {
            return check(
                id: "core-ml",
                title: title,
                detail: String(localized: "Core ML is available; model loading can be verified after the models are downloaded."),
                status: .warning
            )
        }

        do {
            try await coreMLModelLoader(modelsDirectoryURL.appendingPathComponent(probeRelativePath))
            return check(
                id: "core-ml",
                title: title,
                detail: String(localized: "A FluidAudio Core ML model loaded successfully."),
                status: .ready
            )
        } catch {
            return check(
                id: "core-ml",
                title: title,
                detail: String(
                    format: String(localized: "Core ML could not load the model: %@"),
                    error.localizedDescription
                ),
                status: .unavailable
            )
        }
    }

    private func modelFilesCheck(
        id: String,
        title: String,
        missingPaths: [String]
    ) -> TranscriptionTechnologyCheck {
        guard missingPaths.isEmpty else {
            return check(
                id: id,
                title: title,
                detail: String(
                    format: String(localized: "Missing files: %d"),
                    missingPaths.count
                ),
                status: .unavailable
            )
        }
        return check(
            id: id,
            title: title,
            detail: String(localized: "Installed and ready."),
            status: .ready
        )
    }

    private func isModelStorageWritable() -> Bool {
        var candidate = modelsDirectoryURL
        while !fileManager.fileExists(atPath: candidate.path),
              candidate.path != candidate.deletingLastPathComponent().path {
            candidate.deleteLastPathComponent()
        }
        return fileManager.isWritableFile(atPath: candidate.path)
    }

    private func writableDirectoryDescription() -> String {
        if isModelStorageWritable() {
            return modelsDirectoryURL.path
        }
        return String(
            format: String(localized: "No write access to %@"),
            modelsDirectoryURL.path
        )
    }

    private func check(
        id: String,
        title: String,
        detail: String,
        status: TranscriptionTechnologyCheck.Status,
        isRequired: Bool = true
    ) -> TranscriptionTechnologyCheck {
        TranscriptionTechnologyCheck(
            id: id,
            title: title,
            detail: detail,
            status: status,
            isRequired: isRequired
        )
    }
}
