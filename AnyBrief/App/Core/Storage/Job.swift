import Foundation

/// Pipeline stage persisted with each job. Raw values are the strings stored in
/// `jobs.json` and exposed by the Local API, so they must stay stable.
enum JobStage: String, Codable, Equatable, Sendable {
    case recording
    case recorded
    case transcribingSystem = "transcribing_system"
    case transcribingMic = "transcribing_mic"
    case mergingTranscripts = "merging_transcripts"
    case processingTranscript = "processing_transcript"
    case summarizing
    case convertingAudio = "converting_audio"
    case packaging
    case completed
    case partialSuccess = "partial_success"
    case cancelled
}

/// Job state persisted in `~/anybrief/state/jobs.json`.
struct Job: Codable, Equatable, Sendable {
    struct ErrorState: Codable, Equatable, Sendable {
        let code: String
        let message: String
        let stage: String?
        let retryable: Bool
    }

    let id: String
    let meetingId: String
    let status: String
    let stage: JobStage
    let progressPercent: Int?
    let source: String
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
    let retryCount: Int
    let error: ErrorState?
    let warnings: [String]

    init(
        id: String,
        meetingId: String,
        status: String,
        stage: JobStage,
        progressPercent: Int? = nil,
        source: String,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date? = nil,
        retryCount: Int = 0,
        error: ErrorState? = nil,
        warnings: [String] = []
    ) {
        self.id = id
        self.meetingId = meetingId
        self.status = status
        self.stage = stage
        self.progressPercent = progressPercent
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.completedAt = completedAt
        self.retryCount = retryCount
        self.error = error
        self.warnings = warnings
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        meetingId = try container.decode(String.self, forKey: .meetingId)
        status = try container.decode(String.self, forKey: .status)
        let rawStage = try container.decode(String.self, forKey: .stage)
        // Persisted history may contain stage strings written by older app
        // versions; fall back instead of failing the whole jobs.json load.
        stage = JobStage(rawValue: rawStage)
            ?? (Self.isTerminalStatus(status) ? .completed : .recording)
        progressPercent = try container.decodeIfPresent(Int.self, forKey: .progressPercent)
        source = try container.decode(String.self, forKey: .source)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        retryCount = try container.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        error = try container.decodeIfPresent(ErrorState.self, forKey: .error)
        warnings = try container.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }
}

extension Job {
    var isTerminal: Bool {
        Self.isTerminalStatus(status)
    }

    static func isTerminalStatus(_ status: String) -> Bool {
        switch status {
        case "completed", "partial_success", "failed", "cancelled", "skipped":
            return true
        default:
            return false
        }
    }
}

/// Stage-to-progress mapping for persisted jobs and Local API responses.
enum JobProgress {
    static func percent(for stage: JobStage, status: String) -> Int {
        switch status {
        case "cancelled", "completed", "partial_success":
            return 100
        case "failed":
            return 0
        default:
            break
        }

        switch stage {
        case .recording:
            return 0
        case .recorded, .transcribingSystem:
            return 20
        case .transcribingMic:
            return 40
        case .mergingTranscripts:
            return 55
        case .processingTranscript:
            return 58
        case .summarizing:
            return 60
        case .convertingAudio:
            return 85
        case .packaging:
            return 92
        case .completed:
            return 100
        case .partialSuccess, .cancelled:
            // Terminal statuses are handled above; these stages without a
            // terminal status should not occur.
            return 0
        }
    }
}
