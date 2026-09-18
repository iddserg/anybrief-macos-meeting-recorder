import Foundation

extension PipelineOrchestrator {
    /// Reads preserved transcript_raw.txt and writes the LLM result to
    /// transcript.txt for downstream consumers. Retries always use the raw
    /// recognition result. Failed or excessively shortened output falls back
    /// to the original transcript, including when retrying an older result.
    func cleanupTranscriptIfNeeded(for session: RecordingSession) async throws {
        let settings = await effectiveSettings(for: session)
        guard settings.prompts.transcriptCleanup.enabled else {
            return
        }

        let transcriptURL = session.paths.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        let rawURL = session.paths.folderURL.appendingPathComponent("transcript_raw.txt", isDirectory: false)
        let transcript = try await transcriptMergeService.rawTranscript(in: session.paths.folderURL)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        // Seed the output from the preserved input, not a previous LLM result.
        // All failure paths therefore leave usable original text downstream.
        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
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
                transcriptURL: rawURL,
                progress: { [weak self] event in
                    await self?.updateLLMActivity(
                        for: session.jobId,
                        phase: .transcriptCleanup,
                        event: event
                    )
                }
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let elapsed = Date().timeIntervalSince(startedAt)
            try Task.checkCancellation()
            // Compare transcript text only (without calendar metadata). Ignore
            // whitespace so formatting changes cannot hide substantial loss.
            let originalCount = transcript.filter { !$0.isWhitespace }.count
            let cleanedCount = cleaned.filter { !$0.isWhitespace }.count
            let retainedRatio = Double(cleanedCount) / Double(originalCount)
            guard cleanedCount > 0, retainedRatio >= 0.5 else {
                let message = "Transcript cleanup rejected for job \(session.jobId): output is too short "
                    + "(input_chars=\(originalCount), output_chars=\(cleanedCount), "
                    + "retained_percent=\(String(format: "%.1f", retainedRatio * 100)), minimum_percent=50). "
                    + "Keeping original transcript."
                await loggingService.log(
                    message,
                    level: .error,
                    component: "Pipeline"
                )
                Self.appendToJobLog("ERROR: \(message)\n", at: session.paths.jobLogURL)
                return
            }
            try Task.checkCancellation()
            try (cleaned + "\n").write(to: transcriptURL, atomically: true, encoding: .utf8)
            await loggingService.log(
                "Transcript cleanup completed for job \(session.jobId): elapsed_sec=\(String(format: "%.1f", elapsed))",
                level: .info,
                component: "Pipeline"
            )
            Self.appendToJobLog("✅ Transcript cleaned.\n", at: session.paths.jobLogURL)
        } catch {
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            await loggingService.log(
                "Transcript cleanup failed for job \(session.jobId): \(error.localizedDescription). Continuing with the original transcript.",
                level: .error,
                component: "Pipeline"
            )
            Self.appendToJobLog("ERROR: Transcript cleanup failed: \(error.localizedDescription). Keeping original transcript.\n", at: session.paths.jobLogURL)
        }
    }
}
