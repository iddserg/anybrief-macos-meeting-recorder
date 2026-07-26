import Foundation

struct WhisperCppModel: Identifiable, Equatable {
    let id: String
    let diskSize: String

    var filename: String {
        "ggml-\(id).bin"
    }

    var displayName: String {
        "\(id) · \(diskSize)"
    }
}

enum WhisperCppModelServiceError: LocalizedError {
    case unknownModel(String)
    case invalidDownload

    var errorDescription: String? {
        switch self {
        case .unknownModel(let model):
            return String(format: String(localized: "Unknown Whisper model: %@"), model)
        case .invalidDownload:
            return String(localized: "The downloaded Whisper model is invalid.")
        }
    }
}

final class WhisperCppModelService {
    static let vadModelFilename = "ggml-silero-v6.2.0.bin"
    static let vadModelDownloadURL = URL(
        string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin"
    )!

    static let models: [WhisperCppModel] = [
        WhisperCppModel(id: "tiny", diskSize: "75 MB"),
        WhisperCppModel(id: "base", diskSize: "142 MB"),
        WhisperCppModel(id: "small", diskSize: "466 MB"),
        WhisperCppModel(id: "medium", diskSize: "1.5 GB"),
        WhisperCppModel(id: "large-v3-turbo-q5_0", diskSize: "547 MB"),
    ]

    static let supportedLanguageCodes = [
        "auto", "ru", "en", "de", "fr", "es", "it", "pt", "pl", "nl", "uk",
        "tr", "ja", "zh", "ko",
    ]

    static let modelsDirectoryURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/AnyBrief/stt-whisper/models", isDirectory: true)

    private let fileManager: FileManager
    private let modelsDirectoryURL: URL
    private let download: (URL) async throws -> URL

    init(
        fileManager: FileManager = .default,
        modelsDirectoryURL: URL = WhisperCppModelService.modelsDirectoryURL,
        download: @escaping (URL) async throws -> URL = { url in
            let (temporaryURL, response) = try await URLSession.shared.download(from: url)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<300).contains(httpResponse.statusCode) else {
                throw WhisperCppModelServiceError.invalidDownload
            }
            return temporaryURL
        }
    ) {
        self.fileManager = fileManager
        self.modelsDirectoryURL = modelsDirectoryURL
        self.download = download
    }

    static func model(named name: String) -> WhisperCppModel? {
        models.first { $0.id == name }
    }

    func modelURL(named name: String) throws -> URL {
        guard let model = Self.model(named: name) else {
            throw WhisperCppModelServiceError.unknownModel(name)
        }
        return modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
    }

    func vadModelURL() -> URL {
        modelsDirectoryURL.appendingPathComponent(Self.vadModelFilename, isDirectory: false)
    }

    func isModelInstalled(named name: String) -> Bool {
        guard let url = try? modelURL(named: name) else { return false }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 1_000_000
    }

    func isVADModelInstalled() -> Bool {
        let size = (try? vadModelURL().resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return size > 100_000
    }

    func status(model name: String) -> TranscriptionModelStatus {
        let modelURL = try? modelURL(named: name)
        let modelSize = modelURL.flatMap {
            try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } ?? 0
        let vadURL = vadModelURL()
        let vadSize = (try? vadURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let modelInstalled = isModelInstalled(named: name)
        let vadInstalled = isVADModelInstalled()
        var missing: [String] = []
        if !modelInstalled {
            missing.append(modelURL?.lastPathComponent ?? name)
        }
        if !vadInstalled {
            missing.append(vadURL.lastPathComponent)
        }
        return TranscriptionModelStatus(
            modelsDirectoryURL: modelsDirectoryURL,
            isInstalled: modelInstalled && vadInstalled,
            installedSizeBytes: Int64(modelSize + vadSize),
            missingRelativePaths: missing
        )
    }

    func downloadModel(named name: String) async throws {
        guard let model = Self.model(named: name),
              let sourceURL = URL(
                string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(model.filename)"
              ) else {
            throw WhisperCppModelServiceError.unknownModel(name)
        }
        try fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
        try await downloadModelFile(
            from: sourceURL,
            to: try modelURL(named: name),
            minimumSize: 1_000_000
        )
        try await downloadModelFile(
            from: Self.vadModelDownloadURL,
            to: vadModelURL(),
            minimumSize: 100_000
        )
    }

    func ensureVADModel() async throws {
        let destinationURL = vadModelURL()
        let size = (try? destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 100_000 else { return }
        try fileManager.createDirectory(at: modelsDirectoryURL, withIntermediateDirectories: true)
        try await downloadModelFile(
            from: Self.vadModelDownloadURL,
            to: destinationURL,
            minimumSize: 100_000
        )
    }

    private func downloadModelFile(
        from sourceURL: URL,
        to destinationURL: URL,
        minimumSize: Int
    ) async throws {
        let temporaryURL = try await download(sourceURL)
        let values = try temporaryURL.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) > minimumSize else {
            throw WhisperCppModelServiceError.invalidDownload
        }
        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }
        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
    }
}
