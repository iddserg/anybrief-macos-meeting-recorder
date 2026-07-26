import Foundation

@MainActor
final class LiveTranscriptService {
    private let capture: LiveAudioCapturing
    private let sttRunner: LiveSTTRunning
    private let deduplicator: LiveTranscriptDeduplicator
    private let chunkDuration: TimeInterval
    private let updateIntervalNanoseconds: UInt64
    private let updateIntervalSeconds: TimeInterval
    private let maximumTranscriptCharacters: Int
    private let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?

    private var isVisible = false
    private var isUserEnabled = false
    private var runTask: Task<Void, Never>?
    private var activeRunID: UUID?
    private(set) var snapshot = LiveTranscriptSnapshot()

    var onSnapshotChanged: ((LiveTranscriptSnapshot) -> Void)?

    init(
        capture: LiveAudioCapturing = LiveSystemAudioCapture(),
        sttRunner: LiveSTTRunning = LiveSTTCLIRunner(),
        deduplicator: LiveTranscriptDeduplicator = LiveTranscriptDeduplicator(),
        chunkDuration: TimeInterval = 30,
        updateIntervalNanoseconds: UInt64 = 8_000_000_000,
        maximumTranscriptCharacters: Int = 40_000,
        logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)? = nil
    ) {
        self.capture = capture
        self.sttRunner = sttRunner
        self.deduplicator = deduplicator
        self.chunkDuration = chunkDuration
        self.updateIntervalNanoseconds = updateIntervalNanoseconds
        self.updateIntervalSeconds = TimeInterval(updateIntervalNanoseconds) / 1_000_000_000
        self.maximumTranscriptCharacters = maximumTranscriptCharacters
        self.logger = logger
    }

    func setVisible(_ visible: Bool) {
        let previous = isVisible
        isVisible = visible
        if previous != visible {
            Task {
                await log(
                    "Live transcript visibility changed: \(previous) -> \(visible), userEnabled=\(isUserEnabled), shouldRun=\(shouldRun)",
                    level: .info
                )
            }
        }
        reconcile()
    }

    func setUserEnabled(_ enabled: Bool) {
        let previous = isUserEnabled
        isUserEnabled = enabled
        Task {
            await log(
                "Live transcript user toggle changed: \(previous) -> \(enabled), visible=\(isVisible), shouldRun=\(shouldRun)",
                level: .info
            )
        }
        publish(snapshot: LiveTranscriptSnapshot(
            text: snapshot.text,
            status: statusForCurrentInputs(),
            isUserEnabled: enabled,
            lastUpdatedAt: snapshot.lastUpdatedAt,
            nextChunkAt: enabled ? snapshot.nextChunkAt : nil,
            lastChunkMessage: enabled ? snapshot.lastChunkMessage : nil
        ))
        reconcile()
    }

    func clearTranscript() {
        publish(snapshot: LiveTranscriptSnapshot(
            text: "",
            status: snapshot.status,
            isUserEnabled: isUserEnabled,
            lastUpdatedAt: nil,
            nextChunkAt: snapshot.nextChunkAt,
            lastChunkMessage: nil
        ))
    }

    func setRecordingActive(_ active: Bool) {
        // Live transcript captures system audio independently from the regular
        // recording pipeline. Keep this hook for existing dashboard refresh
        // wiring, but do not let recording state gate live capture.
    }

    func stop() {
        Task {
            await log("Live transcript stop requested.", level: .info)
        }
        isUserEnabled = false
        isVisible = false
        reconcile()
    }

    private var shouldRun: Bool {
        isVisible && isUserEnabled
    }

    private func reconcile() {
        if shouldRun {
            guard runTask == nil else {
                Task {
                    await log("Live transcript reconcile: run already active.", level: .debug)
                }
                return
            }
            Task {
                await log("Live transcript reconcile: starting run task.", level: .info)
            }
            startRunTask()
            return
        }

        if let runTask {
            Task {
                await log("Live transcript reconcile: cancelling active run task.", level: .info)
            }
            publish(status: .stopping)
            runTask.cancel()
            return
        }

        publish(status: statusForCurrentInputs())
    }

    private func startRunTask() {
        let runID = UUID()
        activeRunID = runID
        publish(status: .starting)
        Task {
            await log("Live transcript run \(runID.uuidString) starting.", level: .info)
        }
        runTask = Task { [weak self] in
            await self?.runLiveTranscript(runID: runID)
        }
    }

    private func runLiveTranscript(runID: UUID) async {
        do {
            await log("Live transcript run \(runID.uuidString): starting system audio capture.", level: .info)
            try await capture.start()
            await log(
                "Live transcript run \(runID.uuidString): capture started. \(captureDiagnosticsSummary())",
                level: .info
            )

            while !Task.isCancelled, shouldRun {
                publish(status: .running, nextChunkAt: Date().addingTimeInterval(updateIntervalSeconds))
                await log(
                    "Live transcript run \(runID.uuidString): waiting \(String(format: "%.1f", updateIntervalSeconds))s before next chunk. \(captureDiagnosticsSummary())",
                    level: .debug
                )
                try await Task.sleep(nanoseconds: updateIntervalNanoseconds)
                guard !Task.isCancelled, shouldRun else {
                    await log(
                        "Live transcript run \(runID.uuidString): loop exiting after wait. cancelled=\(Task.isCancelled), shouldRun=\(shouldRun)",
                        level: .info
                    )
                    break
                }
                try await transcribeRecentChunk()
            }
        } catch is CancellationError {
            await log("Live transcript run \(runID.uuidString): cancelled.", level: .info)
        } catch {
            isUserEnabled = false
            await log(
                "Live transcript run \(runID.uuidString): failed: \(error.localizedDescription). \(captureDiagnosticsSummary())",
                level: .error
            )
            publish(status: .failed(error.localizedDescription))
        }

        await capture.stop()
        await log(
            "Live transcript run \(runID.uuidString): capture stopped. \(captureDiagnosticsSummary())",
            level: .info
        )

        if activeRunID == runID {
            runTask = nil
            activeRunID = nil
            publish(snapshot: LiveTranscriptSnapshot(
                text: snapshot.text,
                status: statusForCurrentInputs(),
                isUserEnabled: isUserEnabled,
                lastUpdatedAt: snapshot.lastUpdatedAt,
                nextChunkAt: nil,
                lastChunkMessage: snapshot.lastChunkMessage
            ))
            if shouldRun {
                await log("Live transcript run \(runID.uuidString): shouldRun still true after cleanup, restarting.", level: .info)
                startRunTask()
            }
        }
    }

    private func transcribeRecentChunk() async throws {
        guard let chunk = try await capture.writeRecentChunk(duration: chunkDuration) else {
            await log(
                "Live transcript skipped chunk: not enough captured system audio yet. requestedDuration=\(String(format: "%.2f", chunkDuration))s; \(captureDiagnosticsSummary())",
                level: .warn
            )
            publish(snapshot: LiveTranscriptSnapshot(
                text: snapshot.text,
                status: .running,
                isUserEnabled: isUserEnabled,
                lastUpdatedAt: Date(),
                nextChunkAt: nil,
                lastChunkMessage: String(localized: "No system audio captured yet.")
            ))
            return
        }

        await log(
            String(
                format: "Live transcript chunk ready: duration=%.2fs samples=%d peak=%.5f rms=%.5f bytes=%lld; %@",
                chunk.duration,
                chunk.sampleCount,
                chunk.peakAmplitude,
                chunk.rmsAmplitude,
                chunk.byteSize,
                captureDiagnosticsSummary()
            ),
            level: .info
        )
        publish(status: .transcribing)
        let startedAt = Date()
        await log("Live transcript STT starting for chunk: url=\(chunk.url.path)", level: .info)
        let fragment = try await sttRunner.transcribe(chunk: chunk)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let elapsed = Date().timeIntervalSince(startedAt)
        guard !Task.isCancelled, shouldRun else {
            await log(
                "Live transcript STT completed after stop/cancel: elapsed=\(String(format: "%.2f", elapsed))s chars=\(fragment.count), cancelled=\(Task.isCancelled), shouldRun=\(shouldRun)",
                level: .info
            )
            return
        }

        guard !fragment.isEmpty else {
            await log(
                String(
                    format: "Live transcript STT returned empty text: elapsed=%.2fs duration=%.2fs peak=%.5f rms=%.5f bytes=%lld; %@",
                    elapsed,
                    chunk.duration,
                    chunk.peakAmplitude,
                    chunk.rmsAmplitude,
                    chunk.byteSize,
                    captureDiagnosticsSummary()
                ),
                level: .warn
            )
            publish(snapshot: LiveTranscriptSnapshot(
                text: snapshot.text,
                status: .running,
                isUserEnabled: isUserEnabled,
                lastUpdatedAt: Date(),
                nextChunkAt: nil,
                lastChunkMessage: String(localized: "No system speech detected in the last chunk.")
            ))
            return
        }

        await log(
            "Live transcript STT returned text: elapsed=\(String(format: "%.2f", elapsed))s chars=\(fragment.count), previousTranscriptChars=\(snapshot.text.count)",
            level: .info
        )
        let merged = deduplicator.appending(fragment, to: snapshot.text)
        await log(
            "Live transcript merge completed: fragmentChars=\(fragment.count), previousChars=\(snapshot.text.count), mergedChars=\(merged.count), cappedChars=\(cappedTranscript(merged).count)",
            level: .info
        )
        publish(snapshot: LiveTranscriptSnapshot(
            text: cappedTranscript(merged),
            status: .running,
            isUserEnabled: isUserEnabled,
            lastUpdatedAt: Date(),
            nextChunkAt: nil,
            lastChunkMessage: nil
        ))
    }

    private func statusForCurrentInputs() -> LiveTranscriptStatus {
        guard isUserEnabled else {
            return .idle
        }
        guard isVisible else {
            return .idle
        }
        return .running
    }

    private func cappedTranscript(_ text: String) -> String {
        guard text.count > maximumTranscriptCharacters else {
            return text
        }
        return String(text.suffix(maximumTranscriptCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func publish(status: LiveTranscriptStatus, nextChunkAt: Date? = nil) {
        publish(snapshot: LiveTranscriptSnapshot(
            text: snapshot.text,
            status: status,
            isUserEnabled: isUserEnabled,
            lastUpdatedAt: snapshot.lastUpdatedAt,
            nextChunkAt: nextChunkAt,
            lastChunkMessage: snapshot.lastChunkMessage
        ))
    }

    private func publish(snapshot: LiveTranscriptSnapshot) {
        self.snapshot = snapshot
        onSnapshotChanged?(snapshot)
    }

    private func log(_ message: String, level: LoggingService.LogLevel) async {
        guard let logger else {
            return
        }
        await logger(message, level)
    }

    private func captureDiagnosticsSummary() -> String {
        let diagnostics = capture.diagnostics()
        let sampleRate = diagnostics.sampleRate.map { String(format: "%.0f", $0) } ?? "nil"
        let lastAudioAge = diagnostics.lastAudioAt.map { String(format: "%.1fs ago", -$0.timeIntervalSinceNow) } ?? "never"
        return String(
            format: "capture{capturing=%@, received=%d, appended=%d, dropped=%d, bufferedSamples=%d, bufferedDuration=%.2fs, sampleRate=%@, lastAudio=%@, lastDrop=%@}",
            diagnostics.isCapturing ? "true" : "false",
            diagnostics.receivedAudioBuffers,
            diagnostics.appendedAudioBuffers,
            diagnostics.droppedAudioBuffers,
            diagnostics.bufferedSamples,
            diagnostics.bufferedDuration,
            sampleRate,
            lastAudioAge,
            diagnostics.lastDropReason ?? "none"
        )
    }
}
