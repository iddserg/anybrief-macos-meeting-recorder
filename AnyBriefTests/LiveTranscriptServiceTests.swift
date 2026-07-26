import XCTest
@testable import AnyBrief

@MainActor
final class LiveTranscriptServiceTests: XCTestCase {
    func testLiveTranscriptStartsWhenVisibleAndEnabled() async {
        let capture = FakeLiveAudioCapture()
        let runner = FakeLiveSTTRunner(fragments: ["hello"])
        let service = LiveTranscriptService(
            capture: capture,
            sttRunner: runner,
            updateIntervalNanoseconds: 20_000_000
        )

        service.setUserEnabled(true)
        await waitBriefly()
        XCTAssertEqual(capture.startCount, 0)

        service.setVisible(true)
        await waitUntil { capture.startCount == 1 }

        XCTAssertEqual(capture.startCount, 1)
        service.stop()
    }

    func testLiveTranscriptStopsWhenTabCloses() async {
        let capture = FakeLiveAudioCapture()
        let runner = FakeLiveSTTRunner(fragments: ["hello"])
        let service = LiveTranscriptService(
            capture: capture,
            sttRunner: runner,
            updateIntervalNanoseconds: 20_000_000
        )

        service.setUserEnabled(true)
        service.setVisible(true)
        service.setRecordingActive(true)
        await waitUntil { capture.startCount == 1 }

        service.setVisible(false)
        await waitUntil { capture.stopCount == 1 }

        XCTAssertEqual(capture.stopCount, 1)
        XCTAssertFalse(service.snapshot.isRunning)
    }

    func testLiveTranscriptDoesNotRunParallelSTTChunks() async {
        let capture = FakeLiveAudioCapture()
        let runner = FakeLiveSTTRunner(
            fragments: ["one two", "two three", "three four"],
            delayNanoseconds: 80_000_000
        )
        let service = LiveTranscriptService(
            capture: capture,
            sttRunner: runner,
            updateIntervalNanoseconds: 10_000_000
        )

        service.setUserEnabled(true)
        service.setVisible(true)
        service.setRecordingActive(true)

        await waitUntil { service.snapshot.text.contains("three") }
        service.stop()

        XCTAssertEqual(runner.maxConcurrentTranscriptions, 1)
        XCTAssertTrue(service.snapshot.text.contains("one two"))
        XCTAssertTrue(service.snapshot.text.contains("three"))
    }

    func testLiveTranscriptReportsEmptySTTChunk() async {
        let capture = FakeLiveAudioCapture()
        let runner = FakeLiveSTTRunner(fragments: [""])
        let service = LiveTranscriptService(
            capture: capture,
            sttRunner: runner,
            updateIntervalNanoseconds: 10_000_000
        )

        service.setUserEnabled(true)
        service.setVisible(true)

        await waitUntil { service.snapshot.lastChunkMessage != nil }
        service.stop()

        XCTAssertEqual(service.snapshot.text, "")
        XCTAssertEqual(
            service.snapshot.lastChunkMessage,
            String(localized: "No system speech detected in the last chunk.")
        )
    }

    func testLiveTranscriptReportsMissingSystemAudioFrames() async {
        let capture = FakeLiveAudioCapture(chunksEnabled: false)
        let runner = FakeLiveSTTRunner(fragments: ["not used"])
        let service = LiveTranscriptService(
            capture: capture,
            sttRunner: runner,
            updateIntervalNanoseconds: 10_000_000
        )

        service.setUserEnabled(true)
        service.setVisible(true)

        await waitUntil { service.snapshot.lastChunkMessage != nil }
        service.stop()

        XCTAssertEqual(runner.transcribeCount, 0)
        XCTAssertEqual(
            service.snapshot.lastChunkMessage,
            String(localized: "No system audio captured yet.")
        )
    }

