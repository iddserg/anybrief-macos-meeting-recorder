import AppKit
import Foundation

extension AppDelegate {
    @objc func startRecording() {
        Task {
            do {
                _ = try await recordingAdapter.start(
                    jobId: JobIDGenerator.make(),
                    source: "manual",
                    title: "Manual recording"
                )
            } catch {
                await handleRecordingActionError(error, action: "start")
            }
        }
    }

    @MainActor
    @objc func stopRecording() {
        guard !isStoppingRecording else {
            Task {
                await environment.loggingService.log(
                    "Stop requested while another stop request is already in progress. Ignoring duplicate action.",
                    level: .info,
                    component: "Recording"
                )
            }
            return
        }

        isStoppingRecording = true
        Task {
            defer {
                Task { @MainActor in
                    self.isStoppingRecording = false
                }
            }

            do {
                let session = try await recordingAdapter.stop()
                await pipelineOrchestrator.enqueue(session: session)
            } catch {
                await handleRecordingActionError(error, action: "stop")
            }
        }
    }

    @objc func openDashboard() {
        Task { @MainActor in
            presentDashboard()
        }
    }

    @objc func openRecordingsFolder() {
        let url = environment.storageService.meetingsDirectoryURL
        NSWorkspace.shared.open(url)
    }

    @objc func forceStopCurrentRecording() {
        Task {
            guard let session = await recordingAdapter.currentSession() else {
                return
            }

            do {
                _ = try await recordingAdapter.cancel(jobId: session.jobId)
            } catch {
                await handleRecordingActionError(error, action: "force-stop")
            }
        }
    }

    @objc func toggleMicrophonePause() {
        Task {
            do {
                let paused = await recordingAdapter.isMicrophonePaused()
                _ = try await recordingAdapter.setMicrophonePaused(!paused)
                let appState = await MainActor.run {
                    environment.appState
                }
                await apply(appState: appState)
            } catch {
                await handleRecordingActionError(error, action: "toggle microphone pause")
            }
        }
    }

    @objc func disableAutoStopForCurrentMeeting() {
        Task {
            do {
                _ = try await recordingAdapter.disableAutoStop()
                let appState = await MainActor.run {
                    environment.appState
                }
                await apply(appState: appState)
            } catch {
                await handleRecordingActionError(error, action: "disable auto-stop")
            }
        }
    }

    @objc func openTodayFolder() {
        let todayFolderURL = environment.storageService.meetingsDirectoryURL
            .appendingPathComponent(todayFolderFormatter.string(from: Date()), isDirectory: true)
        try? FileManager.default.createDirectory(at: todayFolderURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(todayFolderURL)
    }

    @objc func openLogs() {
        let logsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("anybrief", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(logsURL)
    }

    @MainActor
    @objc func openAbout() {
        AboutWindowController.shared.show()
    }

    @objc func quit() {
        Task {
            await autopilotService.stop()
        }
        NSApp.terminate(nil)
    }
}
