import Foundation

public struct DiarizationDocument: Decodable, Equatable, Sendable {
    public struct Segment: Decodable, Equatable, Sendable {
        public let start: Double
        public let end: Double
        public let speaker: String
        public let quality: Double

        public init(start: Double, end: Double, speaker: String, quality: Double) {
            self.start = start
            self.end = end
            self.speaker = speaker
            self.quality = quality
        }
    }

    public let schemaVersion: Int
    public let duration: Double
    public let segments: [Segment]

    public init(schemaVersion: Int = 1, duration: Double, segments: [Segment]) {
        self.schemaVersion = schemaVersion
        self.duration = duration
        self.segments = segments
    }
}

public struct WhisperDocument: Decodable, Sendable {
    public struct Segment: Decodable, Sendable {
        public struct Offsets: Decodable, Sendable {
            public let from: Int
            public let to: Int
        }

        public struct Token: Decodable, Sendable {
            public let text: String
            public let offsets: Offsets?
        }

        public let offsets: Offsets
        public let text: String
        public let tokens: [Token]?
    }

    public let transcription: [Segment]
}

public struct TimedText: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public struct SpeakerTurn: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: String
    public let text: String

    public init(start: Double, end: Double, speaker: String, text: String) {
        self.start = start
        self.end = end
        self.speaker = speaker
        self.text = text
    }
}
