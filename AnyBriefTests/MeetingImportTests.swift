import AVFoundation
import XCTest
@testable import AnyBrief

final class MeetingImportTests: XCTestCase {
    func testAudioAndVideoImportProduceOneTrackAndKeepOriginal() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let audio = root.appendingPathComponent("Диктофон встреча.m4a")
        let wav = root.appendingPathComponent("tone.wav")
        try makeWAV(at: wav)
        try run(URL(fileURLWithPath: "/usr/bin/afconvert"), ["-f", "m4af", "-d", "aac", wav.path, audio.path])
        let video = root.appendingPathComponent("Видео встречи.mov")
        try await makeVideo(at: video, audio: audio)
        let storage = StorageService(rootDirectoryOverride: root)
        let importer = MeetingImportService(storage: storage)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        var ids = Set<String>()
        for file in [audio, video] {
            let original = try Data(contentsOf: file)
            let session = try await importer.prepare(file: file, title: "  Встреча / тест  ", date: date)
            XCTAssertTrue(ids.insert(session.jobId).inserted)
            XCTAssertEqual(session.source, RecordingSession.fileImportSource)
            XCTAssertEqual(session.startedAt, date)
            XCTAssertEqual(session.title, "Встреча / тест")
            XCTAssertFalse(session.hasMicrophoneTrack)
            XCTAssertFalse(FileManager.default.fileExists(atPath: session.paths.micWavURL.path))
            let wav = try AVAudioFile(forReading: session.paths.systemWavURL)
            XCTAssertEqual(wav.processingFormat.channelCount, 1)
            XCTAssertEqual(wav.processingFormat.sampleRate, 16_000)
            XCTAssertGreaterThan(wav.length, 13_000)
            XCTAssertEqual(try Data(contentsOf: file), original)
            XCTAssertTrue(MeetingMetadataStore.isImported(in: session.paths.folderURL))
            XCTAssertEqual(MeetingMetadataStore.title(in: session.paths.folderURL), session.title)
        }
    }

    func testInvalidAndVideoWithoutAudioLeaveNoMeeting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("broken.mp3")
        try Data("not media".utf8).write(to: invalid)
        let video = root.appendingPathComponent("silent.mov")
        try await makeVideo(at: video)
        let storage = StorageService(rootDirectoryOverride: root)
        let importer = MeetingImportService(storage: storage)
        for file in [invalid, video] {
            do {
                _ = try await importer.prepare(file: file, title: "Broken", date: Date())
                XCTFail("Import must reject a file without decodable audio")
            } catch { XCTAssertFalse(error.localizedDescription.isEmpty) }
        }
        XCTAssertTrue(meetingDirectories(in: storage.meetingsDirectoryURL).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: invalid.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: video.path))
    }

    func testCancellationRemovesIncompleteMeeting() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("input.wav")
        try Data("fixture".utf8).write(to: file)
        let storage = StorageService(rootDirectoryOverride: root)
        let importer = MeetingImportService(storage: storage, prepareAudio: { _, _, _ in
            try await Task.sleep(for: .seconds(30))
        })
        let task = Task { try await importer.prepare(file: file, title: "Cancelled", date: Date()) }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(meetingDirectories(in: storage.meetingsDirectoryURL).isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), Data("fixture".utf8))
    }

    func testImportedMeetingRunsPipelineExportsAndCanBeReprocessed() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meeting.wav")
        try makeWAV(at: file)
        let original = try Data(contentsOf: file)
        let storage = StorageService(rootDirectoryOverride: root)
        let session = try await MeetingImportService(storage: storage).prepare(file: file, title: "Import test", date: Date())
        var settings = AppSettings.default
        settings.transcription.providers = [.fluidAudioSTT()]
        settings.summary.enabled = true
        settings.prompts.transcriptCleanup.enabled = true
        settings.llm.connections = [SummarizationServiceTests.openAIConfiguration(model: "import-test", apiKeyRef: "key")]
        let export = root.appendingPathComponent("exports")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        settings.postProcessing = PostProcessingSettings(enabled: true, rules: [PostProcessingRuleConfiguration(
            title: "Import export", calendarTitlePattern: "Import", destinationFolderPath: export.path,
            exportContent: .both, filenameTemplate: "{type}.md"
        )])
        let jobs = InMemoryJobRepository()
        let log = LoggingService(logsDirectoryURL: root.appendingPathComponent("logs"))
        let summary = SummarizationService(keychainStore: MockKeychainStore(values: ["key": "test"]), session: SummarizationServiceTests.mockSession { request in
            let body = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant",
                "content": String(repeating: "Processed meeting with decisions and next steps. ", count: 15)]]]])
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, body)
        })
        let pipeline = PipelineOrchestrator(
            jobRepository: jobs, appSettingsStore: FixedAppSettingsStore(settings: settings),
            transcriptionService: TranscriptionService(providerRegistry: TranscriptionProviderRegistry(modules: [ImportTestModule()])),
            transcriptMergeService: TranscriptMergeService(), summarizationService: summary,
            finalizationService: FinalizationService(storageService: storage, jobRepository: jobs, loggingService: log, appStateDidChange: { _ in }),
            loggingService: log, appStateDidChange: { _ in }
        )
        await pipeline.run(session: session)
        let job = await jobs.get(id: session.jobId)
        XCTAssertEqual(job?.status, "completed", job?.error?.message ?? "")
        let finalPaths = try XCTUnwrap(storage.findMeetingPaths(jobId: session.jobId, createdAt: session.startedAt))
        let content = MeetingReaderFiles.documents(in: finalPaths.folderURL)
        XCTAssertFalse(content.summary.isEmpty)
        XCTAssertTrue(content.transcript.contains("Processed meeting")) // cleanup ran through LLM
        XCTAssertTrue(content.isImported)
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("summary.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.appendingPathComponent("transcript.md").path))
        let playback = try MeetingReaderFiles.audio(in: finalPaths.folderURL, scratch: root.appendingPathComponent("playback"))
        XCTAssertEqual(playback.map(\.lastPathComponent), ["system_audio.mp3"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalPaths.tmpURL.path))
        try await pipeline.repeatProcessing(meetingFolderURL: finalPaths.folderURL, jobId: session.jobId, title: session.title, mode: .transcription)
        let repeatedJob = await jobs.get(id: session.jobId)
        XCTAssertEqual(repeatedJob?.status, "completed")
        XCTAssertEqual(try Data(contentsOf: file), original)
    }

    func testMicrophoneExclusionPersistsAndKeepsAudioAcrossReprocessing() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(rootDirectoryOverride: root)
        let startedAt = Date()
        let paths = try storage.createMeetingFolder(jobId: "exclude-mic", startedAt: startedAt)
        try makeWAV(at: paths.systemWavURL)
        try makeWAV(at: paths.micWavURL)
        let session = RecordingSession(jobId: "exclude-mic", pid: 0, paths: paths, startedAt: startedAt,
            source: "manual", title: "Test", autoStopDisabled: false)
        XCTAssertTrue(session.shouldTranscribeMicrophone)
        try MeetingMetadataStore.setSkipsMicrophone(true, in: paths.folderURL)
        XCTAssertFalse(session.shouldTranscribeMicrophone)
        XCTAssertTrue(session.hasMicrophoneTrack)
        var settings = AppSettings.default
        settings.summary.enabled = false
        settings.prompts.transcriptCleanup.enabled = false
        let jobs = InMemoryJobRepository()
        let log = LoggingService(logsDirectoryURL: root.appendingPathComponent("logs"))
        let pipeline = PipelineOrchestrator(jobRepository: jobs, appSettingsStore: FixedAppSettingsStore(settings: settings),
            transcriptionService: TranscriptionService(providerRegistry: TranscriptionProviderRegistry(modules: [ImportTestModule(allowsMicrophone: true)])),
            transcriptMergeService: TranscriptMergeService(), summarizationService: SummarizationService(),
            finalizationService: FinalizationService(storageService: storage, jobRepository: jobs, loggingService: log, appStateDidChange: { _ in }),
            loggingService: log, appStateDidChange: { _ in })
        let recoveredMic = try await pipeline.loadTranscription(.mic, for: session)
        XCTAssertTrue(recoveredMic.isEmpty)
        await pipeline.run(session: session)
        let job = await jobs.get(id: session.jobId)
        XCTAssertEqual(job?.status, "completed", job?.error?.message ?? "")
        let finalPaths = try XCTUnwrap(storage.findMeetingPaths(jobId: session.jobId, createdAt: startedAt))
        let folder = finalPaths.folderURL
        XCTAssertTrue(MeetingMetadataStore.skipsMicrophone(in: folder))
        let before = try MeetingReaderFiles.audio(in: folder, scratch: root.appendingPathComponent("before"))
        XCTAssertEqual(before.count, 2)
        let micBefore = try Data(contentsOf: XCTUnwrap(before.first { $0.lastPathComponent == "microphone_audio.mp3" }))
        try await pipeline.repeatProcessing(meetingFolderURL: folder, jobId: session.jobId, title: "Test", mode: .transcription)
        let excluded = try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: folder.appendingPathComponent("transcript_merged.json")))
        XCTAssertFalse(excluded.isEmpty)
        XCTAssertTrue(excluded.allSatisfy { $0.sourceTrack == .system })
        let after = try MeetingReaderFiles.audio(in: folder, scratch: root.appendingPathComponent("after"))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(after.first { $0.lastPathComponent == "microphone_audio.mp3" })), micBefore)
        try MeetingMetadataStore.setSkipsMicrophone(false, in: folder)
        XCTAssertFalse(MeetingMetadataStore.skipsMicrophone(in: folder))
        try await pipeline.repeatProcessing(meetingFolderURL: folder, jobId: session.jobId, title: "Test", mode: .transcription)
        let included = try JSONDecoder().decode([TranscriptSegment].self, from: Data(contentsOf: folder.appendingPathComponent("transcript_merged.json")))
        XCTAssertEqual(Set(included.map(\.sourceTrack)), [.system, .mic])
    }

    func testRetryOfUnpackagedImportPreservesPlayableAudio() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("retry.wav")
        try makeWAV(at: source)
        let storage = StorageService(rootDirectoryOverride: root)
        let session = try await MeetingImportService(storage: storage).prepare(file: source, title: "Retry import", date: Date())
        let jobs = InMemoryJobRepository()
        await jobs.upsert(Job(id: session.jobId, meetingId: session.jobId, status: "failed", stage: .transcribingSystem,
                             source: "recovery", createdAt: session.startedAt, updatedAt: Date()))
        var settings = AppSettings.default
        settings.transcription.providers = [.fluidAudioSTT()]
        let log = LoggingService(logsDirectoryURL: root.appendingPathComponent("logs"))
        let pipeline = PipelineOrchestrator(jobRepository: jobs, appSettingsStore: FixedAppSettingsStore(settings: settings),
            transcriptionService: TranscriptionService(providerRegistry: TranscriptionProviderRegistry(modules: [ImportTestModule()])),
            transcriptMergeService: TranscriptMergeService(), summarizationService: SummarizationService(),
            finalizationService: FinalizationService(storageService: storage, jobRepository: jobs, loggingService: log, appStateDidChange: { _ in }),
            loggingService: log, appStateDidChange: { _ in })
        try await pipeline.repeatProcessing(meetingFolderURL: session.paths.folderURL, jobId: session.jobId, title: session.title, mode: .transcription)
        let job = await jobs.get(id: session.jobId)
        XCTAssertEqual(job?.status, "completed")
        let paths = try XCTUnwrap(storage.findMeetingPaths(jobId: session.jobId, createdAt: session.startedAt))
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.tmpURL.path))
        let audio = try MeetingReaderFiles.audio(in: paths.folderURL, scratch: root.appendingPathComponent("playback"))
        XCTAssertEqual(audio.count, 1)
        XCTAssertGreaterThan(try AVAudioPlayer(contentsOf: XCTUnwrap(audio.first)).duration, 0)
    }

    func testRecoveryAcceptsImportedSingleTrack() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = StorageService(rootDirectoryOverride: root)
        let date = Date()
        let paths = try storage.createMeetingFolder(jobId: "import-recovery", startedAt: date)
        try Data("wav".utf8).write(to: paths.systemWavURL)
        let jobs = InMemoryJobRepository()
        await jobs.upsert(Job(id: "import-recovery", meetingId: "import-recovery", status: "processing", stage: .recorded,
                             source: RecordingSession.fileImportSource, createdAt: date, updatedAt: date))
        let resumed = expectation(description: "Single-track import is recoverable")
        let recovery = StartupRecoveryService(jobRepository: jobs, storageService: storage, loggingService: LoggingService()) { session, stage in
            XCTAssertFalse(session.hasMicrophoneTrack)
            XCTAssertEqual(stage, .recorded)
            resumed.fulfill()
        }
        await recovery.recoverJobs()
        await fulfillment(of: [resumed], timeout: 1)
    }

    private func makeWAV(at url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for frame in 0..<44_100 {
                buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.05) * 0.1
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func makeVideo(at url: URL, audio: URL? = nil) async throws {
        let silent = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: silent, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
                                                                         AVVideoWidthKey: 32, AVVideoHeightKey: 32])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 32, kCVPixelBufferHeightKey as String: 32
        ])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 32, kCVPixelFormatType_32ARGB, nil, &pixel), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixel)
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        guard let audio else { try FileManager.default.moveItem(at: silent, to: url); return }
        let composition = AVMutableComposition()
        for (source, type) in [(silent, AVMediaType.video), (audio, AVMediaType.audio)] {
            let asset = AVURLAsset(url: source)
            let tracks = try await asset.loadTracks(withMediaType: type)
            let track = try XCTUnwrap(tracks.first)
            let target = try XCTUnwrap(composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid))
            try target.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 0.9, preferredTimescale: 600)), of: track, at: .zero)
        }
        let exporter = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality))
        exporter.outputURL = url
        exporter.outputFileType = .mov
        await exporter.export()
        XCTAssertEqual(exporter.status, .completed)
        try FileManager.default.removeItem(at: silent)
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anybrief-import-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func meetingDirectories(in root: URL) -> [URL] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }.filter { $0.lastPathComponent.hasSuffix("_inprogress") }
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}

