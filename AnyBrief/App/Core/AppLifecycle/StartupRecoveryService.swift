import Foundation

/// Reconciles persisted jobs with on-disk artifacts during app startup.
actor StartupRecoveryService {
    private let jobRepository: JobRepositoryProtocol
    private let storageService: StorageServiceProtocol
    private let loggingService: LoggingService
    private let fileManager: FileManager
    private let notifyInterruptedRecording: @Sendable (String) async -> Void
    private let resumeJob: @Sendable (RecordingSession, JobStage) async -> Void

    init(
        jobRepository: JobRepositoryProtocol,
        storageService: StorageServiceProtocol,
        loggingService: LoggingService,
        fileManager: FileManager = .default,
        notifyInterruptedRecording: @escaping @Sendable (String) async -> Void = { _ in },
        resumeJob: @escaping @Sendable (RecordingSession, JobStage) async -> Void
    ) {
        self.jobRepository = jobRepository
        self.storageService = storageService
        self.loggingService = loggingService
        self.fileManager = fileManager
        self.notifyInterruptedRecording = notifyInterruptedRecording
        self.resumeJob = resumeJob
    }

    func recoverJobs() async {
        let jobs = await jobRepository.load().sorted { $0.createdAt < $1.createdAt }
        var interruptedRecordingCount = 0

        for job in jobs {
            do {
                if job.isTerminal {
                    if !shouldPreserveTemporaryArtifacts(for: job) {
                        try cleanupTemporaryArtifacts(for: job)
                    }
                    continue
                }

                if job.stage == .recording {
                    let failedJob = interruptedJob(from: job)
                    await jobRepository.upsert(failedJob)
                    await loggingService.log(
                        "Marked interrupted recording job \(job.id) as failed during startup recovery; preserving raw recording artifacts.",
                        level: .warn,
                        component: "Recovery"
                    )
                    interruptedRecordingCount += 1
                    continue
                }

                guard let session = try recoverySession(for: job) else {
                    await markMissingArtifacts(job: job)
                    continue
                }

                guard requiredInputsExist(for: job.stage, session: session) else {
                    await markMissingArtifacts(job: job)
                    continue
                }

                await loggingService.log(
                    "Resuming job \(job.id) from stage \(job.stage.rawValue).",
                    level: .info,
                    component: "Recovery"
                )
                await resumeJob(session, job.stage)
            } catch {
                await markFailed(job: job, stage: job.stage, code: "recovery_failed", message: error.localizedDescription)
            }
        }

        interruptedRecordingCount += await recoverOrphanedInProgressFolders(knownJobs: jobs)
        await notifyInterruptedRecordingsIfNeeded(count: interruptedRecordingCount)
    }

    private func notifyInterruptedRecordingsIfNeeded(count: Int) async {
        guard count > 0 else {
            return
        }

        let body: String
        if count == 1 {
            body = String(localized: "Recovery found 1 interrupted recording.")
        } else {
            body = String(
                format: String(localized: "Recovery found %d interrupted recordings."),
                count
            )
        }

        await notifyInterruptedRecording(body)
    }

    private func recoverySession(for job: Job) throws -> RecordingSession? {
        guard let paths = try storageService.findMeetingPaths(jobId: job.id, createdAt: job.createdAt) else {
            return nil
        }
        let metadata = Self.autopilotMetadata(in: paths.folderURL)

        return RecordingSession(
            jobId: job.id,
            pid: 0,
            paths: paths,
            startedAt: job.createdAt,
            source: job.source,
            title: job.meetingId,
            autoStopDisabled: false,
            recordingWarnings: job.warnings,
            systemSpeakersOverride: metadata?.systemSpeakersOverride,
            calendarEventUID: metadata?.calendarEventUID
        )
    }

    private static func autopilotMetadata(in folderURL: URL) -> AutopilotRecordingMetadata? {
        let metadataURL = folderURL.appendingPathComponent(".anybrief-autopilot.json", isDirectory: false)
        guard let data = try? Data(contentsOf: metadataURL) else {
            return nil
        }
        return try? JSONDecoder().decode(AutopilotRecordingMetadata.self, from: data)
    }

    private func requiredInputsExist(for stage: JobStage, session: RecordingSession) -> Bool {
        let fileManager = FileManager.default
        let paths = session.paths
        let systemCombinedURL = FluidAudioSTTProvider.combinedTxtURL(
            for: paths.systemWavURL,
            outputDir: FluidAudioSTTProvider.outputDir(for: paths, track: .system)
        )
        let micCombinedURL = FluidAudioSTTProvider.combinedTxtURL(
            for: paths.micWavURL,
            outputDir: FluidAudioSTTProvider.outputDir(for: paths, track: .mic)
        )
        let transcriptURL = paths.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        let mergedJSONURL = paths.folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        let summaryURL = paths.folderURL.appendingPathComponent("summary.md", isDirectory: false)
        let systemMP3URL = paths.folderURL.appendingPathComponent("system_audio.mp3", isDirectory: false)
        let micMP3URL = paths.folderURL.appendingPathComponent("microphone_audio.mp3", isDirectory: false)

        let requiredURLs: [URL]
        switch stage {
        case .recorded, .transcribingSystem:
            requiredURLs = [paths.systemWavURL, paths.micWavURL]
        case .transcribingMic:
            requiredURLs = [paths.micWavURL, systemCombinedURL]
        case .mergingTranscripts:
            requiredURLs = [systemCombinedURL, micCombinedURL]
        case .processingTranscript:
            requiredURLs = [transcriptURL, mergedJSONURL]
        case .summarizing:
            requiredURLs = [transcriptURL, mergedJSONURL]
        case .convertingAudio:
            requiredURLs = [paths.systemWavURL, paths.micWavURL, transcriptURL, mergedJSONURL, summaryURL]
        case .packaging:
            requiredURLs = [systemMP3URL, micMP3URL, transcriptURL, mergedJSONURL, summaryURL]
        case .recording, .completed, .partialSuccess, .cancelled:
            return false
        }

        return requiredURLs.allSatisfy { fileManager.fileExists(atPath: $0.path) }
    }

    private func cleanupTemporaryArtifacts(for job: Job) throws {
        guard let paths = try storageService.findMeetingPaths(jobId: job.id, createdAt: job.createdAt) else {
            return
        }

        try storageService.cleanupTemporaryArtifacts(for: paths)
    }

    private func recoverOrphanedInProgressFolders(knownJobs: [Job]) async -> Int {
        let knownMeetingKeys = Set(knownJobs.flatMap { Self.knownInProgressFolderKeys(for: $0) })
        var interruptedRecordingCount = 0

        do {
            let folders = try inProgressMeetingFolders()
            for folderURL in folders where Self.isUnknownInProgressFolder(folderURL, knownKeys: knownMeetingKeys) {
                let createdAt = Self.createdAt(from: folderURL) ?? Date()
                let now = Date()
                let jobId = "orphan-\(folderURL.lastPathComponent)"
                let job = Job(
                    id: jobId,
                    meetingId: folderURL.lastPathComponent,
                    status: "failed",
                    stage: .recording,
                    source: "recovery",
                    createdAt: createdAt,
                    updatedAt: now,
                    completedAt: now,
                    error: Job.ErrorState(
                        code: "recording_interrupted",
                        message: "Recording folder was left in progress without an active job.",
                        stage: JobStage.recording.rawValue,
                        retryable: false
                    )
                )

                await jobRepository.upsert(job)
                await loggingService.log(
                    "Marked orphaned in-progress meeting folder \(folderURL.lastPathComponent) as failed during startup recovery; preserving raw recording artifacts.",
                    level: .warn,
                    component: "Recovery"
                )
                interruptedRecordingCount += 1
            }
        } catch {
            await loggingService.log(
                "Failed to scan orphaned in-progress meeting folders: \(error.localizedDescription)",
                level: .warn,
                component: "Recovery"
            )
        }

        return interruptedRecordingCount
    }

    private func inProgressMeetingFolders() throws -> [URL] {
        guard fileManager.fileExists(atPath: storageService.meetingsDirectoryURL.path) else {
            return []
        }

        let dayFolders = try fileManager.contentsOfDirectory(
            at: storageService.meetingsDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        return try dayFolders.flatMap { dayURL -> [URL] in
            guard Self.isDirectory(dayURL) else { return [] }
            return try fileManager.contentsOfDirectory(
                at: dayURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.contains("_inprogress") && Self.isDirectory($0) }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private static func folderPrefix(for folderURL: URL) -> String {
        folderPrefix(forName: folderURL.lastPathComponent)
    }

    private static func folderPrefix(forName name: String) -> String {
        name.replacingOccurrences(of: "_inprogress", with: "")
    }

    private static func inProgressFolderPrefix(for date: Date) -> String {
        inProgressFolderDateFormatter.string(from: date)
    }

    private static func knownInProgressFolderKeys(for job: Job) -> [String] {
        let timestampPrefix = inProgressFolderPrefix(for: job.createdAt)
        var keys = [
            timestampPrefix,
            "\(timestampPrefix)_\(job.id)",
            "\(timestampPrefix)_\(job.id)_inprogress",
        ]

        let meetingId = job.meetingId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !meetingId.isEmpty {
            keys.append(meetingId)
            keys.append(folderPrefix(forName: meetingId))
            if !meetingId.hasSuffix("_inprogress") {
                keys.append("\(meetingId)_inprogress")
            }
            keys.append("\(timestampPrefix)_\(meetingId)")
            keys.append("\(timestampPrefix)_\(meetingId)_inprogress")
        }

        if job.id.hasPrefix("orphan-") {
            let folderName = String(job.id.dropFirst("orphan-".count))
            keys.append(folderName)
            keys.append(folderPrefix(forName: folderName))
        }

        return keys
    }

    private static func isUnknownInProgressFolder(_ folderURL: URL, knownKeys: Set<String>) -> Bool {
        let folderName = folderURL.lastPathComponent
        let prefix = folderPrefix(forName: folderName)
        return !knownKeys.contains(folderName) && !knownKeys.contains(prefix)
    }

    private static func createdAt(from folderURL: URL) -> Date? {
        let prefix = folderPrefix(for: folderURL)
        let dateToken = String(prefix.prefix(16))
        return inProgressFolderDateFormatter.date(from: dateToken)
    }

    private static let inProgressFolderDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm"
        return formatter
    }()

    private func interruptedJob(from job: Job) -> Job {
        let now = Date()
        return Job(
            id: job.id,
            meetingId: job.meetingId,
            status: "failed",
            stage: .recording,
            source: job.source,
            createdAt: job.createdAt,
            updatedAt: now,
            completedAt: now,
            retryCount: job.retryCount,
            error: Job.ErrorState(
                code: "recording_interrupted",
                message: "Recording was interrupted",
                stage: JobStage.recording.rawValue,
                retryable: false
            ),
            warnings: job.warnings
        )
    }

    private func markMissingArtifacts(job: Job) async {
        await markFailed(
            job: job,
            stage: job.stage,
            code: "artifacts_missing",
            message: "Recovery input files are missing."
        )
    }

    private func markFailed(job: Job, stage: JobStage, code: String, message: String) async {
        let now = Date()
        let failedJob = Job(
            id: job.id,
            meetingId: job.meetingId,
            status: "failed",
            stage: stage,
            source: job.source,
            createdAt: job.createdAt,
            updatedAt: now,
            completedAt: now,
            retryCount: job.retryCount,
            error: Job.ErrorState(
                code: code,
                message: message,
                stage: stage.rawValue,
                retryable: false
            ),
            warnings: job.warnings
        )
        await jobRepository.upsert(failedJob)
        await loggingService.log(
            "Startup recovery failed job \(job.id) at stage \(stage.rawValue): \(message)",
            level: .warn,
            component: "Recovery"
        )
        if !shouldPreserveTemporaryArtifacts(for: failedJob) {
            try? cleanupTemporaryArtifacts(for: failedJob)
        }
    }

    private func shouldPreserveTemporaryArtifacts(for job: Job) -> Bool {
        job.status == "failed" && job.stage == .recording
    }
}
