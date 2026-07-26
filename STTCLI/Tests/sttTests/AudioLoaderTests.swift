import XCTest
@testable import stt

final class AudioLoaderTests: XCTestCase {
    func testLoadsMP3As16kHzMonoSamples() throws {
        let fixtureURL = fixturesURL.appendingPathComponent("short_speech.mp3")

        let samples = try AudioProcessor().loadAudioSamples(from: fixtureURL)

        XCTAssertGreaterThan(samples.count, 31_000)
        XCTAssertLessThan(samples.count, 35_000)
        XCTAssertTrue(samples.contains { abs($0) > 0.001 })
    }

    func testStillLoadsWAVAs16kHzMonoSamples() throws {
        let fixtureURL = fixturesURL.appendingPathComponent("three_speakers.wav")

        let samples = try AudioProcessor().loadAudioSamples(from: fixtureURL)

        XCTAssertEqual(samples.count, 9_645_218)
        XCTAssertTrue(samples.contains { abs($0) > 0.001 })
    }

    func testInvalidAudioThrowsInsteadOfAborting() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("invalid-\(UUID().uuidString).mp3")
        try Data("not an mp3".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try AudioProcessor().loadAudioSamples(from: url)) { error in
            XCTAssertTrue(error is AudioLoadingError)
        }
    }

    private var fixturesURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }
}
