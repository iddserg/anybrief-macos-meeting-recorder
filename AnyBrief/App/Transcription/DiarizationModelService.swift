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

final class DiarizationModelService {
    static let modelsDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FluidAudio/Models", isDirectory: true)
    static let relativePaths = [
        "speaker-diarization/Segmentation.mlmodelc",
        "speaker-diarization/FBank.mlmodelc",
        "speaker-diarization/Embedding.mlmodelc",
        "speaker-diarization/PldaRho.mlmodelc",
        "speaker-diarization/plda-parameters.json",
    ]

    private let fileManager: FileManager
    private let sttURLResolver: () throws -> URL
    private let root: URL

    init(fileManager: FileManager = .default, sttURLResolver: @escaping () throws -> URL = CLIPathResolver.resolveStt,
         modelsDirectoryURL: URL = DiarizationModelService.modelsDirectoryURL) {
        self.fileManager = fileManager
        self.sttURLResolver = sttURLResolver
        self.root = modelsDirectoryURL
    }

    var missingRelativePaths: [String] {
        Self.relativePaths.filter { !fileManager.fileExists(atPath: root.appendingPathComponent($0).path) }
    }

    func downloadModels() async throws {
        let process = Process()
        process.executableURL = try sttURLResolver()
        process.arguments = ["--prepare-diarization-models"]
        try process.run()
        do {
            while process.isRunning { try await Task.sleep(nanoseconds: 100_000_000) }
            guard process.terminationStatus == 0 else {
                throw TranscriptionError(message: "Diarization model preparation failed: \(process.terminationStatus)")
            }
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}
