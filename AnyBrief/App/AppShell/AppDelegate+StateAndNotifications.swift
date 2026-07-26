import AppKit
import Foundation

extension AppDelegate {
    func apply(appState: AppState) async {
        let currentSession = await recordingAdapter.currentSession()
        let effectiveAppState: AppState = currentSession == nil ? appState : .recording
        await MainActor.run {
            environment.appState = effectiveAppState
            menuContext = MenuBarContext(appState: effectiveAppState, currentSession: currentSession)
            menuBarManager.update(
                context: menuContext,
                target: self
            )
        }
    }

    func handleRecordingActionError(_ error: Error, action: String) async {
        if action == "start", error is RecordingAlreadyActiveError {
            await environment.loggingService.log(
                "Start requested while recording is already active. Ignoring duplicate action.",
                level: .info,
                component: "Recording"
            )
            await apply(appState: .recording)
            return
        }

        if (action == "stop" || action == "force-stop"), error is NoActiveRecordingError {
            await environment.loggingService.log(
                "Stop requested but no active recording. Resetting UI.",
                level: .warn,
                component: "Recording"
            )
            await apply(appState: .idle)
            return
        }

        await environment.loggingService.log(
            "Failed to \(action) recording: \(error.localizedDescription)",
            level: .error,
            component: "Recording"
        )
        await notificationService.publishInternal(
            category: "recording_error",
            title: "AnyBrief",
            body: "Failed to \(action) recording: \(error.localizedDescription)"
        )

        if action == "start" {
            await apply(appState: .error)
        }
    }

    func handleSystemWillSleep() async {
        guard await recordingAdapter.currentSession() != nil else {
            return
        }

        await environment.loggingService.log(
            "System will sleep; stopping active recording before suspend.",
            level: .warn,
            component: "Recording"
        )

        do {
            let session = try await recordingAdapter.stop()
            await pipelineOrchestrator.enqueue(session: session)
        } catch is NoActiveRecordingError {
            await environment.loggingService.log(
                "Sleep handler found no active recording by the time stop executed.",
                level: .info,
                component: "Recording"
            )
        } catch {
            await environment.loggingService.log(
                "Failed to stop recording before sleep: \(error.localizedDescription)",
                level: .error,
                component: "Recording"
            )
        }
    }

    func deliverUserNotification(category: String, title: String, body: String) async {
        guard let category = NotificationService.Category(rawValue: category) else {
            return
        }
        await notificationService.notify(category: category, title: title, body: body)
    }

    func refreshPermissionAppState() async {
        let microphoneStatus = await environment.permissionService.check(.microphone)
        let screenRecordingStatus = await environment.permissionService.check(.screenRecording)
        let permissionAppState: AppState =
            (microphoneStatus == .denied || screenRecordingStatus == .denied) ? .needsPermissions : .idle

        await environment.loggingService.log(
            "Permission status: microphone=\(microphoneStatus.rawValue), screenRecording=\(screenRecordingStatus.rawValue)",
            level: .info,
            component: "Permissions"
        )

        let deniedPermissions = [
            microphoneStatus == .denied ? "Microphone" : nil,
            screenRecordingStatus == .denied ? "Screen Recording" : nil,
        ]
        .compactMap { $0 }

        if deniedPermissions.isEmpty {
            lastPermissionNotificationSignature = nil
        } else {
            let signature = deniedPermissions.joined(separator: "|")
            if lastPermissionNotificationSignature != signature {
                lastPermissionNotificationSignature = signature
                await notificationService.publishInternal(
                    category: "permissions_error",
                    title: "AnyBrief",
                    body: deniedPermissions.joined(separator: " and ") + " permission is denied."
                )
            }
        }
        await apply(appState: permissionAppState)
    }

    func handleNewInAppNotification(_ item: InAppNotificationItem) async {
        _ = item
        guard await recordingAdapter.currentSession() != nil else {
            return
        }

        _ = await MainActor.run {
            NSApp.requestUserAttention(.informationalRequest)
        }
    }
}
