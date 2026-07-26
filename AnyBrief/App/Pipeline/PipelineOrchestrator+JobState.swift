import Foundation

extension PipelineOrchestrator {
    func finalize(_ session: RecordingSession, summary: String, startingAt stage: JobStage) async throws {
        guard stage == .convertingAudio || stage == .packaging else {
            throw TranscriptionError(message: "Unsupported finalization stage \(stage.rawValue).")
        }

        await upsertJob(from: session, status: "processing", stage: stage)
        await loggingService.log(
            "Starting \(stage.rawValue) for job \(session.jobId)",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog("--- \(stage.rawValue) ---\n", at: session.paths.jobLogURL)
        try await finalizationService.finalize(session: session, summary: summary, startingAt: stage)
    }

    func fail(_ session: RecordingSession, error: Error, stage: JobStage) async {
        if await markPartialSuccessIfPossible(session, error: error, stage: stage) {
            return
        }

        let failedJob = await updatedJob(
            from: session,
            status: "failed",
            stage: stage,
            errorState: errorState(from: error, stage: stage)
        )
        await jobRepository.upsert(failedJob)
        let message = "Pipeline failed at \(stage.rawValue) for job \(session.jobId): \(error.localizedDescription)"
        await loggingService.log(message, level: .error, component: "Pipeline")
        Self.appendToJobLog("ERROR: \(error.localizedDescription)\n", at: session.paths.jobLogURL)
        await appStateDidChange(.error)
    }

    func markPartialSuccessIfPossible(_ session: RecordingSession, error: Error, stage: JobStage) async -> Bool {
        guard stage == .convertingAudio || stage == .packaging else {
            return false
        }
        guard hasUsefulArtifacts(for: session, stage: stage) else {
            return false
        }

        let partialJob = await updatedJob(
            from: session,
            status: "partial_success",
            stage: .partialSuccess,
            completedAt: Date(),
            errorState: Job.ErrorState(
                code: "finalization_failed",
                message: error.localizedDescription,
                stage: stage.rawValue,
                retryable: false
            )
        )
        await jobRepository.upsert(partialJob)
        let message = "Pipeline finished with partial_success at \(stage.rawValue) for job \(session.jobId): \(error.localizedDescription)"
        await loggingService.log(message, level: .warn, component: "Pipeline")
        Self.appendToJobLog("WARN: partial_success at \(stage.rawValue): \(error.localizedDescription)\n", at: session.paths.jobLogURL)
        await notifyUser(
            NotificationService.Category.summaryReady.rawValue,
            "AnyBrief",
            String(localized: "Your brief is ready")
        )
        await appStateDidChange(.idle)
        return true
    }

    func hasUsefulArtifacts(for session: RecordingSession, stage: JobStage) -> Bool {
        let fileManager = FileManager.default
        let folderURL = session.paths.folderURL
        let summaryURL = folderURL.appendingPathComponent("summary.md", isDirectory: false)
        let transcriptURL = folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        let bundleURL = folderURL.appendingPathComponent("bundle.zip", isDirectory: false)
        let systemMP3URL = folderURL.appendingPathComponent("system_audio.mp3", isDirectory: false)
        let micMP3URL = folderURL.appendingPathComponent("microphone_audio.mp3", isDirectory: false)
        guard fileManager.fileExists(atPath: summaryURL.path) else {
            return false
        }
        if stage == .convertingAudio {
            return true
        }

        return fileManager.fileExists(atPath: transcriptURL.path) ||
            fileManager.fileExists(atPath: bundleURL.path) ||
            fileManager.fileExists(atPath: systemMP3URL.path) ||
            fileManager.fileExists(atPath: micMP3URL.path)
    }

    static func appendToJobLog(_ text: String, at url: URL) {
        guard let data = text.data(using: .utf8) else { return }

        do {
            let handle = try FileHandle(forWritingTo: url)
            defer {
                do {
                    try handle.close()
                } catch {
                    NSLog("AnyBrief failed to close job log at \(url.path): \(error.localizedDescription)")
                }
            }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            NSLog("AnyBrief failed to append job log at \(url.path): \(error.localizedDescription)")
        }
    }

    func currentStage(for session: RecordingSession) async -> JobStage {
        await jobRepository.get(id: session.jobId)?.stage ?? .recorded
    }

    func upsertJob(from session: RecordingSession, status: String, stage: JobStage) async {
        let job = await updatedJob(from: session, status: status, stage: stage)
        await jobRepository.upsert(job)
    }

    func updatedJob(
        from session: RecordingSession,
        status: String,
        stage: JobStage,
        completedAt: Date? = nil,
        errorState: Job.ErrorState? = nil
    ) async -> Job {
        let now = Date()
        if let existingJob = await jobRepository.get(id: session.jobId) {
            return Job(
                id: existingJob.id,
                meetingId: existingJob.meetingId,
                status: status,
                stage: stage,
                progressPercent: JobProgress.percent(for: stage, status: status),
                source: existingJob.source,
                createdAt: existingJob.createdAt,
                updatedAt: now,
                completedAt: completedAt ?? (status == "failed" ? now : existingJob.completedAt),
                retryCount: existingJob.retryCount,
                error: errorState,
                warnings: Self.mergedWarnings(existingJob.warnings, session.recordingWarnings)
            )
        }

        return Job(
            id: session.jobId,
            meetingId: session.jobId,
            status: status,
            stage: stage,
            progressPercent: JobProgress.percent(for: stage, status: status),
            source: session.source,
            createdAt: session.startedAt,
            updatedAt: now,
            completedAt: completedAt ?? (status == "failed" ? now : nil),
            error: errorState,
            warnings: session.recordingWarnings
        )
    }

    static func mergedWarnings(_ existing: [String], _ incoming: [String]) -> [String] {
        var merged = existing
        for warning in incoming where !merged.contains(warning) {
            merged.append(warning)
        }
        return merged
    }

    func errorState(from error: Error, stage: JobStage) -> Job.ErrorState {
        let code: String
        if error is TranscriptionError || error is TranscriptionTimeoutError {
            code = "transcription_failed"
        } else if stage == .mergingTranscripts {
            code = "merge_failed"
        } else if stage == .convertingAudio || stage == .packaging {
            code = "finalization_failed"
        } else {
            code = "pipeline_failed"
        }

        return Job.ErrorState(
            code: code,
            message: error.localizedDescription,
            stage: stage.rawValue,
            retryable: false
        )
    }

    func cleanupCancelledArtifacts(for session: RecordingSession) {
        let fileManager = FileManager.default
        let urls = [
            session.paths.tmpURL,
            session.paths.folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false),
            session.paths.folderURL.appendingPathComponent("transcript.txt", isDirectory: false),
            session.paths.folderURL.appendingPathComponent("summary.md", isDirectory: false),
            session.paths.folderURL.appendingPathComponent("system_audio.mp3", isDirectory: false),
            session.paths.folderURL.appendingPathComponent("microphone_audio.mp3", isDirectory: false),
            session.paths.folderURL.appendingPathComponent("bundle.zip", isDirectory: false),
        ]
        for url in urls where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }
}