private struct ImportTestModule: TranscriptionProviderModule {
    var allowsMicrophone = false
    let id: TranscriptionProviderID = .fluidAudioSTT
    let title = "Import fixture"
    let systemImage = "waveform"
    func defaultConfiguration() -> TranscriptionProviderConfiguration { .fluidAudioSTT() }
    func makeProvider(context: TranscriptionRuntimeContext) -> any TranscriptionProvider { ImportTestProvider(allowsMicrophone: allowsMicrophone) }
    func makeDiagnostics(context: TranscriptionDiagnosticsContext) -> any TranscriptionDiagnostics { ImportTestDiagnostics() }
}

private struct ImportTestProvider: TranscriptionProvider {
    var allowsMicrophone = false
    let id: TranscriptionProviderID = .fluidAudioSTT
    func transcribe(input: TranscriptionInput) async throws -> TranscriptionResult {
        if !allowsMicrophone { XCTAssertEqual(input.sourceTrack, .system, "An import must never be transcribed twice") }
        let text = Array(repeating: "Meeting decisions tasks", count: 15).joined(separator: " ")
        return TranscriptionResult(segments: [TranscriptSegment(startTime: 0, endTime: 2, speaker: "Speaker 1", text: text, sourceTrack: input.sourceTrack)],
                                   outputDir: input.outputDir, combinedTxtURL: input.outputDir.appendingPathComponent("system_combined.txt"))
    }
}

private struct ImportTestDiagnostics: TranscriptionDiagnostics {
    func diagnose(configuration: TranscriptionProviderConfiguration, settings: AppSettings) async -> TranscriptionDiagnosticResult {
        TranscriptionDiagnosticResult(status: .success, message: "OK")
    }
}
