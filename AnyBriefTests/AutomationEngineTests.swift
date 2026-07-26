import XCTest
@testable import AnyBrief

final class AutomationEngineTests: XCTestCase {
    func testDispatchesResolvedActionsForSourceEvents() async {
        let source = StubAutomationSource()
        let recorder = AutomationActionRecorder()
        let handled = expectation(description: "automation action handled")
        let engine = AutomationEngine(
            sources: [source],
            resolveActions: { event in
                [.skip(reason: "resolved-\(event.sourceID.rawValue)")]
            },
            handleAction: { action in
                await recorder.record(action)
                handled.fulfill()
            }
        )

        await engine.start()
        source.emit(AutomationEvent(sourceID: .calDAV, kind: .sourceFailed(message: "boom")))
        await fulfillment(of: [handled], timeout: 2)
        await engine.stop()

        let handledActions = await recorder.handledActions()
        XCTAssertEqual(handledActions, ["skip:resolved-caldav"])
    }
}

private final class StubAutomationSource: AutomationSource {
    let id: AutomationSourceID = .calDAV
    let events: AsyncStream<AutomationEvent>
    private let continuation: AsyncStream<AutomationEvent>.Continuation

    init() {
        var streamContinuation: AsyncStream<AutomationEvent>.Continuation!
        events = AsyncStream { continuation in
            streamContinuation = continuation
        }
        continuation = streamContinuation
    }

    func start() async {}

    func stop() async {
        continuation.finish()
    }

    func emit(_ event: AutomationEvent) {
        continuation.yield(event)
    }
}

private actor AutomationActionRecorder {
    private var actions: [String] = []

    func record(_ action: AutomationAction) {
        switch action {
        case let .skip(reason):
            actions.append("skip:\(reason)")
        case let .log(message, _):
            actions.append("log:\(message)")
        case let .startCalendarRecording(event, _, _):
            actions.append("start:\(event.uid)")
        case let .startWindowRecording(match, _):
            actions.append("start-window:\(match.recordingTitle)")
        case let .notifyWindowMatch(match):
            actions.append("notify-window:\(match.recordingTitle)")
        case let .stopCalendarRecording(session, _):
            actions.append("stop:\(session.jobId)")
        }
    }

    func handledActions() -> [String] {
        actions
    }
}
