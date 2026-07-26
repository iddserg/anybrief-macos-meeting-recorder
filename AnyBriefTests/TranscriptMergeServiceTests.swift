import XCTest
@testable import AnyBrief

/// Tests transcript merge rules and output files.
final class TranscriptMergeServiceTests: XCTestCase {
    func testMergeSortsSegmentsByStartTime() async {
        let service = TranscriptMergeService()

        let merged = await service.merge(
            system: [
                segment(startTime: 4.0, endTime: 5.0, speaker: "Speaker 2", text: "Second", sourceTrack: .system),
            ],
            mic: [
                segment(startTime: 1.0, endTime: 2.0, speaker: "Speaker 1", text: "First", sourceTrack: .mic),
            ]
        )

        XCTAssertEqual(merged.map(\.text), ["First", "Second"])
    }

    func testMergeKeepsOverlappingSegmentsChronological() async {
        let service = TranscriptMergeService()

        let merged = await service.merge(
            system: [
                segment(startTime: 1.5, endTime: 4.0, speaker: "Speaker 2", text: "System text", sourceTrack: .system),
            ],
            mic: [
                segment(startTime: 1.0, endTime: 3.0, speaker: "Speaker 1", text: "Mic text", sourceTrack: .mic),
            ]
        )

        XCTAssertEqual(merged, [
            segment(startTime: 1.0, endTime: 3.0, speaker: "Speaker 1", text: "Mic text", sourceTrack: .mic),
            segment(startTime: 1.5, endTime: 4.0, speaker: "Speaker 2", text: "System text", sourceTrack: .system),
        ])
    }

    func testMergeKeepsMultipleMicSegmentsChronologicalInsideLongSystemSegment() async {
        let service = TranscriptMergeService()

        let merged = await service.merge(
            system: [
                segment(startTime: 10.0, endTime: 40.0, speaker: "Speaker 2", text: "Long system", sourceTrack: .system),
            ],
            mic: [
                segment(startTime: 12.0, endTime: 15.0, speaker: "Speaker 1", text: "Mic first", sourceTrack: .mic),
                segment(startTime: 18.0, endTime: 20.0, speaker: "Speaker 1", text: "Mic second", sourceTrack: .mic),
                segment(startTime: 30.0, endTime: 35.0, speaker: "Speaker 1", text: "Mic third", sourceTrack: .mic),
            ]
        )

        XCTAssertEqual(merged.map(\.text), ["Long system", "Mic first", "Mic second", "Mic third"])
        XCTAssertEqual(merged.map(\.startTime), [10.0, 12.0, 18.0, 30.0])
    }

    func testMergeKeepsBothForIdenticalTextInSameWindow() async {
        let service = TranscriptMergeService()

        let merged = await service.merge(
            system: [
                segment(startTime: 1.0, endTime: 2.0, speaker: "Speaker 2", text: "Same text", sourceTrack: .system),
            ],
            mic: [
                segment(startTime: 1.0, endTime: 2.0, speaker: "Speaker 1", text: "Same text", sourceTrack: .mic),
            ]
        )

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].sourceTrack, .system)
        XCTAssertEqual(merged[1].sourceTrack, .mic)
        XCTAssertEqual(merged[0].text, "Same text")
        XCTAssertEqual(merged[1].text, "Same text")
    }

    func testWriteCreatesPlainTextAndMergedJsonFiles() async throws {
        let service = TranscriptMergeService()
        let meetingFolder = try makeTemporaryDirectory()

        let merged = try await service.write(
            system: [
                segment(startTime: 1.2, endTime: 2.0, speaker: "Speaker 2", text: "System", sourceTrack: .system),
            ],
            mic: [
                segment(startTime: 3.5, endTime: 4.0, speaker: "Speaker 1", text: "Mic", sourceTrack: .mic),
            ],
            meetingFolder: meetingFolder
        )

        XCTAssertEqual(merged.map(\.text), ["System", "Mic"])

        let text = try String(
            contentsOf: meetingFolder.appendingPathComponent("transcript.txt", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertEqual(
            text,
            """
            [00:00:01.200] Speaker 2: System
            [00:00:03.500] Speaker 1: Mic

            """
        )

        let jsonData = try Data(
            contentsOf: meetingFolder.appendingPathComponent("transcript_merged.json", isDirectory: false)
        )
        let decoded = try JSONDecoder().decode([TranscriptSegment].self, from: jsonData)
        XCTAssertEqual(decoded, merged)
    }

    func testWriteCollapsesMultilineTextToOneLine() async throws {
        let service = TranscriptMergeService()
        let meetingFolder = try makeTemporaryDirectory()

        _ = try await service.write(
            system: [
                segment(startTime: 1.0, endTime: 3.0, speaker: "Speaker 1",
                        text: "First point:\nsync on tasks.", sourceTrack: .system),
            ],
            mic: [],
            meetingFolder: meetingFolder
        )

        let text = try String(
            contentsOf: meetingFolder.appendingPathComponent("transcript.txt", isDirectory: false),
            encoding: .utf8
        )
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        // One segment → exactly one line in transcript.txt, newlines in text collapsed to space
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0], "[00:00:01.000] Speaker 1: First point: sync on tasks.")
    }

    private func segment(
        startTime: TimeInterval,
        endTime: TimeInterval,
        speaker: String,
        text: String,
        sourceTrack: SourceTrack
    ) -> TranscriptSegment {
        TranscriptSegment(
            startTime: startTime,
            endTime: endTime,
            speaker: speaker,
            text: text,
            sourceTrack: sourceTrack
        )
    }
}
