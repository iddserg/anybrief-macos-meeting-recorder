import Foundation
import UserNotifications

/// Delivers local macOS notifications according to app settings from the UI spec.
actor NotificationService {
    enum Category: String {
        case recordingStarted = "recording_started"
        case recordingStopped = "recording_stopped"
        case preEnd = "pre_end"
        case summaryReady = "summary_ready"
        case autoSkipped = "auto_skipped"
        case recordingInterrupted = "recording_interrupted"
        case windowObserver = "window_observer"
    }

    private let appSettingsStore: AppSettingsStoreProtocol
    private let inAppNotificationStore: InAppNotificationStore
    private let loggingService: LoggingService
    private let checkPermissionStatus: @Sendable () async -> PermissionService.PermissionStatus
    private let requestPermissionStatus: @Sendable () async -> PermissionService.PermissionStatus
    private let deliver: @Sendable (String, String) async throws -> Void
    private let didDeliverInAppNotification: @Sendable (InAppNotificationItem) async -> Void

    init(
        appSettingsStore: AppSettingsStoreProtocol,
        inAppNotificationStore: InAppNotificationStore,
        permissionService: PermissionService,
        loggingService: LoggingService,
        checkPermissionStatus: (@Sendable () async -> PermissionService.PermissionStatus)? = nil,
        requestPermissionStatus: (@Sendable () async -> PermissionService.PermissionStatus)? = nil,
        deliver: @escaping @Sendable (String, String) async throws -> Void = { title, body in
            try await NotificationService.deliverSystemNotification(title: title, body: body)
        },
        didDeliverInAppNotification: @escaping @Sendable (InAppNotificationItem) async -> Void = { _ in }
    ) {
        self.appSettingsStore = appSettingsStore
        self.inAppNotificationStore = inAppNotificationStore
        self.loggingService = loggingService
        self.checkPermissionStatus = checkPermissionStatus ?? {
            await permissionService.check(.notifications)
        }
        self.requestPermissionStatus = requestPermissionStatus ?? {
            await permissionService.request(.notifications)
        }
        self.deliver = deliver
        self.didDeliverInAppNotification = didDeliverInAppNotification
    }

    func requestAuthorizationIfNeeded() async -> PermissionService.PermissionStatus {
        let current = await checkPermissionStatus()
        guard current == .notDetermined else {
            return current
        }
        return await requestPermissionStatus()
    }

    func notifyRecordingStarted() async {
        await notify(category: .recordingStarted, title: "AnyBrief", body: String(localized: "Recording started"))
    }

    func notifyPreEndWarning() async {
        await notify(category: .preEnd, title: "AnyBrief", body: String(localized: "Recording will stop in 2 minutes"))
    }

    func notifyRecordingStopped() async {
        await notify(category: .recordingStopped, title: "AnyBrief", body: String(localized: "Recording stopped"))
    }

    func notifyBriefReady() async {
        await notify(category: .summaryReady, title: "AnyBrief", body: String(localized: "Your brief is ready"))
    }

    func notifySystemAudioFailed() async {
        await notify(
            category: .recordingInterrupted,
            title: "AnyBrief",
            body: String(localized: "System audio recording failed. Microphone recording continues.")
        )
    }

    func notifyAutoSkippedBecauseUserAbsent() async {
        await notify(
            category: .autoSkipped,
            title: "AnyBrief",
            body: String(localized: "Auto-recording didn't start: you were not at the computer")
        )
    }

    func publishInternal(category: String, title: String, body: String) async {
        await publishInAppNotification(category: category, title: title, body: body)
    }

    func notify(category: Category, title: String, body: String) async {
        await publishInAppNotification(category: category.rawValue, title: title, body: body)

        let settings = await appSettingsStore.load(using: loggingService)
        guard settings.application.showNotifications else {
            return
        }
        guard settings.application.notificationCategories.contains(category.rawValue) else {
            return
        }
        guard await checkPermissionStatus() == .granted else {
            return
        }

        do {
            try await deliver(title, body)
        } catch {
            await loggingService.log(
                "Failed to deliver notification \(category.rawValue): \(error.localizedDescription)",
                level: .warn,
                component: "Notifications"
            )
        }
    }

    private func publishInAppNotification(category: String, title: String, body: String) async {
        guard let item = await MainActor.run(body: {
            inAppNotificationStore.addIfUnreadDuplicateIsMissing(category: category, title: title, body: body)
        }) else {
            await loggingService.log(
                "Skipped duplicate in-app notification \(category).",
                level: .debug,
                component: "Notifications"
            )
            return
        }
        await didDeliverInAppNotification(item)
    }

    private static func deliverSystemNotification(title: String, body: String) async throws {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}
