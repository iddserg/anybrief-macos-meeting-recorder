import Foundation

enum LiveTranscriptStatus: Equatable {
    case idle
    case waitingForRecording
    case starting
    case running
    case transcribing
    case stopping
    case failed(String)

    var isRunning: Bool {
        switch self {
        case .starting, .running, .transcribing, .stopping:
            return true
        case .idle, .waitingForRecording, .failed:
            return false
        }
    }
}

struct LiveTranscriptSnapshot: Equatable {
    var text = ""
    var status: LiveTranscriptStatus = .idle
    var isUserEnabled = false
    var lastUpdatedAt: Date?
    var nextChunkAt: Date?
    var lastChunkMessage: String?

    var isRunning: Bool {
        status.isRunning
    }
}

struct LiveAudioChunk: Sendable {
    let url: URL
    let duration: TimeInterval
    let sampleCount: Int
    let peakAmplitude: Float
    let rmsAmplitude: Float
    let byteSize: Int64

    init(
        url: URL,
        duration: TimeInterval,
        sampleCount: Int = 0,
        peakAmplitude: Float = 0,
        rmsAmplitude: Float = 0,
        byteSize: Int64 = 0
    ) {
        self.url = url
        self.duration = duration
        self.sampleCount = sampleCount
        self.peakAmplitude = peakAmplitude
        self.rmsAmplitude = rmsAmplitude
        self.byteSize = byteSize
    }
}

struct LiveAudioCaptureDiagnostics: Sendable {
    var isCapturing = false
    var receivedAudioBuffers = 0
    var appendedAudioBuffers = 0
    var droppedAudioBuffers = 0
    var bufferedSamples = 0
    var bufferedDuration: TimeInterval = 0
    var sampleRate: Double?
    var lastAudioAt: Date?
    var lastDropReason: String?
}

protocol LiveAudioCapturing: AnyObject {
    func start() async throws
    func stop() async
    func writeRecentChunk(duration: TimeInterval) async throws -> LiveAudioChunk?
    func diagnostics() -> LiveAudioCaptureDiagnostics
}

protocol LiveSTTRunning: AnyObject {
    func transcribe(chunk: LiveAudioChunk) async throws -> String
}

struct LiveTranscriptTextDisplayState: Equatable {
    private(set) var visibleText = ""
    private(set) var pendingText: String?
    private(set) var isUserInteractionActive = false

    mutating func applyIncomingText(_ text: String) {
        if isUserInteractionActive {
            pendingText = text
        } else {
            visibleText = text
            pendingText = nil
        }
    }

    mutating func setUserInteractionActive(_ isActive: Bool) {
        isUserInteractionActive = isActive
        guard !isActive, let pendingText else {
            return
        }
        visibleText = pendingText
        self.pendingText = nil
    }
}
