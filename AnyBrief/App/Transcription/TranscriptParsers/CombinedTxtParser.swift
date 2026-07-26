import Foundation

/// Parses stt `<name>_combined.txt` files into transcript segments.
///
/// Supports known combined.txt variants emitted by bundled STT tools.
struct CombinedTxtParser {
    enum ParseError: LocalizedError, Equatable {
        case invalidHeader(line: Int, text: String)
        case invalidTimestamp(String)

        var errorDescription: String? {
            switch self {
            case let .invalidHeader(line, text):
                return "Invalid combined.txt header at line \(line): \(text)"
            case let .invalidTimestamp(value):
                return "Invalid combined.txt timestamp: \(value)"
            }
        }
    }

    private struct RawSegment {
        let startTime: TimeInterval
        let endTime: TimeInterval?
        let speaker: String
        let text: String
    }

    // Format A: [MM:SS] Speaker A: inline text
    private let headerRegexA = /^\[(\d{2}:\d{2})\] (Speaker \w+): (.+)$/

    // Format B: [MM:SS.mmm - MM:SS.mmm] Speaker 1:   (text follows on next lines)
    private let headerRegexB = /^\[(\d{2}:\d{2}\.\d{3}) - (\d{2}:\d{2}\.\d{3})\] (Speaker \w+):$/

    func parse(fileURL: URL, sourceTrack: SourceTrack) throws -> [TranscriptSegment] {
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = content.components(separatedBy: .newlines)

        // FluidAudio can occasionally return no diarization turns while ASR still
        // succeeds. Older stt builds wrote that plain ASR text directly into
        // combined.txt. Preserve the transcript as one unknown-speaker segment
        // instead of failing the entire recording pipeline.
        let hasKnownHeader = lines.contains {
            $0.wholeMatch(of: headerRegexA) != nil || $0.wholeMatch(of: headerRegexB) != nil
        }
        if !hasKnownHeader {
            let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [
                TranscriptSegment(
                    startTime: 0,
                    endTime: 30,
                    speaker: sourceTrack == .mic ? "Mic" : "Speaker A",
                    text: text,
                    sourceTrack: sourceTrack
                ),
            ]
        }

        var raw: [RawSegment] = []
        var currentSpeaker: String?
        var currentStart: TimeInterval?
        var currentEnd: TimeInterval?
        var currentTextLines: [String] = []

        func flush() {
            guard let speaker = currentSpeaker, let start = currentStart else { return }
            raw.append(RawSegment(
                startTime: start,
                endTime: currentEnd,
                speaker: speaker,
                text: currentTextLines.joined(separator: "\n")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            ))
        }

        for (index, line) in lines.enumerated() {
            if let match = line.wholeMatch(of: headerRegexA) {
                flush()
                currentStart = try parseTimestampShort(String(match.1))
                currentEnd = nil
                currentSpeaker = String(match.2)
                currentTextLines = [String(match.3)]
                continue
            }

            if let match = line.wholeMatch(of: headerRegexB) {
                flush()
                currentStart = try parseTimestampFull(String(match.1))
                currentEnd = try parseTimestampFull(String(match.2))
                currentSpeaker = String(match.3)
                currentTextLines = []
                continue
            }

            if currentSpeaker == nil {
                guard line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ParseError.invalidHeader(line: index + 1, text: line)
                }
                continue
            }

            currentTextLines.append(line)
        }
        flush()

        return raw.enumerated().map { i, seg in
            let endTime: TimeInterval
            if let explicit = seg.endTime {
                endTime = explicit
            } else if i + 1 < raw.count {
                endTime = raw[i + 1].startTime
            } else {
                endTime = seg.startTime + 30
            }
            return TranscriptSegment(
                startTime: seg.startTime,
                endTime: endTime,
                speaker: qualifiedSpeaker(seg.speaker, sourceTrack: sourceTrack),
                text: seg.text,
                sourceTrack: sourceTrack
            )
        }
    }

    // System speakers keep diarization labels; mic segments are the local user.
    private func qualifiedSpeaker(_ speaker: String, sourceTrack: SourceTrack) -> String {
        switch sourceTrack {
        case .system: return speaker
        case .mic:    return "Mic"
        }
    }

    private func parseTimestampShort(_ value: String) throws -> TimeInterval {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard
            parts.count == 2,
            let minutes = TimeInterval(parts[0]),
            let seconds = TimeInterval(parts[1])
        else {
            throw ParseError.invalidTimestamp(value)
        }
        return minutes * 60 + seconds
    }

    private func parseTimestampFull(_ value: String) throws -> TimeInterval {
        let parts = value.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else {
            throw ParseError.invalidTimestamp(value)
        }

        let secondParts = parts[1].split(separator: ".", maxSplits: 1)
        guard
            secondParts.count == 2,
            let minutes = TimeInterval(parts[0]),
            let seconds = TimeInterval(secondParts[0]),
            let milliseconds = TimeInterval(secondParts[1])
        else {
            throw ParseError.invalidTimestamp(value)
        }

        return minutes * 60 + seconds + milliseconds / 1_000
    }
}
