import Foundation
import XCTest
@testable import AnyBrief

final class WindowObserverSourceTests: XCTestCase {
    func testSkipsWindowSnapshotsWhileRecordingIsActive() async {
        let snapshotProvider = CountingWindowSnapshotProvider()
        let didSleep = expectation(description: "window observer completed one polling tick")
        let source = WindowObserverSource(
            appSettingsStore: WindowObserverTestSettingsStore(),
            loggingService: Self.loggingService(),
            snapshotProvider: snapshotProvider,
            currentSessionProvider: { Self.activeRecordingSession() },
            sleep: { _ in
                didSleep.fulfill()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        )

        await source.start()
        await fulfillment(of: [didSleep], timeout: 2)
        await source.stop()

        XCTAssertEqual(snapshotProvider.requestCount, 0)
    }

    private static func activeRecordingSession() -> RecordingSession {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anybrief-window-observer-test", isDirectory: true)
        return RecordingSession(
            jobId: "active-recording",
            pid: 42,
            paths: MeetingPaths(
                folderURL: root.appendingPathComponent("meeting", isDirectory: true),
                tmpURL: root.appendingPathComponent("meeting/tmp", isDirectory: true),
                systemWavURL: root.appendingPathComponent("meeting/tmp/system.wav", isDirectory: false),
                micWavURL: root.appendingPathComponent("meeting/tmp/mic.wav", isDirectory: false),
                jobLogURL: root.appendingPathComponent("logs/job.log", isDirectory: false)
            ),
            startedAt: Date(),
            source: "manual",
            title: "Manual recording",
            autoStopDisabled: false
        )
    }

    private static func loggingService() -> LoggingService {
        LoggingService(
            logsDirectoryURL: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )
    }
}

private final class CountingWindowSnapshotProvider: WindowSnapshotProviding {
    private let lock = NSLock()
    private var requests = 0

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func visibleWindows(scope: WindowObserverConfig.Scope) -> [ObservedWindow] {
        lock.lock()
        requests += 1
        lock.unlock()
        return [
            ObservedWindow(applicationName: "zoom.us", title: "Daily Sync", processIdentifier: 100),
        ]
    }
}

private struct WindowObserverTestSettingsStore: AppSettingsStoreProtocol {
    func load(using loggingService: LoggingService) async -> AppSettings {
        var settings = AppSettings.default
        settings.automation.windowObserverSettings = WindowObserverConfig(
            enabled: true,
            actionMode: .recordAndNotify,
            scope: .activeApplication,
            stableMatchSec: 1,
            pollIntervalSec: 1,
            rules: [WindowObserverRule(name: "Zoom", applicationPattern: "zoom")]
        )
        return settings
    }

    func save(_ settings: AppSettings) async throws {}
}
