import FluidAudio
import Foundation

extension AudioProcessor {
    private struct DiarizationJSON: Encodable {
        struct Segment: Encodable {
            let start: Float
            let end: Float
            let speaker: String
            let quality: Float
        }

        let schemaVersion = 1
        let duration: Double
        let segments: [Segment]
    }

    /// Perform speaker diarization on 16 kHz mono Float32 samples.
    /// Returns the raw DiarizationResult so callers can use it directly without re-parsing text.
    func diarizeAudio(
        samples: [Float],
        threshold: Double,
        numClusters: Int = -1,
        maxClusters: Int = -1
    ) async throws -> DiarizationResult {
        let config = makeOfflineDiarizerConfig(
            threshold: threshold,
            numClusters: numClusters,
            maxClusters: maxClusters
        )
        let diarizer = OfflineDiarizerManager(config: config)

        verboseLog("👥 Initializing offline speaker diarization models...")
        try await diarizer.prepareModels()
        verboseLog("✅ Offline diarization models loaded")
        verboseLog(
            "✅ Offline diarizer initialised with threshold: \(threshold), exactSpeakers: \(numClusters), maxSpeakers: \(maxClusters)"
        )

        verboseLog("👥 Performing offline VBx speaker diarization...")
        var result = try await diarizer.process(audio: samples)
        if numClusters > 0,
           Set(result.segments.map(\.speakerId)).count != numClusters {
            verboseLog(
                "⚠️ Offline reconstruction did not preserve the requested speaker count; applying exact-count fallback"
            )
            result = SpeakerCountConstraint.apply(
                to: result,
                exactCount: numClusters
            )
        } else if maxClusters > 0,
                  Set(result.segments.map(\.speakerId)).count > maxClusters {
            verboseLog(
                "⚠️ Offline reconstruction exceeded the speaker limit; applying maximum-count fallback"
            )
            result = SpeakerCountConstraint.apply(
                to: result,
                exactCount: maxClusters
            )
        }
        result = normalizedSpeakerIDs(in: result)
        let uniqueSpeakers = Set(result.segments.map { $0.speakerId })
        verboseLog("🎯 Found \(uniqueSpeakers.count) speakers in \(result.segments.count) segments")
        return result
    }

    func prepareOfflineDiarizationModels() async throws {
        verboseLog("👥 Downloading and compiling offline speaker diarization models...")
        let diarizer = OfflineDiarizerManager()
        try await diarizer.prepareModels()
        verboseLog("✅ Offline diarization models loaded")
    }

    func makeOfflineDiarizerConfig(
        threshold: Double,
        numClusters: Int,
        maxClusters: Int = -1
    ) -> OfflineDiarizerConfig {
        // The existing CLI accepts 0.0. FluidAudio's offline validator requires
        // a strictly positive threshold, so retain CLI compatibility with a
        // practically-zero value.
        var config = OfflineDiarizerConfig(
            clusteringThreshold: max(threshold, 0.000_001),
            segmentationStepRatio: 0.1,
            minSegmentDuration: 0.0
        )
        config.zeroVoteReembed = .init(
            enabled: true,
            minDurationSeconds: 0.4
        )
        if numClusters > 0 {
            config = config.withSpeakers(exactly: numClusters)
        } else if maxClusters > 0 {
            config = config.withSpeakers(min: 1, max: maxClusters)
        }
        return config
    }

    private func normalizedSpeakerIDs(in result: DiarizationResult) -> DiarizationResult {
        var speakerIDs: [String] = []
        for segment in result.segments where !speakerIDs.contains(segment.speakerId) {
            speakerIDs.append(segment.speakerId)
        }
        let labels = Dictionary(
            uniqueKeysWithValues: speakerIDs.enumerated().map {
                ($0.element, String($0.offset + 1))
            }
        )
        let segments = result.segments.map { segment in
            TimedSpeakerSegment(
                speakerId: labels[segment.speakerId] ?? segment.speakerId,
                embedding: segment.embedding,
                startTimeSeconds: segment.startTimeSeconds,
                endTimeSeconds: segment.endTimeSeconds,
                qualityScore: segment.qualityScore
            )
        }
        return DiarizationResult(
            segments: segments,
            speakerDatabase: result.speakerDatabase,
            chunkEmbeddings: result.chunkEmbeddings,
            timings: result.timings
        )
    }

    /// Format DiarizationResult as a human-readable text file (written to disk for reference).
    func formatDiarizationText(_ result: DiarizationResult, audioDuration: Double? = nil) -> String {
        var output = "SPEAKER DIARIZATION RESULTS\n"
        output += "==========================\n\n"

        let audioDuration = audioDuration ?? result.segments.last.map { Double($0.endTimeSeconds) } ?? 0
        output += "Audio Duration: \(String(format: "%.1f", audioDuration)) seconds\n"

        let uniqueSpeakers = Set(result.segments.map { $0.speakerId })
        output += "Speaker Count: \(uniqueSpeakers.count)\n"
        output += "Segments: \(result.segments.count)\n"

        if let timings = result.timings {
            output += "Processing Time: \(String(format: "%.2f", timings.totalProcessingSeconds)) seconds\n"
            let rtf = audioDuration > 0 ? timings.totalInferenceSeconds / audioDuration : 0
            output += "Real-time Factor: \(String(format: "%.2fx", rtf))\n"
        }
        output += "\n"

        output += "SPEAKER SEGMENTS:\n"
        output += "-----------------\n"

        for segment in result.segments {
            let start = formatTimestamp(segment.startTimeSeconds)
            let end   = formatTimestamp(segment.endTimeSeconds)
            let dur   = segment.endTimeSeconds - segment.startTimeSeconds
            output += "Speaker \(segment.speakerId): \(start) - \(end) (\(String(format: "%.1f", dur))s)"
            if segment.qualityScore > 0 {
                output += " [Quality: \(String(format: "%.1f", segment.qualityScore * 100))%]"
            }
            output += "\n"
        }

        return output
    }

    func writeDiarizationJSON(
        _ result: DiarizationResult,
        audioDuration: Double,
        to url: URL
    ) throws {
        let document = DiarizationJSON(
            duration: audioDuration,
            segments: result.segments.map {
                DiarizationJSON.Segment(
                    start: $0.startTimeSeconds,
                    end: $0.endTimeSeconds,
                    speaker: $0.speakerId,
                    quality: $0.qualityScore
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    private func formatTimestamp(_ seconds: Float) -> String {
        let totalSeconds = Int(seconds)
        let minutes      = totalSeconds / 60
        let secs         = totalSeconds % 60
        let ms           = Int((seconds - Float(totalSeconds)) * 1000)
        return String(format: "%02d:%02d.%03d", minutes, secs, ms)
    }
}
