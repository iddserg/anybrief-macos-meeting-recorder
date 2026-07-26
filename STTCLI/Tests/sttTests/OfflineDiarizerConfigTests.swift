import XCTest
@testable import stt

final class OfflineDiarizerConfigTests: XCTestCase {
    func testAutoSpeakerCountLeavesOfflineClusteringUnconstrained() {
        let processor = AudioProcessor()

        let config = processor.makeOfflineDiarizerConfig(
            threshold: 0.65,
            numClusters: -1
        )

        XCTAssertEqual(config.clustering.threshold, 0.65)
        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
        XCTAssertEqual(config.segmentation.stepRatio, 0.1)
        XCTAssertEqual(config.embedding.minSegmentDurationSeconds, 0)
        XCTAssertTrue(config.zeroVoteReembed.enabled)
    }

    func testExactSpeakerCountUsesOfflineClusteringConstraint() {
        let processor = AudioProcessor()

        let config = processor.makeOfflineDiarizerConfig(
            threshold: 0.65,
            numClusters: 3
        )

        XCTAssertEqual(config.clustering.numSpeakers, 3)
        XCTAssertNil(config.clustering.minSpeakers)
        XCTAssertNil(config.clustering.maxSpeakers)
    }

    func testMaximumSpeakerCountAllowsFewerSpeakers() {
        let processor = AudioProcessor()

        let config = processor.makeOfflineDiarizerConfig(
            threshold: 0.65,
            numClusters: -1,
            maxClusters: 4
        )

        XCTAssertNil(config.clustering.numSpeakers)
        XCTAssertEqual(config.clustering.minSpeakers, 1)
        XCTAssertEqual(config.clustering.maxSpeakers, 4)
    }

    func testMaximumOfOneSpeakerIsAValidConstraint() {
        let processor = AudioProcessor()

        let config = processor.makeOfflineDiarizerConfig(
            threshold: 0.65,
            numClusters: -1,
            maxClusters: 1
        )

        XCTAssertEqual(config.clustering.minSpeakers, 1)
        XCTAssertEqual(config.clustering.maxSpeakers, 1)
        XCTAssertNoThrow(try config.validate())
    }

    func testZeroThresholdRemainsAcceptedByCLIContract() {
        let processor = AudioProcessor()

        let config = processor.makeOfflineDiarizerConfig(
            threshold: 0,
            numClusters: -1
        )

        XCTAssertGreaterThan(config.clustering.threshold, 0)
        XCTAssertNoThrow(try config.validate())
    }
}
