import XCTest
@testable import AnyBrief

/// Tests stt `<name>_combined.txt` parsing.
/// Covers both output formats produced by different stt versions:
/// - Format A (current): `[MM:SS] Speaker A: inline text`
/// - Format B (spec/future): `[MM:SS.mmm - MM:SS.mmm] Speaker 1:` + text on next lines
final class CombinedTxtParserTests: XCTestCase {

    // MARK: - Format A (current stt output)

    func testFormatAParsesSingleLineSpeakerSegments() throws {
        let fileURL = try writeCombinedTxt(
            """
            [00:30] Speaker A: Привет, давайте начинать.
            [00:45] Speaker B: Да, всем привет. Начнем с повестки.
            [01:32] Speaker A: Первый пункт — синхронизация.
            """
        )

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .mic)

        XCTAssertEqual(segments.count, 3)
        // Mic track always has one local speaker — all labeled "Mic"
        XCTAssertEqual(segments[0].speaker, "Mic")
        XCTAssertEqual(segments[0].text, "Привет, давайте начинать.")
        XCTAssertEqual(segments[0].sourceTrack, .mic)
        XCTAssertEqual(segments[1].speaker, "Mic")
        XCTAssertEqual(segments[1].text, "Да, всем привет. Начнем с повестки.")
        XCTAssertEqual(segments[2].speaker, "Mic")
        XCTAssertEqual(segments[2].text, "Первый пункт — синхронизация.")
    }

    func testFormatATimestampsInSeconds() throws {
        let fileURL = try writeCombinedTxt(
            """
            [00:30] Speaker A: First.
            [01:15] Speaker B: Second.
            [02:00] Speaker A: Third.
            """
        )

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .system)

        XCTAssertEqual(segments[0].startTime, 30, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 75, accuracy: 0.001)    // derived from next segment start
        XCTAssertEqual(segments[1].startTime, 75, accuracy: 0.001)
        XCTAssertEqual(segments[1].endTime, 120, accuracy: 0.001)   // derived from next segment start
        XCTAssertEqual(segments[2].startTime, 120, accuracy: 0.001)
        XCTAssertEqual(segments[2].endTime, 150, accuracy: 0.001)   // last segment: startTime + 30s
        XCTAssertEqual(segments[2].sourceTrack, .system)
    }

    // MARK: - Format B (spec / future stt output)

    func testFormatBParsesMultiLineSpeakerSegments() throws {
        let fileURL = try writeCombinedTxt(
            """
            [00:00.240 - 00:45.680] Speaker 1:
            Привет, давайте начинать.

            [00:45.800 - 01:32.120] Speaker 2:
            Да, всем привет. Начнем с повестки.

            [01:32.500 - 01:40.000] Speaker 1:
            Первый пункт:
            синхронизация по задачам.

            [01:40.250 - 02:00.750] Speaker 3:
            Ок, я зафиксирую решения.
            """
        )

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .mic)

        XCTAssertEqual(segments.count, 4)
        XCTAssertEqual(segments[0].speaker, "Mic")
        XCTAssertEqual(segments[0].text, "Привет, давайте начинать.")
        XCTAssertEqual(segments[0].sourceTrack, .mic)
        XCTAssertEqual(segments[1].speaker, "Mic")
        XCTAssertEqual(segments[1].text, "Да, всем привет. Начнем с повестки.")
        XCTAssertEqual(segments[2].text, "Первый пункт:\nсинхронизация по задачам.")
        XCTAssertEqual(segments[3].speaker, "Mic")
        XCTAssertEqual(segments[3].text, "Ок, я зафиксирую решения.")
    }

    func testFormatBTimestampsInSeconds() throws {
        let fileURL = try writeCombinedTxt(
            """
            [00:00.240 - 00:45.680] Speaker 1:
            First.

            [01:32.500 - 01:40.000] Speaker 2:
            Second.
            """
        )

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .system)

        XCTAssertEqual(segments[0].startTime, 0.240, accuracy: 0.0001)
        XCTAssertEqual(segments[0].endTime, 45.680, accuracy: 0.0001)
        XCTAssertEqual(segments[1].startTime, 92.500, accuracy: 0.0001)
        XCTAssertEqual(segments[1].endTime, 100.000, accuracy: 0.0001)
        XCTAssertEqual(segments[1].sourceTrack, .system)
    }

    // MARK: - Plain transcription fallback

    func testPlainTextFallbackPreservesMicTranscriptWhenDiarizationIsEmpty() throws {
        let fileURL = try writeCombinedTxt(
            """
            Uhus.
            The rest of the transcript is still available.
            """
        )

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .mic)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].startTime, 0, accuracy: 0.001)
        XCTAssertEqual(segments[0].endTime, 30, accuracy: 0.001)
        XCTAssertEqual(segments[0].speaker, "Mic")
        XCTAssertEqual(segments[0].text, "Uhus.\nThe rest of the transcript is still available.")
        XCTAssertEqual(segments[0].sourceTrack, .mic)
    }

    func testPlainTextFallbackUsesUnknownSystemSpeaker() throws {
        let fileURL = try writeCombinedTxt("Plain system transcript.")

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .system)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].speaker, "Speaker A")
        XCTAssertEqual(segments[0].text, "Plain system transcript.")
        XCTAssertEqual(segments[0].sourceTrack, .system)
    }

    func testEmptyPlainTextFallbackProducesNoSegments() throws {
        let fileURL = try writeCombinedTxt(" \n\n ")

        let segments = try CombinedTxtParser().parse(fileURL: fileURL, sourceTrack: .mic)

        XCTAssertTrue(segments.isEmpty)
    }

    private func writeCombinedTxt(_ content: String) throws -> URL {
        let directoryURL = try makeTemporaryDirectory()
        let fileURL = directoryURL.appendingPathComponent("mic_combined.txt", isDirectory: false)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }
}
