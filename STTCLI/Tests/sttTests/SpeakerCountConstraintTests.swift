import FluidAudio
import XCTest
@testable import stt

final class SpeakerCountConstraintTests: XCTestCase {
    func testExactSpeakerCountReclustersSegments() {
        let result = DiarizationResult(segments: [
            segment("a", [1, 0], 0),
            segment("a", [0.9, 0.1], 1),
            segment("b", [0, 1], 2),
            segment("b", [0.1, 0.9], 3),
            segment("c", [-1, 0], 4),
            segment("c", [-0.9, 0.1], 5),
        ])

        let constrained = SpeakerCountConstraint.apply(to: result, exactCount: 3)

        XCTAssertEqual(Set(constrained.segments.map(\.speakerId)), Set(["1", "2", "3"]))
        XCTAssertEqual(constrained.segments.map(\.startTimeSeconds), [0, 1, 2, 3, 4, 5])
    }

    private func segment(
        _ speakerID: String,
        _ embedding: [Float],
        _ start: Float
    ) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerID,
            embedding: embedding,
            startTimeSeconds: start,
            endTimeSeconds: start + 1,
            qualityScore: 1
        )
    }
}
