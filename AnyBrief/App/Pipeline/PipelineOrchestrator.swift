import Foundation

enum MeetingReprocessingMode: Sendable {
    case transcription
    case all
}

struct PipelineActivityDetail: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case transcriptCleanup
        case summarization
    }

    let phase: Phase
    let connectionName: String?
    let connectionIndex: Int?
    let connectionCount: Int?
    let fallbackFrom: String?
}

/// Runs the post-recording pipeline and persists job stage transitions.
actor PipelineOrchestrator {
    enum SummaryOutcome {
        case ready(String)
        case skipped
        case fallback
    }

    let jobRepository: JobRepositoryProtocol
    let appSettingsStore: AppSettingsStoreProtocol
    let transcriptionService: TranscriptionService
    let transcriptMergeService: TranscriptMergeService
    let summarizationService: SummarizationService
    let postProcessingService: PostProcessingService
    let finalizationService: FinalizationService
    let audioConversionService: AudioConversionService
    let loggingService: LoggingService
    let appStateDidChange: @Sendable (AppState) async -> Void
    let notifyUser: @Sendable (String, String, String) async -> Void
    let parser = CombinedTxtParser()
    private var activeSessions: [String: RecordingSession] = [:]
    private var activeTasks: [String: Task<Void, Never>] = [:]
    var manuallyReprocessingJobIDs: Set<String> = []
    var activityDetails: [String: PipelineActivityDetail] = [:]

    init(
        jobRepository: JobRepositoryProtocol,
        appSettingsStore: AppSettingsStoreProtocol,
        transcriptionService: TranscriptionService,
        transcriptMergeService: TranscriptMergeService,
        summarizationService: SummarizationService,
        postProcessingService: PostProcessingService? = nil,
        finalizationService: FinalizationService,
        audioConversionService: AudioConversionService = AudioConversionService(),
        loggingService: LoggingService,
        appStateDidChange: @escaping @Sendable (AppState) async -> Void,
        notifyUser: @escaping @Sendable (String, String, String) async -> Void = { _, _, _ in }
    ) {
        self.jobRepository = jobRepository
        self.appSettingsStore = appSettingsStore
        self.transcriptionService = transcriptionService
        self.transcriptMergeService = transcriptMergeService
        self.summarizationService = summarizationService
        self.postProcessingService = postProcessingService ?? PostProcessingService(logger: { message, level in
            await loggingService.log(message, level: level, component: "PostProcessing")
        })
        self.finalizationService = finalizationService
        self.audioConversionService = audioConversionService
        self.loggingService = loggingService
        self.appStateDidChange = appStateDidChange
        self.notifyUser = notifyUser
    }

    func enqueue(session: RecordingSession, startingAt stage: JobStage = .recorded) {
        activeTasks[session.jobId]?.cancel()
        activeSessions[session.jobId] = session
        activeTasks[session.jobId] = Task { [weak self] in
            await self?.run(session: session, startingAt: stage)
        }
    }

    func cancel(jobId: String) async -> Job? {
        guard let session = activeSessions[jobId] else {
            return nil
        }
        guard let job = await jobRepository.get(id: jobId), !job.isTerminal else {
            activeTasks[jobId]?.cancel()
            activeTasks[jobId] = nil
            activeSessions[jobId] = nil
            return nil
        }
        guard job.stage != .packaging, job.stage != .completed, job.stage != .partialSuccess else {
            return nil
        }

        activeTasks[jobId]?.cancel()
        activeTasks[jobId] = nil
        activeSessions[jobId] = nil
        cleanupCancelledArtifacts(for: session)

        let now = Date()
        let cancelledJob = Job(
            id: job.id,
            meetingId: job.meetingId,
            status: "cancelled",
            stage: .cancelled,
            progressPercent: JobProgress.percent(for: .cancelled, status: "cancelled"),
            source: job.source,
            createdAt: job.createdAt,
            updatedAt: now,
            completedAt: now,
            retryCount: job.retryCount
        )
        await jobRepository.upsert(cancelledJob)
        await loggingService.log(
            "Cancelled pipeline for job \(jobId) at stage \(job.stage.rawValue)",
            level: .info,
            component: "Pipeline"
        )
        await appStateDidChange(.idle)
        return cancelledJob
    }

    func run(session: RecordingSession, startingAt stage: JobStage = .recorded) async {
        defer {
            activeTasks[session.jobId] = nil
            activeSessions[session.jobId] = nil
            activityDetails[session.jobId] = nil
        }
        await appStateDidChange(.processing)
        await loggingService.log(
            "Pipeline started for job \(session.jobId) — startingAt=\(stage.rawValue) folder=\(session.paths.folderURL.path)",
            level: .info, component: "Pipeline"
        )

        do {
            var didCreateSummary = false
            switch stage {
            case .recorded, .transcribingSystem, .transcribingMic, .mergingTranscripts, .processingTranscript, .summarizing:
                let segments = try await transcriptSegments(for: session, resumingAt: stage)
                let checkedSession = await sessionByAddingTranscriptQualityWarnings(session, segments: segments)
                if stage != .summarizing {
                    try await cleanupTranscriptIfNeeded(for: checkedSession)
                }
                switch await summarize(segments: segments, for: checkedSession) {
                case let .ready(summary):
                    didCreateSummary = true
                    try await finalize(checkedSession, summary: summary, startingAt: .convertingAudio)
                case .skipped:
                    try await finalize(checkedSession, summary: "", startingAt: .convertingAudio)
                case .fallback:
                    return
                }
            case .convertingAudio, .packaging:
                try await finalize(session, summary: "", startingAt: stage)
            case .recording, .completed, .partialSuccess, .cancelled:
                throw TranscriptionError(message: "Unsupported recovery stage \(stage.rawValue).")
            }
            if didCreateSummary {
                await notifyUser(
                    NotificationService.Category.summaryReady.rawValue,
                    "AnyBrief",
                    String(localized: "Your brief is ready")
                )
            }
            try Task.checkCancellation()
        } catch {
            if error is CancellationError {
                return
            }
            let stage = await currentStage(for: session)
            await fail(session, error: error, stage: stage)
        }
    }

    func activityDetail(for jobId: String) -> PipelineActivityDetail? {
        activityDetails[jobId]
    }

    func updateLLMActivity(
        for jobId: String,
        phase: PipelineActivityDetail.Phase,
        event: LLMProgressEvent
    ) {
        activityDetails[jobId] = PipelineActivityDetail(
            phase: phase,
            connectionName: event.connectionName,
            connectionIndex: event.connectionIndex,
            connectionCount: event.connectionCount,
            fallbackFrom: event.fallbackFrom
        )
    }

    /// Produces merged transcript segments, re-running only the steps the
    /// resume stage still requires and loading earlier artifacts from disk.
    private func transcriptSegments(
        for session: RecordingSession,
        resumingAt stage: JobStage
    ) async throws -> [TranscriptSegment] {
        switch stage {
        case .recorded, .transcribingSystem:
            let systemSegments = try await transcribe(.system, for: session)
            let micSegments = try await transcribe(.mic, for: session)
            return try await merge(system: systemSegments, mic: micSegments, for: session)
        case .transcribingMic:
            let systemSegments = try loadTranscription(.system, for: session)
            let micSegments = try await transcribe(.mic, for: session)
            return try await merge(system: systemSegments, mic: micSegments, for: session)
        case .mergingTranscripts:
            let systemSegments = try loadTranscription(.system, for: session)
            let micSegments = try loadTranscription(.mic, for: session)
            return try await merge(system: systemSegments, mic: micSegments, for: session)
        case .processingTranscript, .summarizing:
            return try loadMergedSegments(for: session)
        case .recording, .convertingAudio, .packaging, .completed, .partialSuccess, .cancelled:
            throw TranscriptionError(message: "Unsupported recovery stage \(stage.rawValue).")
        }
    }
}
