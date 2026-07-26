import AppKit
import Foundation

protocol WindowSnapshotProviding {
    func visibleWindows(scope: WindowObserverConfig.Scope) -> [ObservedWindow]
}

final class WindowObserverSource: AutomationSource {
    let id: AutomationSourceID = .windowObserver
    let events: AsyncStream<AutomationEvent>

    private let appSettingsStore: AppSettingsStoreProtocol
    private let loggingService: LoggingService
    private let snapshotProvider: WindowSnapshotProviding
    private let currentSessionProvider: @Sendable () async -> RecordingSession?
    private let sleep: @Sendable (UInt64) async -> Void
    private let continuation: AsyncStream<AutomationEvent>.Continuation
    private var loopTask: Task<Void, Never>?
    private var candidate: StableCandidate?
    private var lastEmittedStableIdentity: String?

    init(
        appSettingsStore: AppSettingsStoreProtocol,
        loggingService: LoggingService,
        snapshotProvider: WindowSnapshotProviding = CGWindowSnapshotProvider(),
        currentSessionProvider: @escaping @Sendable () async -> RecordingSession? = { nil },
        sleep: @escaping @Sendable (UInt64) async -> Void = { value in
            try? await Task.sleep(nanoseconds: value)
        }
    ) {
        self.appSettingsStore = appSettingsStore
        self.loggingService = loggingService
        self.snapshotProvider = snapshotProvider
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
        candidate = nil
        lastEmittedStableIdentity = nil
    }

    private func runLoop() async {
        while !Task.isCancelled {
            let interval = await tick()
            await sleep(UInt64(interval * 1_000_000_000))
        }
    }

    private func tick() async -> TimeInterval {
        let settings = await appSettingsStore.load(using: loggingService)
        let config = settings.automation.windowObserverSettings.normalized()
        guard config.enabled else {
            candidate = nil
            lastEmittedStableIdentity = nil
            return TimeInterval(config.pollIntervalSec)
        }
        if await currentSessionProvider() != nil {
            candidate = nil
            lastEmittedStableIdentity = nil
            return TimeInterval(config.pollIntervalSec)
        }

        let windows = snapshotProvider.visibleWindows(scope: config.scope)
        guard let match = WindowMatcher.firstMatch(in: windows, rules: config.rules) else {
            candidate = nil
            lastEmittedStableIdentity = nil
            return TimeInterval(config.pollIntervalSec)
        }

        let now = Date()
        if candidate?.match.stableIdentity != match.stableIdentity {
            candidate = StableCandidate(match: match, firstSeenAt: now)
        }

        guard let candidate,
              now.timeIntervalSince(candidate.firstSeenAt) >= TimeInterval(config.stableMatchSec),
              lastEmittedStableIdentity != match.stableIdentity else {
            return TimeInterval(config.pollIntervalSec)
        }

        lastEmittedStableIdentity = match.stableIdentity
        continuation.yield(
            AutomationEvent(
                sourceID: id,
                kind: .windowMatched(match: match, config: config, settings: settings)
            )
        )
        return TimeInterval(config.pollIntervalSec)
    }

    private struct StableCandidate {
        let match: WindowObserverMatch
        let firstSeenAt: Date
    }
}

struct CGWindowSnapshotProvider: WindowSnapshotProviding {
    func visibleWindows(scope: WindowObserverConfig.Scope) -> [ObservedWindow] {
        guard let infoList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else {
            return []
        }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var windows: [ObservedWindow] = []
        for info in infoList {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  !ownerName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let pid = info[kCGWindowOwnerPID as String] as? Int32 else {
                continue
            }

            if scope == .activeApplication, frontmostPID != nil, pid != frontmostPID {
                continue
            }

            let title = info[kCGWindowName as String] as? String ?? ""
            windows.append(
                ObservedWindow(
                    applicationName: ownerName,
                    title: title,
                    processIdentifier: pid
                )
            )
        }
        return windows
    }
}
