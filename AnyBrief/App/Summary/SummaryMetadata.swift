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

struct SummaryTranscriptionMetadata {
    let provider: String
    let model: String
    let language: String?
    let acceleration: String?
    let diarizationEnabled: Bool
    let speakersMode: String
    let speakersCount: Int
    let systemSpeakers: String
    let microphoneSpeakers: Int
    let threshold: Double

    init(
        provider: String = TranscriptionProviderID.fluidAudioSTT.rawValue,
        model: String = "nvidia-parakeet-tdt-0.6b-v3",
        language: String? = nil,
        acceleration: String? = "core_ml",
        diarizationEnabled: Bool = true,
        speakersMode: String,
        speakersCount: Int,
        systemSpeakers: String,
        microphoneSpeakers: Int,
        threshold: Double
    ) {
        self.provider = provider
        self.model = model
        self.language = language
        self.acceleration = acceleration
        self.diarizationEnabled = diarizationEnabled
        self.speakersMode = speakersMode
        self.speakersCount = speakersCount
        self.systemSpeakers = systemSpeakers
        self.microphoneSpeakers = microphoneSpeakers
        self.threshold = threshold
    }
}

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
