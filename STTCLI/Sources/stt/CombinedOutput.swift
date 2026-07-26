import FluidAudio
import Foundation

extension AudioProcessor {
    private struct SpeakerTurn {
        let speaker: String
        let startTime: Double
        var endTime: Double
        var text: String
    }

    /// Align full-pass ASR words with diarization by their real timestamps.
    func combineTranscriptionWithDiarization(
        wordTimings: [WordTiming],
        diarizationResult: DiarizationResult,
        maximumJoinGap: Double = 2.0,
        maximumNearestDistance: Double = 2.5
    ) -> String {
        let segments = diarizationResult.segments.sorted { lhs, rhs in
            if lhs.startTimeSeconds == rhs.startTimeSeconds {
                return lhs.endTimeSeconds < rhs.endTimeSeconds
            }
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        guard !wordTimings.isEmpty else { return "" }

        let labels = speakerLabels(segments.map(\.speakerId))
        var turns: [SpeakerTurn] = []

        for word in wordTimings where !word.word.isEmpty {
            let speakerID = bestSpeaker(
                for: word,
                segments: segments,
                maximumNearestDistance: maximumNearestDistance
            )
            let speaker = speakerID.flatMap { labels[$0] } ?? "Speaker Unknown"

            if let previous = turns.last,
               previous.speaker == speaker,
               word.startTime - previous.endTime <= maximumJoinGap {
                turns[turns.count - 1].endTime = max(previous.endTime, word.endTime)
                turns[turns.count - 1].text = join(previous.text, word.word)
            } else {
                turns.append(
                    SpeakerTurn(
                        speaker: speaker,
                        startTime: word.startTime,
                        endTime: word.endTime,
                        text: word.word
                    )
                )
            }
        }

        return turns.map {
            "[\(clock($0.startTime))] \($0.speaker): \($0.text)"
        }.joined(separator: "\n")
    }

    /// Preserve ASR timing without loading diarization models.
    func combineTranscriptionWithoutDiarization(
        wordTimings: [WordTiming],
        speaker: String = "Speaker A",
        maximumJoinGap: Double = 2.0
    ) -> String {
        var turns: [SpeakerTurn] = []

        for word in wordTimings where !word.word.isEmpty {
            if let previous = turns.last,
               word.startTime - previous.endTime <= maximumJoinGap {
                turns[turns.count - 1].endTime = max(previous.endTime, word.endTime)
                turns[turns.count - 1].text = join(previous.text, word.word)
            } else {
                turns.append(
                    SpeakerTurn(
                        speaker: speaker,
                        startTime: word.startTime,
                        endTime: word.endTime,
                        text: word.word
                    )
                )
            }
        }

        return turns.map {
            "[\(clock($0.startTime))] \($0.speaker): \($0.text)"
        }.joined(separator: "\n")
    }

    private func bestSpeaker(
        for word: WordTiming,
        segments: [TimedSpeakerSegment],
        maximumNearestDistance: Double
    ) -> String? {
        let midpoint = (word.startTime + word.endTime) / 2
        let containing = segments.filter {
            Double($0.startTimeSeconds) <= midpoint && midpoint < Double($0.endTimeSeconds)
        }
        if let best = containing.max(by: { lhs, rhs in
            if lhs.qualityScore == rhs.qualityScore {
                return overlap(word, lhs) < overlap(word, rhs)
            }
            return lhs.qualityScore < rhs.qualityScore
        }) {
            return best.speakerId
        }

        var bestOverlapping: (segment: TimedSpeakerSegment, overlap: Double)?
        for segment in segments {
            let overlapDuration = overlap(word, segment)
            guard overlapDuration > 0 else { continue }
            if let current = bestOverlapping {
                if overlapDuration > current.overlap
                    || (overlapDuration == current.overlap
                        && segment.qualityScore > current.segment.qualityScore) {
                    bestOverlapping = (segment, overlapDuration)
                }
            } else {
                bestOverlapping = (segment, overlapDuration)
            }
        }
        if let bestOverlapping {
            return bestOverlapping.segment.speakerId
        }

        var nearest: (segment: TimedSpeakerSegment, distance: Double)?
        for segment in segments {
            let candidateDistance = distance(word, segment)
            if let current = nearest {
                if candidateDistance < current.distance
                    || (candidateDistance == current.distance
                        && segment.qualityScore > current.segment.qualityScore) {
                    nearest = (segment, candidateDistance)
                }
            } else {
                nearest = (segment, candidateDistance)
            }
        }
        guard let nearest, nearest.distance <= maximumNearestDistance else {
            return nil
        }
        return nearest.segment.speakerId
    }

    private func overlap(_ word: WordTiming, _ segment: TimedSpeakerSegment) -> Double {
        max(
            0,
            min(word.endTime, Double(segment.endTimeSeconds))
                - max(word.startTime, Double(segment.startTimeSeconds))
        )
    }

    private func distance(_ word: WordTiming, _ segment: TimedSpeakerSegment) -> Double {
        if overlap(word, segment) > 0 {
            return 0
        }
        return word.endTime <= Double(segment.startTimeSeconds)
            ? Double(segment.startTimeSeconds) - word.endTime
            : word.startTime - Double(segment.endTimeSeconds)
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

    private func join(_ lhs: String, _ rhs: String) -> String {
        guard let first = rhs.first else { return lhs }
        return ".,!?;:)]}".contains(first) ? lhs + rhs : lhs + " " + rhs
    }

    private func clock(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }
}
