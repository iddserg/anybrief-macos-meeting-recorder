import Darwin
import Foundation

final class ProcessAudioRecorder: AudioRecording {
    private let recorderURL: URL
    private let micURL: URL
    private let systemURL: URL
    private let logURL: URL
    private var process: Process?

    init(recorderURL: URL, micURL: URL, systemURL: URL, logURL: URL) {
        self.recorderURL = recorderURL
        self.micURL = micURL
        self.systemURL = systemURL
        self.logURL = logURL
    }

    func start() async throws {
        let logHandle = try Self.openLogHandle(at: logURL)
        let process = Process()
        process.executableURL = recorderURL
        process.arguments = [
            "--system-out", systemURL.path,
            "--mic-out", micURL.path,
        ]
        process.standardOutput = logHandle
        process.standardError = logHandle
        try process.run()
        self.process = process
    }

    func stop() async throws {
        guard let process else { return }

        if process.isRunning {
            process.terminate()
        }

        let didExitGracefully = try await waitForExit(of: process, pollInterval: 200_000_000, timeout: 10)

        if !didExitGracefully && process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            _ = try await waitForExit(of: process, pollInterval: 100_000_000, timeout: 5)
        }

        self.process = nil
    }

    func setMicrophonePaused(_ paused: Bool) throws {
        // External recorder processes do not expose a microphone mute control.
        // The in-app recorder handles this feature.
    }

    func audioLevels() -> AudioLevelSnapshot {
        AudioLevelSnapshot()
    }

    private static func openLogHandle(at url: URL) throws -> FileHandle {
        let fileManager = FileManager.default
        let directoryURL = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func waitForExit(of process: Process, pollInterval: UInt64, timeout: TimeInterval?) async throws -> Bool {
        let deadline = timeout.map { Date().addingTimeInterval($0) }

        while process.isRunning {
            if let deadline, Date() >= deadline {
                return false
            }
            try await Task.sleep(nanoseconds: pollInterval)
        }

        return true
    }
}
