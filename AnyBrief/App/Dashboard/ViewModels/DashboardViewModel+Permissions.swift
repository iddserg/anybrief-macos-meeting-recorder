
import AppKit

extension DashboardViewModel {
    func openSystemSettings(for permission: PermissionRow) {
        workspace.open(permission.systemSettingsURL)
    }

    func recheckPermissions() {
        guard !isRecheckingPermissions else {
            return
        }
        isRecheckingPermissions = true
        Task {
            await refreshPermissions()
            await MainActor.run {
                lastPermissionsRecheckAt = Date()
                isRecheckingPermissions = false
            }
        }
    }

    func requestScreenRecording() {
        Task {
            let status = await permissionService.request(.screenRecording)
            await refreshPermissions()
            if status != .granted {
                _ = await MainActor.run {
                    workspace.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                }
            }
        }
    }

    func requestMicrophone() {
        Task {
            _ = await permissionService.request(.microphone)
            await refreshPermissions()
        }
    }

    func requestNotifications() {
        Task {
            _ = await permissionService.request(.notifications)
            await refreshPermissions()
        }
    }
    func loadPermissions() async -> [PermissionRow] {
        let microphoneStatus = await permissionService.check(.microphone)
        let screenRecordingStatus = await permissionService.check(.screenRecording)
        let notificationsStatus = await permissionService.check(.notifications)
        return [
            PermissionRow(
                id: "microphone",
                title: String(localized: "Microphone"),
                detail: String(localized: "Required to record your own voice during the call."),
                rawStatus: microphoneStatus,
                status: Self.label(for: microphoneStatus),
                systemSettingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            ),
            PermissionRow(
                id: "screenRecording",
                title: String(localized: "Screen Recording"),
                detail: String(localized: "Required so recorder can capture system audio from the call."),
                rawStatus: screenRecordingStatus,
                status: Self.label(for: screenRecordingStatus),
                systemSettingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            ),
            PermissionRow(
                id: "notifications",
                title: String(localized: "Notifications"),
                detail: String(localized: "Required for recording and summary alerts from AnyBrief."),
                rawStatus: notificationsStatus,
                status: Self.label(for: notificationsStatus),
                systemSettingsURL: URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!
            ),
        ]
    }
    static func label(for status: PermissionService.PermissionStatus) -> String {
        switch status {
        case .granted:
            return String(localized: "Granted")
        case .denied:
            return String(localized: "Missing")
        case .notDetermined:
            return String(localized: "Not requested")
        }
    }
}
