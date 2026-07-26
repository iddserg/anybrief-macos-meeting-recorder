import AVFoundation
import CoreGraphics
import Foundation
import UserNotifications

actor PermissionService {
    enum PermissionKind: CaseIterable {
        case microphone
        case screenRecording
        case notifications
        case calendar
    }

    enum PermissionStatus: String {
        case granted
        case denied
        case notDetermined
    }

    private var lastCheckedAtByKind: [PermissionKind: Date] = [:]

    func check(_ kind: PermissionKind) async -> PermissionStatus {
        let status: PermissionStatus
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                status = .granted
            case .denied, .restricted:
                status = .denied
            case .notDetermined:
                status = .notDetermined
            @unknown default:
                status = .notDetermined
            }
        case .screenRecording:
            status = CGPreflightScreenCaptureAccess() ? .granted : .denied
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                status = .granted
            case .denied:
                status = .denied
            case .notDetermined:
                status = .notDetermined
            @unknown default:
                status = .notDetermined
            }
        case .calendar:
            status = .notDetermined
        }

        lastCheckedAtByKind[kind] = Date()
        return status
    }

    func request(_ kind: PermissionKind) async -> PermissionStatus {
        switch kind {
        case .microphone:
            let isGranted = await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
            let status: PermissionStatus = isGranted ? .granted : .denied
            lastCheckedAtByKind[kind] = Date()
            return status
        case .screenRecording:
            let status: PermissionStatus = await MainActor.run {
                if CGPreflightScreenCaptureAccess() {
                    return PermissionStatus.granted
                }

                let isGranted = CGRequestScreenCaptureAccess()
                return isGranted ? PermissionStatus.granted : PermissionStatus.denied
            }
            lastCheckedAtByKind[kind] = Date()
            return status
        case .notifications:
            let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
            let status: PermissionStatus = granted ? .granted : .denied
            lastCheckedAtByKind[kind] = Date()
            return status
        case .calendar:
            lastCheckedAtByKind[kind] = Date()
            return .notDetermined
        }
    }

    func lastCheckedAt(for kind: PermissionKind) -> Date? {
        lastCheckedAtByKind[kind]
    }
}
