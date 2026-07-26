import FluidAudio
import Foundation

extension AudioProcessor {

    /// Transcribe audio samples using Parakeet v3 ASR model
    func transcribeAudio(samples: [Float]) async throws -> String {
        try await transcribeAudioResult(samples: samples).text
    }

    /// Transcribe audio samples and preserve FluidAudio's token-level timestamps.
    func transcribeAudioResult(
        samples: [Float],
        vocabularyFile: String? = nil
    ) async throws -> ASRResult {
        do {
            let asrManager = try await cachedAsrManager()
            var result = try await transcribeAudioResult(samples: samples, asrManager: asrManager)
            vocabularyReplacements = []
            if let vocabularyFile {
                result = try await applyVocabularyBoosting(
                    to: result,
                    samples: samples,
                    vocabularyFile: vocabularyFile
                )
            }
            return result

        } catch {
            verboseLog("❌ Transcription failed: \(error.localizedDescription)")
            throw ProcessingError.transcriptionFailed(error)
        }
    }

    func transcribeAudio(samples: [Float], asrManager: AsrManager) async throws -> String {
        try await transcribeAudioResult(samples: samples, asrManager: asrManager).text
    }

    func transcribeAudioResult(samples: [Float], asrManager: AsrManager) async throws -> ASRResult {
        verboseLog("🗣️ Transcribing \(Double(samples.count) / 16000.0) seconds of audio...")
        var decoderState = TdtDecoderState.make()
        let result = try await asrManager.transcribe(samples, decoderState: &decoderState)

        verboseLog("✅ Transcription completed")
        verboseLog("📊 Confidence: \(String(format: "%.1f%%", result.confidence * 100))")
        verboseLog("⏱️ Processing time: \(String(format: "%.2fs", result.processingTime))")

        return result
    }

    private func applyVocabularyBoosting(
        to result: ASRResult,
        samples: [Float],
        vocabularyFile: String
    ) async throws -> ASRResult {
        guard let tokenTimings = result.tokenTimings, !tokenTimings.isEmpty else {
            return result
        }

        verboseLog("📚 Applying custom vocabulary...")
        let (vocabulary, ctcModels) = try await CustomVocabularyContext.loadWithCtcTokens(
            from: vocabularyFile
        )
        guard !vocabulary.terms.isEmpty else { return result }

        let spotter = CtcKeywordSpotter(
            models: ctcModels,
            blankId: ctcModels.vocabulary.count
        )
        let spotResult = try await spotter.spotKeywordsWithLogProbs(
            audioSamples: samples,
            customVocabulary: vocabulary,
            minScore: nil
        )
        guard !spotResult.logProbs.isEmpty else { return result }

        let modelDirectory = CtcModels.defaultCacheDirectory(for: ctcModels.variant)
        let rescorer = try await VocabularyRescorer.create(
            spotter: spotter,
            vocabulary: vocabulary,
            ctcModelDirectory: modelDirectory
        )
        let config = ContextBiasingConstants.rescorerConfig(
            forVocabSize: vocabulary.terms.count
        )
        let output = rescorer.ctcTokenRescore(
            transcript: result.text,
            tokenTimings: tokenTimings,
            logProbs: spotResult.logProbs,
            frameDuration: spotResult.frameDuration,
            cbw: config.cbw,
            marginSeconds: ContextBiasingConstants.defaultMarginSeconds,
            minSimilarity: max(config.minSimilarity, vocabulary.minSimilarity)
        )
        vocabularyReplacements = output.replacements.compactMap { replacement in
            guard replacement.shouldReplace, let replacementWord = replacement.replacementWord else {
                return nil
            }
            return (from: replacement.originalWord, to: replacementWord)
        }
        let aliases = try RecognitionVocabulary(
            contentsOf: URL(fileURLWithPath: vocabularyFile)
        )
        let text = aliases.applyingAliases(to: output.text)
        verboseLog("📚 Applied \(vocabularyReplacements.count) vocabulary replacement(s)")
        return ASRResult(
            text: text,
            confidence: result.confidence,
            duration: result.duration,
            processingTime: result.processingTime,
            tokenTimings: result.tokenTimings
        )
    }
}
