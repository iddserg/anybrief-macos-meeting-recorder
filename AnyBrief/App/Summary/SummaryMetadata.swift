import Foundation

struct SummarizationResult {
    let summary: String
    let provider: SummaryProviderMetadata
}

struct SummaryProviderMetadata {
    let type: SummaryProvider
    let title: String
    let model: String
    let apiURL: String?
    let timeoutSec: Int
    let retryCount: Int?
    let commandPreset: String?
    let commandLine: String?
    let ollamaContextLength: Int?
    let ollamaChunkThreshold: Int?
    let ollamaChunkSize: Int?
}

struct SummaryMetadata {
    let transcription: SummaryTranscriptionMetadata
    let audio: SummaryAudioMetadata
    let calendar: CalendarEvent?
    let warnings: [String]

    init(
        transcription: SummaryTranscriptionMetadata,
        audio: SummaryAudioMetadata,
        calendar: CalendarEvent?,
        warnings: [String] = []
    ) {
        self.transcription = transcription
        self.audio = audio
        self.calendar = calendar
        self.warnings = warnings
    }
}

typealias SummaryTranscriptionMetadata = TranscriptionMetadata

struct SummaryAudioMetadata {
    let system: SummaryAudioTrackMetadata
    let microphone: SummaryAudioTrackMetadata
}

struct SummaryAudioTrackMetadata {
    let status: String
    let durationSeconds: Double
    let sizeBytes: Int
    let segments: Int
    let speakers: Int
}
