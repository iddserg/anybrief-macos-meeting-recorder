import AVFoundation
import Foundation

extension PipelineOrchestrator {
    static let minimumTranscriptWordsForAutomaticSummary = 30

    func summarize(
        segments: [TranscriptSegment],
        for session: RecordingSession,
        forceEnabled: Bool = false
    ) async -> SummaryOutcome {
        let settings = await effectiveSettings(for: session)
        guard settings.summary.enabled || forceEnabled else {
            await loggingService.log(
                "Automatic summary skipped for job \(session.jobId): summary is disabled.",
                level: .info,
                component: "Pipeline"
            )
            Self.appendToJobLog("ℹ️ Summary skipped: automatic summary is disabled.\n", at: session.paths.jobLogURL)
            return .skipped
        }
        let transcriptWordCount = Self.transcriptWordCount(in: segments)
        guard transcriptWordCount >= Self.minimumTranscriptWordsForAutomaticSummary else {
            await loggingService.log(
                "Automatic summary skipped for job \(session.jobId): transcript_word_count=\(transcriptWordCount), minimum_words=\(Self.minimumTranscriptWordsForAutomaticSummary).",
                level: .warn,
                component: "Pipeline"
            )
            Self.appendToJobLog(
                "ℹ️ Summary skipped: transcript has only \(transcriptWordCount) words; minimum is \(Self.minimumTranscriptWordsForAutomaticSummary).\n",
                at: session.paths.jobLogURL
            )
            return .skipped
        }
        await upsertJob(from: session, status: "summarizing", stage: .summarizing)
        await loggingService.log(
            "Starting summarization for job \(session.jobId)",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog("--- summarizing ---\n", at: session.paths.jobLogURL)
        activityDetails[session.jobId] = PipelineActivityDetail(
            phase: .summarization,
            connectionName: nil,
            connectionIndex: nil,
            connectionCount: settings.summaryLLMChain.count,
            fallbackFrom: nil
        )
        let transcriptURL = session.paths.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        let transcript = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let durationMinutes = Self.durationMinutes(from: segments)
        let speakerCount = Set(segments.map(\.speaker)).count
        let completedAt = Date()
        let metadata = await summaryMetadata(settings: settings, session: session, segments: segments)
        let summaryInput = await summarizationService.summarizationInput(transcript: transcript, metadata: metadata)

        do {
            let startedAt = Date()
            let summaryResult = try await summarizationService.summarizeWithMetadata(
                transcript: summaryInput,
                settings: settings,
                meetingTitle: session.title,
                workingDirectory: session.paths.folderURL,
                transcriptURL: transcriptURL,
                progress: { [weak self] event in
                    await self?.updateLLMActivity(
                        for: session.jobId,
                        phase: .summarization,
                        event: event
                    )
                }
            )
            let elapsed = Date().timeIntervalSince(startedAt)
            try await summarizationService.writeSummary(
                summaryResult.summary,
                to: session.paths.folderURL,
                date: completedAt,
                durationMinutes: durationMinutes,
                speakers: speakerCount,
                model: summaryResult.provider.model,
                provider: summaryResult.provider,
                metadata: metadata,
                includeFooter: !settings.application.disableSummaryFooter
            )
            await runPostProcessingExport(
                for: session,
                settings: settings,
                calendarEvent: metadata.calendar
            )
            await loggingService.log(
                "Summary completed for job \(session.jobId): provider=\(summaryResult.provider.type.rawValue), model=\(summaryResult.provider.model), transcript_chars=\(transcript.count), summary_input_chars=\(summaryInput.count), metadata_calendar=\(metadata.calendar == nil ? "missing" : "present"), summary_chars=\(summaryResult.summary.count), elapsed_sec=\(String(format: "%.1f", elapsed))",
                level: .info,
                component: "Pipeline"
            )
            Self.appendToJobLog("✅ Summary: \(session.paths.folderURL.path)/summary.md\n", at: session.paths.jobLogURL)
            Self.appendToJobLog(
                "Summary stats: provider=\(summaryResult.provider.type.rawValue), model=\(summaryResult.provider.model), transcript_chars=\(transcript.count), summary_input_chars=\(summaryInput.count), metadata_calendar=\(metadata.calendar == nil ? "missing" : "present"), summary_chars=\(summaryResult.summary.count), elapsed_sec=\(String(format: "%.1f", elapsed))\n",
                at: session.paths.jobLogURL
            )
            return .ready(summaryResult.summary)
        } catch {
            let summaryDiagnostics = [
                error.localizedDescription,
                "connections=\(settings.summaryLLMChain.map { "\($0.provider.rawValue)(timeout_sec=\($0.effectiveTimeoutSec),attempts=\($0.effectiveRetryCount))" }.joined(separator: ","))",
            ].joined(separator: ", ")
            let fallbackSummary = """
            ## Summary
            Черновик - summary недоступен

            ## Transcript
            \(transcript)
            """
            try? await summarizationService.writeSummary(
                fallbackSummary,
                to: session.paths.folderURL,
                date: completedAt,
                durationMinutes: durationMinutes,
                speakers: speakerCount,
                model: "",
                metadata: metadata,
                status: "partial_success",
                summaryError: "summary_api_failed",
                includeFooter: !settings.application.disableSummaryFooter
            )
            let partialJob = await updatedJob(
                from: session,
                status: "partial_success",
                stage: .partialSuccess,
                completedAt: completedAt,
                errorState: Job.ErrorState(
                    code: "summary_api_failed",
                    message: summaryDiagnostics,
                    stage: "summarizing",
                    retryable: false
                )
            )
            await jobRepository.upsert(partialJob)
            await loggingService.log(
                "Summary fallback created for job \(session.jobId): \(summaryDiagnostics)",
                level: .warn,
                component: "Pipeline"
            )
            Self.appendToJobLog("WARN: Summary unavailable: \(summaryDiagnostics)\n", at: session.paths.jobLogURL)
            await notifyUser(
                NotificationService.Category.summaryReady.rawValue,
                "AnyBrief",
                String(localized: "Your brief is ready")
            )
            await appStateDidChange(.idle)
            return .fallback
        }
    }

    func runPostProcessingExport(
        for session: RecordingSession,
        settings: AppSettings,
        calendarEvent: CalendarEvent?
    ) async {
        let result = await postProcessingService.exportSummaryIfNeeded(
            from: session.paths.folderURL,
            settings: settings.postProcessing,
            calendarEvent: calendarEvent
        )
        switch result.status {
        case .exported:
            if let destination = result.destinationURL {
                Self.appendToJobLog("✅ Summary export: \(destination.path)\n", at: session.paths.jobLogURL)
            }
        case .failed:
            Self.appendToJobLog("WARN: Summary export failed: \(result.message)\n", at: session.paths.jobLogURL)
        case .skipped:
            break
        }
    }

    static func durationMinutes(from segments: [TranscriptSegment]) -> Int {
        guard let duration = segments.map(\.endTime).max(), duration > 0 else {
            return 0
        }

        return Int((duration / 60).rounded(.up))
    }

    func summaryMetadata(
        settings: AppSettings,
        session: RecordingSession,
        segments: [TranscriptSegment]
    ) async -> SummaryMetadata {
        let provider = settings.transcription.activeProviderConfiguration.provider
        let transcriptionConfig: FluidAudioSTTConfig
        let transcriptionModel: String
        let transcriptionLanguage: String?
        let transcriptionAcceleration: String?
        switch provider {
        case .fluidAudioSTT:
            transcriptionConfig = settings.transcription.fluidAudioSTTConfig
            transcriptionModel = "nvidia-parakeet-tdt-0.6b-v3"
            transcriptionLanguage = nil
            transcriptionAcceleration = "core_ml"
        case .whisperCpp:
            let whisperConfig = settings.transcription.whisperCppConfig
            transcriptionConfig = FluidAudioSTTConfig(
                speakersMode: whisperConfig.speakersMode,
                speakersCount: whisperConfig.speakersCount,
                threshold: whisperConfig.threshold
            )
            transcriptionModel = whisperConfig.model
            transcriptionLanguage = whisperConfig.language
            transcriptionAcceleration = whisperConfig.useGPU ? "metal" : "cpu"
        }
        return SummaryMetadata(
            transcription: SummaryTranscriptionMetadata(
                provider: provider.rawValue,
                model: transcriptionModel,
                language: transcriptionLanguage,
                acceleration: transcriptionAcceleration,
                diarizationEnabled: settings.transcription.diarizationEnabled,
                speakersMode: transcriptionConfig.speakersMode,
                speakersCount: transcriptionConfig.speakersCount,
                systemSpeakers: settings.transcription.diarizationEnabled
                    ? {
                        switch transcriptionConfig.speakersMode {
                        case "fixed":
                            return String(transcriptionConfig.speakersCount)
                        case "max":
                            return "max:\(transcriptionConfig.speakersCount)"
                        default:
                            return "auto"
                        }
                    }()
                    : "disabled",
                microphoneSpeakers: settings.transcription.diarizationEnabled ? 1 : 0,
                threshold: transcriptionConfig.threshold
            ),
            audio: SummaryAudioMetadata(
                system: await audioTrackMetadata(
                    url: session.paths.systemWavURL,
                    segments: segments.filter { $0.sourceTrack == .system }
                ),
                microphone: await audioTrackMetadata(
                    url: session.paths.micWavURL,
                    segments: segments.filter { $0.sourceTrack == .mic }
                )
            ),
            calendar: storedAutopilotMetadata(for: session)?.calendarEvent,
            warnings: session.recordingWarnings
        )
    }

    func effectiveSettings(for session: RecordingSession) async -> AppSettings {
        var settings = await appSettingsStore.load(using: loggingService)
        if let override = session.systemSpeakersOverride ?? storedSystemSpeakersOverride(for: session) {
            switch settings.transcription.activeProviderConfiguration.provider {
            case .fluidAudioSTT:
                var config = settings.transcription.fluidAudioSTTConfig
                config.speakersMode = "max"
                config.speakersCount = max(1, min(10, override))
                settings.transcription.fluidAudioSTTConfig = config
            case .whisperCpp:
                var config = settings.transcription.whisperCppConfig
                config.speakersMode = "max"
                config.speakersCount = max(1, min(10, override))
                settings.transcription.whisperCppConfig = config
            }
        }
        return settings
    }

    func storedSystemSpeakersOverride(for session: RecordingSession) -> Int? {
        storedAutopilotMetadata(for: session)?.systemSpeakersOverride
    }

    func storedAutopilotMetadata(for session: RecordingSession) -> AutopilotRecordingMetadata? {
        let metadataURL = session.paths.folderURL.appendingPathComponent(".anybrief-autopilot.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL),
              let metadata = try? JSONDecoder().decode(AutopilotRecordingMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    func audioTrackMetadata(url: URL, segments: [TranscriptSegment]) async -> SummaryAudioTrackMetadata {
        let sizeBytes = Self.fileSize(at: url)
        let durationSeconds = (try? await Self.audioDuration(for: url)) ?? 0
        let status: String
        if sizeBytes == 0 {
            status = "missing"
        } else if durationSeconds <= 0 {
            status = "invalid"
        } else if segments.isEmpty {
            status = "recorded_no_speech"
        } else {
            status = "recorded"
        }

        return SummaryAudioTrackMetadata(
            status: status,
            durationSeconds: durationSeconds,
            sizeBytes: sizeBytes,
            segments: segments.count,
            speakers: Set(segments.map(\.speaker)).count
        )
    }

    func sessionByAddingTranscriptQualityWarnings(
        _ session: RecordingSession,
        segments: [TranscriptSegment]
    ) async -> RecordingSession {
        let warnings = await transcriptQualityWarnings(for: session, segments: segments)
        guard !warnings.isEmpty else {
            return session
        }

        let updatedSession = session.withRecordingWarnings(warnings)
        let job = await updatedJob(from: updatedSession, status: "processing", stage: .mergingTranscripts)
        await jobRepository.upsert(job)
        for warning in warnings {
            await loggingService.log(
                "Transcript quality warning for job \(session.jobId): \(warning)",
                level: .warn,
                component: "Pipeline"
            )
            Self.appendToJobLog("WARN: \(warning)\n", at: session.paths.jobLogURL)
        }
        return updatedSession
    }

    func transcriptQualityWarnings(
        for session: RecordingSession,
        segments: [TranscriptSegment]
    ) async -> [String] {
        let duration = (try? await Self.audioDuration(for: session.paths.systemWavURL)) ?? 0
        guard duration >= 10 * 60 else {
            return []
        }

        let wordCount = Self.transcriptWordCount(in: segments)
        let wordsPerMinute = Double(wordCount) / max(1, duration / 60)
        guard wordCount < Int((duration / 60) * 25), wordsPerMinute < 25 else {
            return []
        }

        return [
            "transcript_suspiciously_short: \(formatDurationMinutes(duration)) of audio produced only \(wordCount) words (\(String(format: "%.1f", wordsPerMinute)) wpm). System audio capture or transcription may be degraded; verify the audio before trusting the summary."
        ]
    }

    static func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }

    static func audioDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw RecordingOutputInvalidError(message: "Unable to determine duration for \(url.path).")
        }
        return seconds
    }

    static func wordCount(in text: String) -> Int {
        text.split { $0.isWhitespace || $0.isPunctuation }.count
    }

    static func transcriptWordCount(in segments: [TranscriptSegment]) -> Int {
        segments.reduce(0) { total, segment in
            total + wordCount(in: segment.text)
        }
    }

    private func formatDurationMinutes(_ duration: TimeInterval) -> String {
        "\(Int((duration / 60).rounded()))m"
    }
}
