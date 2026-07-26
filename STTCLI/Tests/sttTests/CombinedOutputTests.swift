import FluidAudio
import XCTest
@testable import stt

final class CombinedOutputTests: XCTestCase {
    func testAlignsWordsByTimestampAndPreservesPunctuation() {
        let words = [
            word("Привет", 1.0, 1.4),
            word(",", 1.4, 1.5),
            word("коллеги", 1.5, 2.0),
            word("Ответ", 3.1, 3.5),
            word(".", 3.5, 3.6),
        ]
        let diarization = DiarizationResult(segments: [
            segment("10", 0.8, 0.5, 2.5),
            segment("20", 0.9, 3.0, 4.0),
        ])

        let output = AudioProcessor().combineTranscriptionWithDiarization(
            wordTimings: words,
            diarizationResult: diarization
        )

        XCTAssertEqual(output, """
        [00:01] Speaker A: Привет, коллеги
        [00:03] Speaker B: Ответ.
        """)
    }

    func testContainingSegmentPrefersHigherQualityWhenSpeakersOverlap() {
        let diarization = DiarizationResult(segments: [
            segment("1", 0.2, 0, 3),
            segment("2", 0.9, 1, 2),
        ])

        let output = AudioProcessor().combineTranscriptionWithDiarization(
            wordTimings: [word("Да", 1.2, 1.6)],
            diarizationResult: diarization
        )

        XCTAssertEqual(output, "[00:01] Speaker B: Да")
    }

    func testUsesNearestSegmentForWordInShortDiarizationGap() {
        let diarization = DiarizationResult(segments: [
            segment("1", 1, 0, 1),
            segment("2", 1, 2, 3),
        ])

        let output = AudioProcessor().combineTranscriptionWithDiarization(
            wordTimings: [word("рядом", 1.7, 1.9)],
            diarizationResult: diarization
        )

        XCTAssertEqual(output, "[00:01] Speaker B: рядом")
    }

    func testLeavesWordUnknownWhenNoDiarizationIsNearby() {
        let diarization = DiarizationResult(segments: [
            segment("1", 1, 0, 1)
        ])

        let output = AudioProcessor().combineTranscriptionWithDiarization(
            wordTimings: [word("далеко", 10, 11)],
            diarizationResult: diarization
        )

        XCTAssertEqual(output, "[00:10] Speaker Unknown: далеко")
    }

    func testSplitsSameSpeakerAfterLongPause() {
        let diarization = DiarizationResult(segments: [
            segment("1", 1, 0, 1),
            segment("1", 1, 5, 6),
        ])

        let output = AudioProcessor().combineTranscriptionWithDiarization(
            wordTimings: [
                word("раз", 0.2, 0.5),
                word("два", 5.2, 5.5),
            ],
            diarizationResult: diarization,
            maximumJoinGap: 2
        )

        XCTAssertEqual(output, """
        [00:00] Speaker A: раз
        [00:05] Speaker A: два
        """)
    }

    func testPreservesTimingWithoutDiarization() {
        let output = AudioProcessor().combineTranscriptionWithoutDiarization(
            wordTimings: [
                word("Первая", 1.0, 1.4),
                word("фраза", 1.4, 2.0),
                word("Вторая", 6.0, 6.5),
            ]
        )

        XCTAssertEqual(output, """
        [00:01] Speaker A: Первая фраза
        [00:06] Speaker A: Вторая
        """)
    }

    func testVocabularyAliasesPreserveTiming() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vocabulary-\(UUID().uuidString).txt"
        )
        defer { try? FileManager.default.removeItem(at: url) }
        try "MGCom: сам же ком".write(to: url, atomically: true, encoding: .utf8)
        let vocabulary = try RecognitionVocabulary(contentsOf: url)

        let output = AudioProcessor().combineTranscriptionWithoutDiarization(
            wordTimings: vocabulary.applyingAliases(to: [
                word("сам", 1.0, 1.2),
                word("же", 1.2, 1.4),
                word("ком", 1.4, 1.8),
            ])
        )

        XCTAssertEqual(output, "[00:01] Speaker A: MGCom")
    }

    private func word(_ text: String, _ start: Double, _ end: Double) -> WordTiming {
        WordTiming(word: text, startTime: start, endTime: end)
    }

    private func segment(
        _ speakerID: String,
        _ quality: Float,
        _ start: Float,
        _ end: Float
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerID,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: quality
        )
    }
}
