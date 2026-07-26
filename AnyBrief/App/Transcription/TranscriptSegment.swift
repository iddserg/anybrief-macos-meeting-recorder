import Foundation

/// One speaker segment parsed from an stt `<name>_combined.txt` file.
struct TranscriptSegment: Equatable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let speaker: String
    let text: String
    let sourceTrack: SourceTrack
}

/// Audio source that produced a transcript segment.
enum SourceTrack: String, Codable, Equatable {
    case system
    case mic
}

extension TranscriptSegment: Codable {
    private enum CodingKeys: String, CodingKey {
        case sourceTrack
        case speaker
        case startMs
        case endMs
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        startTime = TimeInterval(try container.decode(Int.self, forKey: .startMs)) / 1_000
        endTime = TimeInterval(try container.decode(Int.self, forKey: .endMs)) / 1_000
        speaker = try container.decode(String.self, forKey: .speaker)
        text = try container.decode(String.self, forKey: .text)
        sourceTrack = try container.decode(SourceTrack.self, forKey: .sourceTrack)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceTrack, forKey: .sourceTrack)
        try container.encode(speaker, forKey: .speaker)
        try container.encode(Int((startTime * 1_000).rounded()), forKey: .startMs)
        try container.encode(Int((endTime * 1_000).rounded()), forKey: .endMs)
        try container.encode(text, forKey: .text)
    }
}