    func testDisplayStateDefersUpdatesDuringUserInteraction() {
        var state = LiveTranscriptTextDisplayState()

        state.applyIncomingText("first")
        XCTAssertEqual(state.visibleText, "first")

        state.setUserInteractionActive(true)
        state.applyIncomingText("first\nsecond")

        XCTAssertEqual(state.visibleText, "first")
        XCTAssertEqual(state.pendingText, "first\nsecond")

        state.setUserInteractionActive(false)

        XCTAssertEqual(state.visibleText, "first\nsecond")
        XCTAssertNil(state.pendingText)
    }

    func testDeduplicatorRemovesLongChunkOverlap() {
        let deduplicator = LiveTranscriptDeduplicator()
        let firstChunk = (1...90).map { "word\($0)" }.joined(separator: " ")
        let secondChunk = (35...120).map { "word\($0)" }.joined(separator: " ")

        let merged = deduplicator.appending(secondChunk, to: firstChunk)

        XCTAssertTrue(merged.contains("word1"))
        XCTAssertTrue(merged.contains("word120"))
        XCTAssertEqual(merged.components(separatedBy: "word35").count, 2)
        XCTAssertEqual(merged.components(separatedBy: "word90").count, 2)
    }

    func testDeduplicatorToleratesSmallRecognitionDifferencesInOverlap() {
        let deduplicator = LiveTranscriptDeduplicator()
        let transcript = """
        Вариантов сайта даем там дизайнер еще что-то и вот оно появляется просто как грибы и непонятно за счет чего конкурируют
        """
        let fragment = """
        Вариантов сайта даем там дизайне еще что-то и вот оно появляется просто как гриб и непонятно за счет чего конкурируют дальше новая мысль
        """

        let merged = deduplicator.appending(fragment, to: transcript)

        XCTAssertEqual(merged.components(separatedBy: "Вариантов сайта").count, 2)
        XCTAssertTrue(merged.hasSuffix("дальше новая мысль"))
    }

    private func waitBriefly() async {
        try? await Task.sleep(nanoseconds: 40_000_000)
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        predicate: @MainActor @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

private final class FakeLiveAudioCapture: LiveAudioCapturing {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var chunkCounter = 0
    private let chunksEnabled: Bool

    init(chunksEnabled: Bool = true) {
        self.chunksEnabled = chunksEnabled
    }

    func start() async throws {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
    }

    func writeRecentChunk(duration: TimeInterval) async throws -> LiveAudioChunk? {
        guard chunksEnabled else {
            return nil
        }
        chunkCounter += 1
        return LiveAudioChunk(
            url: URL(fileURLWithPath: "/tmp/anybrief-live-test-\(chunkCounter).wav"),
            duration: duration
        )
    }

    func diagnostics() -> LiveAudioCaptureDiagnostics {
        LiveAudioCaptureDiagnostics(
            isCapturing: startCount > stopCount,
            receivedAudioBuffers: chunksEnabled ? chunkCounter : 0,
            appendedAudioBuffers: chunksEnabled ? chunkCounter : 0,
            droppedAudioBuffers: 0,
            bufferedSamples: chunksEnabled ? 48_000 : 0,
            bufferedDuration: chunksEnabled ? 3 : 0,
            sampleRate: chunksEnabled ? 16_000 : nil,
            lastAudioAt: chunksEnabled ? Date() : nil,
            lastDropReason: nil
        )
    }
}

private final class FakeLiveSTTRunner: LiveSTTRunning {
    private let fragments: [String]
    private let delayNanoseconds: UInt64
    private var inFlightTranscriptions = 0
    private(set) var maxConcurrentTranscriptions = 0
    private(set) var transcribeCount = 0

    init(fragments: [String], delayNanoseconds: UInt64 = 0) {
        self.fragments = fragments
        self.delayNanoseconds = delayNanoseconds
    }

    func transcribe(chunk: LiveAudioChunk) async throws -> String {
        inFlightTranscriptions += 1
        maxConcurrentTranscriptions = max(maxConcurrentTranscriptions, inFlightTranscriptions)
        defer {
            inFlightTranscriptions -= 1
        }

        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }

        let fragment = fragments[min(transcribeCount, fragments.count - 1)]
        transcribeCount += 1
        return fragment
    }
}
