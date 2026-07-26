import Foundation

final class CalDAVAutomationSource: AutomationSource {
    private static let calendarAccessErrorBackoff: TimeInterval = 15 * 60

    let id: AutomationSourceID = .calDAV
    let events: AsyncStream<AutomationEvent>

    private let appSettingsStore: AppSettingsStoreProtocol
    private let keychainStore: SecretStoreProtocol
    private let calendarService: CalDAVCalendarService
    private let loggingService: LoggingService
    private let currentSessionProvider: @Sendable () async -> RecordingSession?
    private let sleep: @Sendable (UInt64) async -> Void
    private let continuation: AsyncStream<AutomationEvent>.Continuation
    private var loopTask: Task<Void, Never>?
    private var calendarSyncBackoffUntil: Date?
    private var lastBackoffErrorDescription: String?
    private var lastBackoffSettingsSignature: String?

    init(
        appSettingsStore: AppSettingsStoreProtocol,
        keychainStore: SecretStoreProtocol,
        calendarService: CalDAVCalendarService,
        loggingService: LoggingService,
        currentSessionProvider: @escaping @Sendable () async -> RecordingSession? = { nil },
        sleep: @escaping @Sendable (UInt64) async -> Void = { value in
            try? await Task.sleep(nanoseconds: value)
        }
    ) {
        self.appSettingsStore = appSettingsStore
        self.keychainStore = keychainStore
        self.calendarService = calendarService
        self.loggingService = loggingService
        self.currentSessionProvider = currentSessionProvider
        self.sleep = sleep

        var streamContinuation: AsyncStream<AutomationEvent>.Continuation!
        events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func start() async {
        guard loopTask == nil else {
            return
        }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() async {
        loopTask?.cancel()
        loopTask = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let interval = await tick()
            await sleep(UInt64(interval * 1_000_000_000))
        }
    }

    private func tick() async -> TimeInterval {
        let settings = await appSettingsStore.load(using: loggingService)
        let baseInterval = AutomationActionResolver.basePollInterval(for: settings)
        guard settings.automation.calDAVSettings.enabled, settings.automation.calendarAutopilotSettings.enabled else {
            clearCalendarSyncBackoff()
            return baseInterval
        }

        let password = settings.automation.calDAVSettings.passwordKeychainRef.flatMap { keychainStore.load(key: $0) }
        let settingsSignature = calendarSyncSettingsSignature(settings: settings, password: password)
        if let calendarSyncBackoffUntil, calendarSyncBackoffUntil > Date() {
            if lastBackoffSettingsSignature == settingsSignature {
                return baseInterval
            }
            clearCalendarSyncBackoff()
        }

        do {
            let events = try await calendarService.fetchEvents(
                settings: settings,
                password: password,
                from: Date().addingTimeInterval(-3600),
                to: Date().addingTimeInterval(24 * 3600)
            )
            clearCalendarSyncBackoff()
            continuation.yield(AutomationEvent(sourceID: id, kind: .calendarEventsRefreshed(events: events, settings: settings)))
            let session = await currentSessionProvider()
            return AutomationActionResolver.nextWakeInterval(
                now: Date(),
                events: events,
                settings: settings,
                currentSession: session
            )
        } catch {
            if error is SuppressedCalendarFetchError {
                return baseInterval
            }
            if await handleCalendarSyncError(error, settingsSignature: settingsSignature) {
                return baseInterval
            }
            continuation.yield(AutomationEvent(sourceID: id, kind: .sourceFailed(message: error.localizedDescription)))
            return baseInterval
        }
    }

    private func handleCalendarSyncError(_ error: Error, settingsSignature: String) async -> Bool {
        guard shouldThrottleAutomaticRetries(for: error) else {
            return false
        }

        let description = error.localizedDescription
        calendarSyncBackoffUntil = Date().addingTimeInterval(Self.calendarAccessErrorBackoff)
        lastBackoffSettingsSignature = settingsSignature
        if lastBackoffErrorDescription != description {
            lastBackoffErrorDescription = description
            await loggingService.log(
                "Autopilot calendar sync failed: \(description). Pausing automatic calendar checks for 15 minutes.",
                level: .warn,
                component: "Autopilot"
            )
        }
        return true
    }

    private func clearCalendarSyncBackoff() {
        calendarSyncBackoffUntil = nil
        lastBackoffErrorDescription = nil
        lastBackoffSettingsSignature = nil
    }

    private func shouldThrottleAutomaticRetries(for error: Error) -> Bool {
        if let calendarError = error as? CalendarSyncError {
            return calendarError.shouldThrottleAutomaticRetries
        }
        return false
    }

    private func calendarSyncSettingsSignature(settings: AppSettings, password: String?) -> String {
        [
            settings.automation.calDAVSettings.config.url.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.automation.calDAVSettings.config.username.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.automation.calDAVSettings.name.trimmingCharacters(in: .whitespacesAndNewlines),
            settings.automation.calDAVSettings.passwordKeychainRef ?? "",
            String(password?.hashValue ?? 0),
        ].joined(separator: "\n")
    }
}
