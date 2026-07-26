import Foundation

enum TranscriptionProviderID: String, Codable, CaseIterable, Identifiable {
    case fluidAudioSTT = "fluid_audio_stt"
    case whisperCpp = "whisper_cpp"

    var id: String { rawValue }
}

struct TranscriptionProviderConfiguration: Codable, Identifiable, Equatable {
    var id = UUID().uuidString.lowercased()
    var provider: TranscriptionProviderID = .fluidAudioSTT
    var enabled = true
    var payload: ConfigurationPayload = [:]

    enum CodingKeys: String, CodingKey {
        case id
        case provider
        case enabled
        case payload
    }

    init(
        id: String = UUID().uuidString.lowercased(),
        provider: TranscriptionProviderID = .fluidAudioSTT,
        enabled: Bool = true,
        payload: ConfigurationPayload = [:]
    ) {
        self.id = id
        self.provider = provider
        self.enabled = enabled
        self.payload = payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString.lowercased()
        provider = try container.decodeIfPresent(TranscriptionProviderID.self, forKey: .provider) ?? .fluidAudioSTT
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        payload = try container.decodeIfPresent(ConfigurationPayload.self, forKey: .payload) ?? [:]
    }
}

enum TranscriptionTrack {
    case system
    case mic

    var sourceTrack: SourceTrack {
        switch self {
        case .system:
            return .system
        case .mic:
            return .mic
        }
    }

    var outputDirectoryName: String {
        switch self {
        case .system:
            return "stt-system"
        case .mic:
            return "stt-mic"
        }
    }
}

struct TranscriptionInput {
    let wavURL: URL
    let outputDir: URL
    let sourceTrack: SourceTrack
    let settings: AppSettings
    let logURL: URL
}

struct TranscriptionResult {
    let segments: [TranscriptSegment]
    let outputDir: URL
    let combinedTxtURL: URL
}

struct TranscriptionRuntimeContext {
    let fileManager: FileManager
}

struct TranscriptionDiagnosticsContext {
    let fileManager: FileManager
}

struct TranscriptionDiagnosticResult: Equatable {
    enum Status: Equatable {
        case success
        case failure
    }

    let status: Status
    let message: String
    var technologyChecks: [TranscriptionTechnologyCheck] = []
}

struct TranscriptionTechnologyCheck: Identifiable, Equatable {
    enum Status: Equatable {
        case ready
        case warning
        case unavailable
    }

    let id: String
    let title: String
    let detail: String
    let status: Status
    let isRequired: Bool
}

protocol TranscriptionProvider {
    var id: TranscriptionProviderID { get }

    func transcribe(input: TranscriptionInput) async throws -> TranscriptionResult
}

protocol TranscriptionDiagnostics {
    func diagnose(configuration: TranscriptionProviderConfiguration, settings: AppSettings) async -> TranscriptionDiagnosticResult
}

protocol TranscriptionProviderModule {
    var id: TranscriptionProviderID { get }
    var title: String { get }
    var systemImage: String { get }

    func defaultConfiguration() -> TranscriptionProviderConfiguration
    func normalize(_ configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration
    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider
    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics
}

extension TranscriptionProviderModule {
    func normalize(_ configuration: TranscriptionProviderConfiguration) -> TranscriptionProviderConfiguration {
        configuration
    }
}

struct TranscriptionError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

struct TranscriptionTimeoutError: LocalizedError {
    let timeout: TimeInterval
    let wavPath: String

    var errorDescription: String? {
        "stt timed out after \(Int(timeout)) seconds for \(wavPath)."
    }
}
