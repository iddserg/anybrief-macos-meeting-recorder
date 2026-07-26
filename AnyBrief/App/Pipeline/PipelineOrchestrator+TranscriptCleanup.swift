import Foundation

extension PipelineOrchestrator {
    /// Runs an optional LLM pass over transcript.txt between merging and
    /// summarization to fix recognition errors and fill in speaker names
    /// from calendar context. Overwrites transcript.txt in place so every
    /// downstream consumer (summarization, exports, the dashboard) sees the
    /// cleaned version. Failures are logged and non-fatal: the pipeline
    /// continues with the original transcript.
    func cleanupTranscriptIfNeeded(for session: RecordingSession) async throws {
        let settings = await effectiveSettings(for: session)
        guard settings.prompts.transcriptCleanup.enabled else {
            return
        }

        let transcriptURL = session.paths.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        guard settings.prompts.transcriptCleanupPrompt != nil else {
            await loggingService.log(
                "Transcript cleanup skipped for job \(session.jobId): no prompt configured.",
                level: .warn,
                component: "Pipeline"
            )
            return
        }
        let chain = settings.transcriptCleanupLLMChain
        guard !chain.isEmpty else {
            await loggingService.log(
                "Transcript cleanup skipped for job \(session.jobId): no enabled LLM connection.",
                level: .warn,
                component: "Pipeline"
            )
            Self.appendToJobLog("WARN: Transcript cleanup skipped: no enabled LLM connection.\n", at: session.paths.jobLogURL)
            return
        }

        try Task.checkCancellation()
        await upsertJob(from: session, status: "processing", stage: .processingTranscript)
        await loggingService.log(
            "Starting transcript cleanup for job \(session.jobId)",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog("--- processing_transcript ---\n", at: session.paths.jobLogURL)
        activityDetails[session.jobId] = PipelineActivityDetail(
            phase: .transcriptCleanup,
            connectionName: nil,
            connectionIndex: nil,
            connectionCount: chain.count,
            fallbackFrom: nil
        )

        let calendarEvent = storedAutopilotMetadata(for: session)?.calendarEvent
        let input = await summarizationService.transcriptCleanupInput(transcript: transcript, calendarEvent: calendarEvent)

        do {
            let startedAt = Date()
            let cleaned = try await summarizationService.cleanupTranscript(
                transcript: input,
                settings: settings,
                workingDirectory: session.paths.folderURL,
                transcriptURL: transcriptURL,
                progress: { [weak self] event in
                    await self?.updateLLMActivity(
                        for: session.jobId,
                        phase: .transcriptCleanup,
                        event: event
                    )
                }
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(startedAt)
            guard !cleaned.isEmpty else {
                await loggingService.log(
                    "Transcript cleanup returned empty output for job \(session.jobId); keeping original transcript.",
                    level: .warn,
                    component: "Pipeline"
                )
                return
            }
            try (cleaned + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
            await loggingService.log(
                "Transcript cleanup completed for job \(session.jobId): elapsed_sec=\(String(format: "%.1f", elapsed))",
                level: .info,
                component: "Pipeline"
            )
            Self.appendToJobLog("✅ Transcript cleaned.\n", at: session.paths.jobLogURL)
        } catch {
            await loggingService.log(
                "Transcript cleanup failed for job \(session.jobId): \(error.localizedDescription). Continuing with the original transcript.",
                level: .warn,
                component: "Pipeline"
            )
            Self.appendToJobLog("WARN: Transcript cleanup failed: \(error.localizedDescription)\n", at: session.paths.jobLogURL)
        }
    }
}
