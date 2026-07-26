import FluidAudio
import Foundation

extension AudioProcessor {
    struct DiarizedTranscriptionResult {
        let plainTranscript: String
        let combinedTranscript: String
    }

    private struct DiarizedTranscriptionTurn {
        let label: String
        let startTime: Double
        let endTime: Double

        var duration: Double {
            endTime - startTime
        }
    }

    func transcribeDiarizedTurns(
        samples: [Float],
        diarizationResult: DiarizationResult
    ) async throws -> DiarizedTranscriptionResult {
        let turns = makeDiarizedTranscriptionTurns(from: diarizationResult)
        guard !turns.isEmpty else {
            verboseLog("⚠️ No diarization turns — falling back to plain transcription")
            let transcription = try await transcribeAudio(samples: samples)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return DiarizedTranscriptionResult(
                plainTranscript: transcription,
                combinedTranscript: transcription.isEmpty
                    ? ""
                    : "[00:00] Speaker A: \(transcription)"
            )
        }

        verboseLog("🤖 Initializing Parakeet v3 ASR model...")
        let asrManager = try await cachedAsrManager()

        let sampleRate = 16_000.0
        let paddingSeconds = 0.35
        let minimumDurationSeconds = 1.0
        let totalDuration = Double(samples.count) / sampleRate

        var plainParts: [String] = []
        var combinedParts: [String] = []

        for (index, turn) in turns.enumerated() {
            let paddedStart = max(0, turn.startTime - paddingSeconds)
            let paddedEnd = min(totalDuration, turn.endTime + paddingSeconds)
            let duration = paddedEnd - paddedStart

            guard duration >= minimumDurationSeconds else {
                verboseLog("⏭️ Skipping very short turn \(index + 1): \(String(format: "%.2fs", duration))")
                continue
            }

            let startSample = max(0, Int((paddedStart * sampleRate).rounded(.down)))
            let endSample = min(samples.count, Int((paddedEnd * sampleRate).rounded(.up)))
            guard startSample < endSample else { continue }

            let chunk = Array(samples[startSample..<endSample])
            verboseLog(
                "🧩 Turn \(index + 1)/\(turns.count) \(turn.label) \(formatClock(turn.startTime))-\(formatClock(turn.endTime))"
            )
            let text = try await transcribeAudio(samples: chunk, asrManager: asrManager)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            plainParts.append(text)
            combinedParts.append("[\(formatClock(turn.startTime))] \(turn.label): \(text)")
        }

        return DiarizedTranscriptionResult(
            plainTranscript: plainParts.joined(separator: " "),
            combinedTranscript: combinedParts.joined(separator: "\n")
        )
    }

    private func makeDiarizedTranscriptionTurns(from result: DiarizationResult) -> [DiarizedTranscriptionTurn] {
        let segments = result.segments.sorted { lhs, rhs in
            if lhs.startTimeSeconds == rhs.startTimeSeconds {
                return lhs.endTimeSeconds < rhs.endTimeSeconds
            }
            return lhs.startTimeSeconds < rhs.startTimeSeconds
        }
        guard !segments.isEmpty else { return [] }

        let uniqueIds = Array(Set(segments.map { $0.speakerId })).sorted()
        let speakerLabel: [String: String] = Dictionary(
            uniqueKeysWithValues: uniqueIds.enumerated().map { index, id in
                let label = if index < 26 {
                    "Speaker \(Character(UnicodeScalar(65 + index)!))"
                } else {
                    "Speaker \(index + 1)"
                }
                return (id, label)
            }
        )

        let mergeGapSeconds = 1.0
        let maxTurnDurationSeconds = 45.0
        var turns: [DiarizedTranscriptionTurn] = []
        var currentLabel: String?
        var currentStart = 0.0
        var currentEnd = 0.0

        func flushCurrent() {
            guard let currentLabel else { return }
            turns.append(
                DiarizedTranscriptionTurn(
                    label: currentLabel,
                    startTime: currentStart,
                    endTime: currentEnd
                )
            )
        }

        for segment in segments {
            let label = speakerLabel[segment.speakerId] ?? segment.speakerId
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            guard end > start else { continue }

            if let currentLabel,
               currentLabel == label,
               start - currentEnd <= mergeGapSeconds,
               end - currentStart <= maxTurnDurationSeconds
            {
                currentEnd = max(currentEnd, end)
            } else {
                flushCurrent()
                currentLabel = label
                currentStart = start
                currentEnd = end
            }
        }
        flushCurrent()

        return turns
    }

    private func formatClock(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, secs)
    }
}
