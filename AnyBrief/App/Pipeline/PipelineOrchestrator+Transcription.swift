import Foundation

extension PipelineOrchestrator {
    func repeatProcessing(
        meetingFolderURL: URL,
        jobId requestedJobId: String?,
        title: String,
        mode: MeetingReprocessingMode
    ) async throws {
        let jobId = try resolvedReprocessingJobID(
            requestedJobId,
            meetingFolderURL: meetingFolderURL
        )
        guard manuallyReprocessingJobIDs.insert(jobId).inserted else {
            throw TranscriptionError(message: String(localized: "Meeting processing is already running."))
        }
        defer {
            manuallyReprocessingJobIDs.remove(jobId)
            activityDetails[jobId] = nil
        }

        let scratchURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "anybrief-reprocess-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: scratchURL)
        }

        let existingJob = await jobRepository.get(id: jobId)
        let startedAt = existingJob?.createdAt ?? Date()
        let source = existingJob?.source ?? "manual"

        do {
            try FileManager.default.createDirectory(
                at: scratchURL,
                withIntermediateDirectories: true
            )
            let audio = try reprocessingAudioURLs(
                meetingFolderURL: meetingFolderURL,
                scratchURL: scratchURL
            )
            let session = RecordingSession(
                jobId: jobId,
                pid: 0,
                paths: MeetingPaths(
                    folderURL: meetingFolderURL,
                    tmpURL: scratchURL.appendingPathComponent("output", isDirectory: true),
                    systemWavURL: audio.system,
                    micWavURL: audio.microphone,
                    jobLogURL: scratchURL.appendingPathComponent("reprocessing.log", isDirectory: false)
                ),
                startedAt: startedAt,
                source: source,
                title: title,
                autoStopDisabled: false,
                recordingWarnings: existingJob?.warnings ?? []
            )

            await appStateDidChange(.processing)
            await loggingService.log(
                "Manual meeting reprocessing started for \(meetingFolderURL.lastPathComponent): mode=\(mode.logValue)",
                level: .info,
                component: "Pipeline"
            )

            let systemSegments = try await transcribe(.system, for: session)
            let micSegments = try await transcribe(.mic, for: session)
            let segments = try await merge(system: systemSegments, mic: micSegments, for: session)
            try await cleanupTranscriptIfNeeded(for: session)

            if mode == .all {
                switch await summarize(segments: segments, for: session, forceEnabled: true) {
                case .ready:
                    await notifyUser(
                        NotificationService.Category.summaryReady.rawValue,
                        "AnyBrief",
                        String(localized: "Your brief is ready")
                    )
                case .skipped:
                    break
                case .fallback:
                    return
                }
            }

            await refreshReprocessedBundle(in: meetingFolderURL)
            await markReprocessingCompleted(session)
            await loggingService.log(
                "Manual meeting reprocessing completed for \(meetingFolderURL.lastPathComponent): mode=\(mode.logValue)",
                level: .info,
                component: "Pipeline"
            )
            await appStateDidChange(.idle)
        } catch {
            let stage = await jobRepository.get(id: jobId)?.stage ?? .transcribingSystem
            let fallbackPaths = MeetingPaths(
                folderURL: meetingFolderURL,
                tmpURL: scratchURL,
                systemWavURL: scratchURL.appendingPathComponent("system_audio.mp3"),
                micWavURL: scratchURL.appendingPathComponent("microphone_audio.mp3"),
                jobLogURL: scratchURL.appendingPathComponent("reprocessing.log")
            )
            let session = RecordingSession(
                jobId: jobId,
                pid: 0,
                paths: fallbackPaths,
                startedAt: startedAt,
                source: source,
                title: title,
                autoStopDisabled: false,
                recordingWarnings: existingJob?.warnings ?? []
            )
            await fail(session, error: error, stage: stage)
            throw error
        }
    }

    func transcribe(_ track: TranscriptionTrack, for session: RecordingSession) async throws -> [TranscriptSegment] {
        let stage: JobStage = track == .system ? .transcribingSystem : .transcribingMic
        await upsertJob(from: session, status: "processing", stage: stage)
        await loggingService.log(
            "Starting \(stage.rawValue) for job \(session.jobId)",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog("--- \(stage.rawValue) ---\n", at: session.paths.jobLogURL)

        let settings = await effectiveSettings(for: session)
        let wavURL = track == .system ? session.paths.systemWavURL : session.paths.micWavURL
        let outputDir = transcriptionOutputDir(for: session, track: track)
        let wavSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int) ?? 0
        let wavDuration = (try? await Self.audioDuration(for: wavURL))
            .map { String(format: "%.1fs", $0) } ?? "unknown"
        let providerDetails = transcriptionProviderDetails(settings: settings)
        await loggingService.log(
            "\(stage.rawValue) input: \(wavURL.path) [\(wavSize / 1024)KB, duration=\(wavDuration)], \(providerDetails)",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog(
            "Input: \(wavURL.path) [\(wavSize / 1024)KB, duration=\(wavDuration)], \(providerDetails)\n",
            at: session.paths.jobLogURL
        )
        let result = try await transcriptionService.transcribe(
            input: TranscriptionInput(
                wavURL: wavURL,
                outputDir: outputDir,
                sourceTrack: track.sourceTrack,
                settings: settings,
                logURL: session.paths.jobLogURL
            )
        )
        await loggingService.log(
            "\(stage.rawValue) completed for job \(session.jobId): \(result.segments.count) segments",
            level: .info,
            component: "Pipeline"
        )
        Self.appendToJobLog(
            "Segments: \(result.segments.count)\n",
            at: session.paths.jobLogURL
        )
        return result.segments
    }

    func loadTranscription(_ track: TranscriptionTrack, for session: RecordingSession) throws -> [TranscriptSegment] {
        let wavURL = track == .system ? session.paths.systemWavURL : session.paths.micWavURL
        let outputDir = transcriptionOutputDir(for: session, track: track)
        let combinedTxtURL = transcriptionCombinedTxtURL(for: wavURL, outputDir: outputDir)
        let sourceTrack = track == .system ? SourceTrack.system : SourceTrack.mic
        return try parser.parse(fileURL: combinedTxtURL, sourceTrack: sourceTrack)
    }

    func transcriptionOutputDir(for session: RecordingSession, track: TranscriptionTrack) -> URL {
        session.paths.tmpURL.appendingPathComponent(track.outputDirectoryName, isDirectory: true)
    }

    func transcriptionCombinedTxtURL(for wavURL: URL, outputDir: URL) -> URL {
        outputDir.appendingPathComponent(
            "\(wavURL.deletingPathExtension().lastPathComponent)_combined.txt",
            isDirectory: false
        )
    }

    func loadMergedSegments(for session: RecordingSession) throws -> [TranscriptSegment] {
        let url = session.paths.folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    private func resolvedReprocessingJobID(
        _ requestedJobId: String?,
        meetingFolderURL: URL
    ) throws -> String {
        if let requestedJobId, !requestedJobId.isEmpty {
            return requestedJobId
        }
        let markerURL = meetingFolderURL.appendingPathComponent(".anybrief-job-id", isDirectory: false)
        if let stored = try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty {
            return stored
        }
        throw TranscriptionError(message: String(localized: "Meeting job information is missing."))
    }

    private func reprocessingAudioURLs(
        meetingFolderURL: URL,
        scratchURL: URL
    ) throws -> (system: URL, microphone: URL) {
        let candidates = [
            meetingFolderURL,
            meetingFolderURL.appendingPathComponent("bundle", isDirectory: true),
        ]
        for directory in candidates {
            let systemURL = directory.appendingPathComponent("system_audio.mp3", isDirectory: false)
            let microphoneURL = directory.appendingPathComponent("microphone_audio.mp3", isDirectory: false)
            if FileManager.default.fileExists(atPath: systemURL.path),
               FileManager.default.fileExists(atPath: microphoneURL.path) {
                return try normalizeReprocessingAudio(
                    systemURL: systemURL,
                    microphoneURL: microphoneURL,
                    scratchURL: scratchURL
                )
            }
        }

        let bundleURL = meetingFolderURL.appendingPathComponent("bundle.zip", isDirectory: false)
        guard FileManager.default.fileExists(atPath: bundleURL.path) else {
            throw TranscriptionError(message: String(localized: "Meeting audio files are missing."))
        }

        let inputURL = scratchURL.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: inputURL, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip", isDirectory: false)
        process.arguments = [
            "-qq", "-j", bundleURL.path,
            "system_audio.mp3", "microphone_audio.mp3",
            "-d", inputURL.path,
        ]
        try PipelineProcessRunner.run(
            process,
            errorContext: "unzip failed reading \(bundleURL.lastPathComponent)"
        )

        let systemURL = inputURL.appendingPathComponent("system_audio.mp3", isDirectory: false)
        let microphoneURL = inputURL.appendingPathComponent("microphone_audio.mp3", isDirectory: false)
        guard FileManager.default.fileExists(atPath: systemURL.path),
              FileManager.default.fileExists(atPath: microphoneURL.path) else {
            throw TranscriptionError(message: String(localized: "Meeting audio files are missing."))
        }
        return try normalizeReprocessingAudio(
            systemURL: systemURL,
            microphoneURL: microphoneURL,
            scratchURL: scratchURL
        )
    }

    private func normalizeReprocessingAudio(
        systemURL: URL,
        microphoneURL: URL,
        scratchURL: URL
    ) throws -> (system: URL, microphone: URL) {
        let normalizedURL = scratchURL.appendingPathComponent("normalized", isDirectory: true)
        let systemWAVURL = normalizedURL.appendingPathComponent("system_audio.wav", isDirectory: false)
        let microphoneWAVURL = normalizedURL.appendingPathComponent(
            "microphone_audio.wav",
            isDirectory: false
        )
        try audioConversionService.convertToTranscriptionWAV(
            inputURL: systemURL,
            outputURL: systemWAVURL
        )
        try audioConversionService.convertToTranscriptionWAV(
            inputURL: microphoneURL,
            outputURL: microphoneWAVURL
        )
        return (systemWAVURL, microphoneWAVURL)
    }

    private func transcriptionProviderDetails(settings: AppSettings) -> String {
        switch settings.transcription.activeProviderConfiguration.provider {
        case .fluidAudioSTT:
            return "provider=\(TranscriptionProviderID.fluidAudioSTT.rawValue), model=nvidia-parakeet-tdt-0.6b-v3, language=multilingual-auto"
        case .whisperCpp:
            let config = settings.transcription.whisperCppConfig
            return "provider=\(TranscriptionProviderID.whisperCpp.rawValue), model=\(config.model), language=\(config.language)"
        }
    }

    private func markReprocessingCompleted(_ session: RecordingSession) async {
        let now = Date()
        let existingJob = await jobRepository.get(id: session.jobId)
        await jobRepository.upsert(Job(
            id: session.jobId,
            meetingId: existingJob?.meetingId ?? session.title,
            status: "completed",
            stage: .completed,
            progressPercent: 100,
            source: existingJob?.source ?? session.source,
            createdAt: existingJob?.createdAt ?? session.startedAt,
            updatedAt: now,
            completedAt: now,
            retryCount: existingJob?.retryCount ?? 0,
            error: nil,
            warnings: existingJob?.warnings ?? session.recordingWarnings
        ))
    }

    private func refreshReprocessedBundle(in meetingFolderURL: URL) async {
        let artifactNames = [
            "transcript.txt",
            "transcript_merged.json",
            "summary.md",
        ]
        let artifactURLs = artifactNames
            .map { meetingFolderURL.appendingPathComponent($0, isDirectory: false) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        do {
            let extractedBundleURL = meetingFolderURL.appendingPathComponent("bundle", isDirectory: true)
            if (try? extractedBundleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                for sourceURL in artifactURLs {
                    let destinationURL = extractedBundleURL.appendingPathComponent(
                        sourceURL.lastPathComponent,
                        isDirectory: false
                    )
                    if FileManager.default.fileExists(atPath: destinationURL.path) {
                        try FileManager.default.removeItem(at: destinationURL)
                    }
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                }
            }

            let bundleURL = meetingFolderURL.appendingPathComponent("bundle.zip", isDirectory: false)
            if FileManager.default.fileExists(atPath: bundleURL.path), !artifactURLs.isEmpty {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/zip", isDirectory: false)
                process.arguments = ["-q", "-j", bundleURL.path] + artifactURLs.map(\.path)
                try PipelineProcessRunner.run(
                    process,
                    errorContext: "zip failed updating \(bundleURL.lastPathComponent)"
                )
            }
        } catch {
            await loggingService.log(
                "Could not refresh meeting bundle after reprocessing: \(error.localizedDescription)",
                level: .warn,
                component: "Pipeline"
            )
        }
    }
}

private extension MeetingReprocessingMode {
    var logValue: String {
        switch self {
        case .transcription: return "transcription"
        case .all: return "all"
        }
    }
}
