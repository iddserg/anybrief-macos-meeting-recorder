import Foundation

public struct TemporalMerger: Sendable {
    public let maximumJoinGap: Double

    public init(maximumJoinGap: Double = 2.0) {
        self.maximumJoinGap = maximumJoinGap
    }

    public func timedText(from document: WhisperDocument) -> [TimedText] {
        let compactedTokenTimeline = usesCompactedTokenTimeline(document)
        let tokenWords = document.transcription.flatMap {
            words(in: $0, compactedTokenTimeline: compactedTokenTimeline)
        }
        if !tokenWords.isEmpty {
            return tokenWords
        }
        return document.transcription.compactMap { segment in
            let text = clean(segment.text)
            guard !text.isEmpty else { return nil }
            return TimedText(
                start: milliseconds(segment.offsets.from),
                end: milliseconds(segment.offsets.to),
                text: text
            )
        }
    }

    public func merge(
        whisper: WhisperDocument,
        diarization: DiarizationDocument
    ) -> [SpeakerTurn] {
        let labels = speakerLabels(diarization.segments.map(\.speaker))
        let pieces = timedText(from: whisper)
        var result: [SpeakerTurn] = []

        for piece in pieces {
            let speakerID = bestSpeaker(for: piece, segments: diarization.segments)
            let speaker = speakerID.flatMap { labels[$0] } ?? "Speaker Unknown"
            if let previous = result.last,
               previous.speaker == speaker,
               piece.start - previous.end <= maximumJoinGap {
                result[result.count - 1] = SpeakerTurn(
                    start: previous.start,
                    end: max(previous.end, piece.end),
                    speaker: speaker,
                    text: join(previous.text, piece.text)
                )
            } else {
                result.append(SpeakerTurn(
                    start: piece.start,
                    end: piece.end,
                    speaker: speaker,
                    text: piece.text
                ))
            }
        }
        return result
    }

    public func transcript(from document: WhisperDocument) -> String {
        document.transcription
            .map { clean($0.text) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    public func combinedText(from turns: [SpeakerTurn]) -> String {
        turns.map { "[\(clock($0.start))] \($0.speaker): \($0.text)" }
            .joined(separator: "\n")
    }

    public func turnsWithoutDiarization(
        from document: WhisperDocument,
        speaker: String = "Speaker A"
    ) -> [SpeakerTurn] {
        var result: [SpeakerTurn] = []

        for piece in timedText(from: document) {
            if let previous = result.last,
               piece.start - previous.end <= maximumJoinGap {
                result[result.count - 1] = SpeakerTurn(
                    start: previous.start,
                    end: max(previous.end, piece.end),
                    speaker: speaker,
                    text: join(previous.text, piece.text)
                )
            } else {
                result.append(
                    SpeakerTurn(
                        start: piece.start,
                        end: piece.end,
                        speaker: speaker,
                        text: piece.text
                    )
                )
            }
        }
        return result
    }

    private func words(
        in segment: WhisperDocument.Segment,
        compactedTokenTimeline: Bool
    ) -> [TimedText] {
        guard let tokens = segment.tokens else { return [] }
        let timedTokens = tokens.filter {
            !isSpecialToken($0.text) && $0.offsets != nil
        }
        let timelineOffset: Int
        if compactedTokenTimeline,
           let lastOffset = timedTokens.last?.offsets {
            // whisper.cpp keeps segment offsets on the original audio timeline
            // when VAD is enabled, but token offsets use the silence-compacted
            // timeline. Anchor each token group to the segment end to restore
            // the original timestamps.
            timelineOffset = segment.offsets.to - lastOffset.to
        } else {
            timelineOffset = 0
        }
        var output: [TimedText] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd: Double?

        func flush() {
            let text = clean(currentText)
            if let currentStart, let currentEnd, !text.isEmpty {
                output.append(TimedText(start: currentStart, end: currentEnd, text: text))
            }
            currentText = ""
            currentStart = nil
            currentEnd = nil
        }

        for token in tokens {
            guard !isSpecialToken(token.text), let offsets = token.offsets else {
                continue
            }
            if token.text.first?.isWhitespace == true, !currentText.isEmpty {
                flush()
            }
            if currentStart == nil {
                currentStart = milliseconds(offsets.from + timelineOffset)
            }
            currentEnd = milliseconds(offsets.to + timelineOffset)
            currentText += token.text
        }
        flush()
        return output
    }

    private func usesCompactedTokenTimeline(_ document: WhisperDocument) -> Bool {
        document.transcription.contains { segment in
            segment.tokens?.contains { token in
                guard !isSpecialToken(token.text), let offsets = token.offsets else {
                    return false
                }
                return offsets.to < segment.offsets.from - 1_000
                    || offsets.from > segment.offsets.to + 1_000
            } ?? false
        }
    }

    private func bestSpeaker(
        for piece: TimedText,
        segments: [DiarizationDocument.Segment]
    ) -> String? {
        let midpoint = (piece.start + piece.end) / 2
        let containing = segments.filter { $0.start <= midpoint && midpoint < $0.end }
        if let best = containing.max(by: { lhs, rhs in
            if lhs.quality == rhs.quality {
                return overlap(piece, lhs) < overlap(piece, rhs)
            }
            return lhs.quality < rhs.quality
        }) {
            return best.speaker
        }

        if let overlapping = segments
            .map({ ($0, overlap(piece, $0)) })
            .filter({ $0.1 > 0 })
            .max(by: { $0.1 < $1.1 }) {
            return overlapping.0.speaker
        }

        let candidates: [(segment: DiarizationDocument.Segment, distance: Double)] =
            segments.map { segment in
                (segment: segment, distance: distance(piece, segment))
            }
        let nearest = candidates.min(by: { lhs, rhs in
                lhs.1 == rhs.1 ? lhs.0.quality > rhs.0.quality : lhs.1 < rhs.1
            })
        guard let nearest, nearest.1 <= 2.5 else {
            return nil
        }
        return nearest.0.speaker
    }

    private func overlap(_ text: TimedText, _ segment: DiarizationDocument.Segment) -> Double {
        max(0, min(text.end, segment.end) - max(text.start, segment.start))
    }

    private func distance(_ text: TimedText, _ segment: DiarizationDocument.Segment) -> Double {
        if overlap(text, segment) > 0 {
            return 0
        }
        return text.end <= segment.start ? segment.start - text.end : text.start - segment.end
    }

    private func speakerLabels(_ speakerIDs: [String]) -> [String: String] {
        let unique = Array(Set(speakerIDs)).sorted {
            if let lhs = Int($0), let rhs = Int($1) {
                return lhs < rhs
            }
            return $0.localizedStandardCompare($1) == .orderedAscending
        }
        return Dictionary(uniqueKeysWithValues: unique.enumerated().map { index, id in
            let label: String
            if index < 26, let scalar = UnicodeScalar(65 + index) {
                label = "Speaker \(Character(scalar))"
            } else {
                label = "Speaker \(index + 1)"
            }
            return (id, label)
        })
    }

    private func milliseconds(_ value: Int) -> Double {
        Double(value) / 1_000
    }

    private func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isSpecialToken(_ text: String) -> Bool {
        text.hasPrefix("<|") || (text.hasPrefix("[_") && text.hasSuffix("]"))
    }

    private func join(_ lhs: String, _ rhs: String) -> String {
        guard let first = rhs.first else { return lhs }
        return ".,!?;:)]}".contains(first) ? lhs + rhs : lhs + " " + rhs
    }

    private func clock(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
