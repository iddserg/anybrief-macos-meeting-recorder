import AVFoundation
import Foundation

/// Finalizes the meeting folder and persistent state after summary generation succeeds or falls back.
actor FinalizationService {
    private let storageService: StorageServiceProtocol
    private let jobRepository: JobRepositoryProtocol
    private let loggingService: LoggingService
    private let appStateDidChange: @Sendable (AppState) async -> Void
    private let audioConversionService: AudioConversionService
    private let bundlePackagingService: BundlePackagingService
    private let fileManager: FileManager
    private let durationResolver: @Sendable (RecordingSession) async throws -> TimeInterval

    init(
        storageService: StorageServiceProtocol,
        jobRepository: JobRepositoryProtocol,
        loggingService: LoggingService,
        appStateDidChange: @escaping @Sendable (AppState) async -> Void,
        fileManager: FileManager = .default,
        audioConversionService: AudioConversionService? = nil,
        bundlePackagingService: BundlePackagingService? = nil,
        ffmpegURLResolver: @escaping () throws -> URL = CLIPathResolver.resolveFfmpeg,
        zipURLResolver: @escaping () throws -> URL = { URL(fileURLWithPath: "/usr/bin/zip", isDirectory: false) },
        durationResolver: (@Sendable (RecordingSession) async throws -> TimeInterval)? = nil
    ) {
        self.storageService = storageService
        self.jobRepository = jobRepository
        self.loggingService = loggingService
        self.appStateDidChange = appStateDidChange
        self.fileManager = fileManager
        self.audioConversionService = audioConversionService ?? AudioConversionService(
            fileManager: fileManager,
            ffmpegURLResolver: ffmpegURLResolver
        )
        self.bundlePackagingService = bundlePackagingService ?? BundlePackagingService(
            fileManager: fileManager,
            zipURLResolver: zipURLResolver
        )
        self.durationResolver = durationResolver ?? { session in
            try await FinalizationService.resolveDuration(session: session)
        }
    }

    func finalize(session: RecordingSession, summary: String, startingAt stage: JobStage = .convertingAudio) async throws {
        _ = summary

        let duration = try await durationResolver(session)
        let systemMP3URL = session.paths.folderURL.appendingPathComponent("system_audio.mp3", isDirectory: false)
        let micMP3URL = session.paths.folderURL.appendingPathComponent("microphone_audio.mp3", isDirectory: false)
        let bundleURL = session.paths.folderURL.appendingPathComponent("bundle.zip", isDirectory: false)

        switch stage {
        case .convertingAudio:
            try audioConversionService.convertToMP3(inputURL: session.paths.systemWavURL, outputURL: systemMP3URL)
            try audioConversionService.convertToMP3(inputURL: session.paths.micWavURL, outputURL: micMP3URL)
            await jobRepository.upsert(await packagingJob(from: session))
            fallthrough
        case .packaging:
            try bundlePackagingService.createBundleZip(in: session.paths.folderURL, bundleURL: bundleURL)
        default:
            throw TranscriptionError(message: "Unsupported finalization stage \(stage.rawValue).")
        }

        // Keep only summary.md, transcript.txt, bundle.zip in the folder.
        // Audio and JSON are already inside bundle.zip.
        for url in [systemMP3URL, micMP3URL,
                    session.paths.folderURL.appendingPathComponent("transcript_merged.json")] {
            try? fileManager.removeItem(at: url)
        }

        let finalFolderURL = try storageService.renameMeetingFolder(from: session.paths, duration: duration)
        let finalTmpURL = finalFolderURL.appendingPathComponent("tmp", isDirectory: true)
        if fileManager.fileExists(atPath: finalTmpURL.path) {
            try fileManager.removeItem(at: finalTmpURL)
        }

        let completedJob = await updatedJob(from: session, completedAt: Date())
        await jobRepository.upsert(completedJob)
        await loggingService.log(
            "Finalization completed for job \(session.jobId) at \(finalFolderURL.path)",
            level: .info,
            component: "Pipeline"
        )
        await appStateDidChange(.idle)
    }

    private func updatedJob(from session: RecordingSession, completedAt: Date) async -> Job {
        let now = Date()
        if let existingJob = await jobRepository.get(id: session.jobId) {
            return Job(
                id: existingJob.id,
                meetingId: existingJob.meetingId,
                status: "completed",
                stage: .completed,
                progressPercent: 100,
                source: existingJob.source,
                createdAt: existingJob.createdAt,
                updatedAt: now,
                completedAt: completedAt,
                retryCount: existingJob.retryCount,
                warnings: Self.mergedWarnings(existingJob.warnings, session.recordingWarnings)
            )
        }

        return Job(
            id: session.jobId,
            meetingId: session.jobId,
            status: "completed",
            stage: .completed,
            progressPercent: 100,
            source: session.source,
            createdAt: session.startedAt,
            updatedAt: now,
            completedAt: completedAt,
            warnings: session.recordingWarnings
        )
    }

    private func packagingJob(from session: RecordingSession) async -> Job {
        let now = Date()
        if let existingJob = await jobRepository.get(id: session.jobId) {
            return Job(
                id: existingJob.id,
                meetingId: existingJob.meetingId,
                status: "processing",
                stage: .packaging,
                progressPercent: JobProgress.percent(for: .packaging, status: "processing"),
                source: existingJob.source,
                createdAt: existingJob.createdAt,
                updatedAt: now,
                completedAt: existingJob.completedAt,
                retryCount: existingJob.retryCount,
                error: existingJob.error,
                warnings: Self.mergedWarnings(existingJob.warnings, session.recordingWarnings)
            )
        }

        return Job(
            id: session.jobId,
            meetingId: session.jobId,
            status: "processing",
            stage: .packaging,
            progressPercent: JobProgress.percent(for: .packaging, status: "processing"),
            source: session.source,
            createdAt: session.startedAt,
            updatedAt: now,
            warnings: session.recordingWarnings
        )
    }

    private static func mergedWarnings(_ existing: [String], _ incoming: [String]) -> [String] {
        var merged = existing
        for warning in incoming where !merged.contains(warning) {
            merged.append(warning)
        }
        return merged
    }

    private static func resolveDuration(session: RecordingSession) async throws -> TimeInterval {
        if let systemDuration = try? await audioDuration(for: session.paths.systemWavURL), systemDuration > 0 {
            return systemDuration
        }
        if let micDuration = try? await audioDuration(for: session.paths.micWavURL), micDuration > 0 {
            return micDuration
        }

        return max(0, Date().timeIntervalSince(session.startedAt))
    }

    private static func audioDuration(for url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else {
            throw RecordingOutputInvalidError(message: "Unable to determine duration for \(url.path).")
        }
        return seconds
    }
}

enum PipelineProcessRunner {
    static func run(_ process: Process, errorContext: String) throws {
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TranscriptionError(message: "\(errorContext) with status \(process.terminationStatus).")
        }
    }
}
