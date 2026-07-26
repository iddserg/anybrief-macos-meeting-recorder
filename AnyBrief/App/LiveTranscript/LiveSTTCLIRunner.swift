import Foundation

final class LiveSTTCLIRunner: LiveSTTRunning {
    private let fileManager: FileManager
    private let sttURLResolver: () throws -> URL
    private let timeout: TimeInterval
    private let pollIntervalNanoseconds: UInt64
    private let terminationGracePeriodNanoseconds: UInt64
    private let logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)?

    init(
        fileManager: FileManager = .default,
        sttURLResolver: @escaping () throws -> URL = CLIPathResolver.resolveStt,
        timeout: TimeInterval = 90,
        pollIntervalNanoseconds: UInt64 = 100_000_000,
        terminationGracePeriodNanoseconds: UInt64 = 2_000_000_000,
        logger: (@Sendable (String, LoggingService.LogLevel) async -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.sttURLResolver = sttURLResolver
        self.timeout = timeout
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.terminationGracePeriodNanoseconds = terminationGracePeriodNanoseconds
        self.logger = logger
    }

    func transcribe(chunk: LiveAudioChunk) async throws -> String {
        let outputDir = chunk.url
            .deletingLastPathComponent()
            .appendingPathComponent("stt-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: outputDir)
            try? fileManager.removeItem(at: chunk.url)
        }
        let logURL = outputDir.appendingPathComponent("live-stt.log", isDirectory: false)
        let logHandle = try Self.openLogHandle(at: logURL)
        defer {
            try? logHandle.close()
        }

        let sttURL = try sttURLResolver()
        let process = Process()
        process.executableURL = sttURL
        process.arguments = [
            chunk.url.path,
            "--output=\(outputDir.path)",
            "--transcribe-only",
        ]

        process.standardOutput = logHandle
        process.standardError = logHandle

        await log(
            "Live STT CLI launching: executable=\(sttURL.path), input=\(chunk.url.path), outputDir=\(outputDir.path), timeout=\(Int(timeout))s",
            level: .info
        )
        let startedAt = Date()
        let status = try await run(process)
        let elapsed = Date().timeIntervalSince(startedAt)
        let outputFiles = outputFileList(in: outputDir)
        await log(
            "Live STT CLI exited: status=\(status), elapsed=\(String(format: "%.2f", elapsed))s, outputFiles=[\(outputFiles.joined(separator: ", "))]",
            level: status == 0 ? .info : .error
        )
        guard status == 0 else {
            try? logHandle.synchronize()
            let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            await log(
                "Live STT CLI failed output: \(output.trimmingCharacters(in: .whitespacesAndNewlines))",
                level: .error
            )
            throw LiveTranscriptError.sttFailed(status: status, output: output)
        }

        if let transcriptURL = Self.transcriptOutputCandidates(for: chunk.url, outputDir: outputDir)
            .first(where: { fileManager.fileExists(atPath: $0.path) }) {
            let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let artifactDir = preserveLastArtifacts(chunk: chunk, outputDir: outputDir, transcriptURL: transcriptURL)
            await log(
                "Live STT CLI transcript selected: file=\(transcriptURL.lastPathComponent), chars=\(transcript.count), artifactDir=\(artifactDir?.path ?? "unavailable")",
                level: transcript.isEmpty ? .warn : .info
            )
            return transcript
        }

        let artifactDir = preserveLastArtifacts(chunk: chunk, outputDir: outputDir, transcriptURL: nil)
        await log(
            "Live STT CLI output missing transcript file: outputFiles=[\(outputFiles.joined(separator: ", "))], artifactDir=\(artifactDir?.path ?? "unavailable")",
            level: .error
        )
        throw LiveTranscriptError.sttOutputMissing(outputFiles: outputFiles.joined(separator: ", "))
    }

    private static func transcriptOutputCandidates(for inputURL: URL, outputDir: URL) -> [URL] {
        let baseName = inputURL.deletingPathExtension().lastPathComponent
        return [
            outputDir.appendingPathComponent("\(baseName)_combined.txt", isDirectory: false),
            outputDir.appendingPathComponent("\(baseName)_transcript.txt", isDirectory: false),
        ]
    }

    private func run(_ process: Process) async throws -> Int32 {
        do {
            try process.run()
            await log("Live STT CLI process started: pid=\(process.processIdentifier)", level: .debug)
        } catch {
            await log("Live STT CLI launch failed: \(error.localizedDescription)", level: .error)
            throw LiveTranscriptError.sttLaunchFailed(error.localizedDescription)
        }

        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeout * 1_000_000_000))
        while process.isRunning {
            if Task.isCancelled {
                await log("Live STT CLI cancellation requested: pid=\(process.processIdentifier)", level: .info)
                await terminate(process)
                throw CancellationError()
            }
            if ContinuousClock.now >= deadline {
                await log("Live STT CLI timed out: pid=\(process.processIdentifier), timeout=\(Int(timeout))s", level: .error)
                await terminate(process)
                throw LiveTranscriptError.sttTimedOut(timeout)
            }
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }

        return process.terminationStatus
    }

    private static func openLogHandle(at url: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        fileManager.createFile(atPath: url.path, contents: nil)
        return try FileHandle(forWritingTo: url)
    }

    private func terminate(_ process: Process) async {
        guard process.isRunning else {
            return
        }

        await log("Live STT CLI sending SIGTERM: pid=\(process.processIdentifier)", level: .info)
        kill(process.processIdentifier, SIGTERM)
        let deadline = ContinuousClock.now + .nanoseconds(Int64(terminationGracePeriodNanoseconds))
        while process.isRunning, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
        if process.isRunning {
            await log("Live STT CLI sending SIGKILL: pid=\(process.processIdentifier)", level: .warn)
            kill(process.processIdentifier, SIGKILL)
        }
        while process.isRunning {
            try? await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    private func preserveLastArtifacts(
        chunk: LiveAudioChunk,
        outputDir: URL,
        transcriptURL: URL?
    ) -> URL? {
        let debugDir = fileManager
            .homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("live-transcript-debug", isDirectory: true)
        do {
            try? fileManager.removeItem(at: debugDir)
            try fileManager.createDirectory(at: debugDir, withIntermediateDirectories: true)
            try fileManager.copyItem(
                at: chunk.url,
                to: debugDir.appendingPathComponent("last-chunk.wav", isDirectory: false)
            )

            let outputCopyDir = debugDir.appendingPathComponent("stt-output", isDirectory: true)
            try fileManager.createDirectory(at: outputCopyDir, withIntermediateDirectories: true)
            for fileName in (try? fileManager.contentsOfDirectory(atPath: outputDir.path)) ?? [] {
                try? fileManager.copyItem(
                    at: outputDir.appendingPathComponent(fileName, isDirectory: false),
                    to: outputCopyDir.appendingPathComponent(fileName, isDirectory: false)
                )
            }

            let transcriptName = transcriptURL?.lastPathComponent ?? "missing"
            NSLog("AnyBrief live transcript artifacts saved to \(debugDir.path); transcript=\(transcriptName)")
            return debugDir
        } catch {
            NSLog("AnyBrief failed to preserve live transcript artifacts: \(error.localizedDescription)")
            return nil
        }
    }

    private func outputFileList(in outputDir: URL) -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: outputDir.path)) ?? []).sorted()
    }

    private func log(_ message: String, level: LoggingService.LogLevel) async {
        guard let logger else {
            return
        }
        await logger(message, level)
    }
}

enum LiveTranscriptError: LocalizedError {
    case sttLaunchFailed(String)
    case sttTimedOut(TimeInterval)
    case sttFailed(status: Int32, output: String)
    case sttOutputMissing(outputFiles: String)
    case audioCaptureUnavailable
    case audioChunkWriteFailed

    var errorDescription: String? {
        switch self {
        case let .sttLaunchFailed(detail):
            return "Live transcript STT did not start: \(detail)"
        case let .sttTimedOut(timeout):
            return "Live transcript STT timed out after \(Int(timeout)) seconds."
        case let .sttFailed(status, output):
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return "Live transcript STT exited with status \(status)."
            }
            return "Live transcript STT exited with status \(status): \(trimmed)"
        case let .sttOutputMissing(outputFiles):
            if outputFiles.isEmpty {
                return "Live transcript STT finished without transcript output."
            }
            return "Live transcript STT finished without transcript output. Files: \(outputFiles)"
        case .audioCaptureUnavailable:
            return "Live transcript could not start system audio capture."
        case .audioChunkWriteFailed:
            return "Live transcript could not write an audio chunk."
        }
    }
}
