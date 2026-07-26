import XCTest
@testable import WhisperSTTCore

final class WhisperSTTCoreTests: XCTestCase {
    func testUsesDefaultDiarizationThreshold() throws {
        let options = try XCTUnwrap(WhisperSTTArguments.parse([
            "/tmp/meeting.wav",
            "--model=/tmp/model.bin",
        ], environment: [:]))

        XCTAssertEqual(options.threshold, 0.65)
    }

    func testParsesCompatibleArguments() throws {
        let options = try XCTUnwrap(WhisperSTTArguments.parse([
            "/tmp/meeting.wav",
            "--output=/tmp/out",
            "--model=/tmp/model.bin",
            "--language=ru",
            "--threshold=0.35",
            "--speakers=3",
            "--threads=6",
            "--no-gpu",
        ], environment: [:]))

        XCTAssertEqual(options.outputDirectory, "/tmp/out")
        XCTAssertEqual(options.language, "ru")
        XCTAssertEqual(options.threshold, 0.35)
        XCTAssertEqual(options.speakers, 3)
        XCTAssertEqual(options.threads, 6)
        XCTAssertTrue(options.noGPU)
    }

    func testParsesMaximumSpeakerCount() throws {
        let options = try XCTUnwrap(WhisperSTTArguments.parse([
            "/tmp/meeting.wav",
            "--model=/tmp/model.bin",
            "--speaker-max=4",
        ], environment: [:]))

        XCTAssertEqual(options.speakers, -1)
        XCTAssertEqual(options.speakerMax, 4)
    }

    func testParsesVADModel() throws {
        let options = try XCTUnwrap(WhisperSTTArguments.parse([
            "/tmp/meeting.wav",
            "--model=/tmp/model.bin",
            "--vad-model=/tmp/silero.bin",
        ], environment: [:]))

        XCTAssertEqual(options.vadModelPath, "/tmp/silero.bin")
    }

    func testWhisperCoreArgumentsEnableSileroVAD() {
        var options = WhisperSTTOptions(
            inputFile: "/tmp/meeting.wav",
            model: "/tmp/model.bin"
        )
        options.language = "ru"

        let arguments = WhisperSTTRunner.makeWhisperCoreArguments(
            inputURL: URL(fileURLWithPath: options.inputFile),
            modelURL: URL(fileURLWithPath: options.model),
            outputPrefix: URL(fileURLWithPath: "/tmp/meeting_whisper"),
            options: options,
            vadModelURL: URL(fileURLWithPath: "/tmp/silero.bin"),
            prompt: nil
        )

        XCTAssertTrue(arguments.contains("--vad"))
        XCTAssertEqual(
            Array(arguments.suffix(from: arguments.firstIndex(of: "--vad")!)),
            ["--vad", "--vad-model", "/tmp/silero.bin"]
        )
    }

    func testRejectsExactAndMaximumSpeakerCountTogether() {
        XCTAssertThrowsError(try WhisperSTTArguments.parse([
            "/tmp/meeting.wav",
            "--model=/tmp/model.bin",
            "--speakers=3",
            "--speaker-max=4",
        ], environment: [:]))
    }

    func testAssignsTimestampedWordsToFluidAudioSpeakers() throws {
        let whisper = try JSONDecoder().decode(WhisperDocument.self, from: Data("""
        {
          "transcription": [{
            "offsets":{"from":0,"to":4000},
            "text":" Hello there. General Kenobi.",
            "tokens":[
              {"text":" Hello","offsets":{"from":200,"to":900}},
              {"text":" there","offsets":{"from":900,"to":1500}},
              {"text":".","offsets":{"from":1500,"to":1600}},
              {"text":" General","offsets":{"from":2200,"to":2900}},
              {"text":" Kenobi","offsets":{"from":2900,"to":3700}},
              {"text":".","offsets":{"from":3700,"to":3800}}
            ]
          }]
        }
        """.utf8))
        let diarization = DiarizationDocument(
            duration: 4,
            segments: [
                .init(start: 0, end: 2, speaker: "0", quality: 0.9),
                .init(start: 2, end: 4, speaker: "1", quality: 0.9),
            ]
        )

        XCTAssertEqual(TemporalMerger().merge(whisper: whisper, diarization: diarization), [
            SpeakerTurn(start: 0.2, end: 1.6, speaker: "Speaker A", text: "Hello there."),
            SpeakerTurn(start: 2.2, end: 3.8, speaker: "Speaker B", text: "General Kenobi."),
        ])
    }

    func testRestoresOriginalTokenTimelineAfterVADCompaction() throws {
        let document = try JSONDecoder().decode(WhisperDocument.self, from: Data("""
        {
          "transcription": [
            {
              "offsets":{"from":10000,"to":12000},
              "text":" First phrase.",
              "tokens":[
                {"text":" First","offsets":{"from":0,"to":1000}},
                {"text":" phrase","offsets":{"from":1000,"to":1900}},
                {"text":".","offsets":{"from":1900,"to":2000}}
              ]
            },
            {
              "offsets":{"from":20000,"to":22000},
              "text":" Second phrase.",
              "tokens":[
                {"text":" Second","offsets":{"from":2000,"to":3000}},
                {"text":" phrase","offsets":{"from":3000,"to":3900}},
                {"text":".","offsets":{"from":3900,"to":4000}}
              ]
            }
          ]
        }
        """.utf8))

        XCTAssertEqual(TemporalMerger().timedText(from: document), [
            TimedText(start: 10, end: 11, text: "First"),
            TimedText(start: 11, end: 12, text: "phrase."),
            TimedText(start: 20, end: 21, text: "Second"),
            TimedText(start: 21, end: 22, text: "phrase."),
        ])
    }

    func testTranscribeOnlyWritesCombinedOutputForAppParser() throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory.appendingPathComponent(
            "whisper-transcribe-only-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let inputURL = directory.appendingPathComponent("meeting.mp3")
        let modelURL = directory.appendingPathComponent("model.bin")
        let whisperJSONURL = directory.appendingPathComponent("whisper.json")
        try Data().write(to: inputURL)
        try Data().write(to: modelURL)
        try Data("""
        {
          "transcription": [{
            "offsets":{"from":0,"to":1000},
            "text":" Hello world.",
            "tokens":[
              {"text":" Hello","offsets":{"from":0,"to":500}},
              {"text":" world","offsets":{"from":500,"to":900}},
              {"text":".","offsets":{"from":900,"to":1000}}
            ]
          }]
        }
        """.utf8).write(to: whisperJSONURL)

        var options = WhisperSTTOptions(inputFile: inputURL.path, model: modelURL.path)
        options.outputDirectory = directory.path
        options.transcribeOnly = true
        options.whisperJSONPath = whisperJSONURL.path

        try WhisperSTTRunner().run(
            options: options,
            ownExecutableURL: directory.appendingPathComponent("whisper-stt")
        )

        let combinedURL = directory.appendingPathComponent("meeting_combined.txt")
        XCTAssertTrue(fileManager.fileExists(atPath: combinedURL.path))
        XCTAssertEqual(
            try String(contentsOf: combinedURL, encoding: .utf8),
            "[00:00] Speaker A: Hello world."
        )
    }

    func testTurnsWithoutDiarizationPreserveLongPauses() throws {
        let document = try JSONDecoder().decode(WhisperDocument.self, from: Data("""
        {
          "transcription": [
            {
              "offsets":{"from":1000,"to":2000},
              "text":" First phrase.",
              "tokens":null
            },
            {
              "offsets":{"from":6000,"to":7000},
              "text":" Second phrase.",
              "tokens":null
            }
          ]
        }
        """.utf8))

        let merger = TemporalMerger(maximumJoinGap: 2)
        XCTAssertEqual(
            merger.combinedText(from: merger.turnsWithoutDiarization(from: document)),
            """
            [00:01] Speaker A: First phrase.
            [00:06] Speaker A: Second phrase.
            """
        )
    }

    func testRecognitionVocabularyBuildsPromptAndAppliesAliases() {
        let vocabulary = RecognitionVocabulary(text: """
        Admon
        MGCom: сам же ком, эм-джи-ком
        """)

        XCTAssertEqual(vocabulary.prompt, "Admon, MGCom")
        XCTAssertEqual(
            vocabulary.applyingAliases(to: "Обсудили Сам же ком и эм-джи-ком."),
            "Обсудили MGCom и MGCom."
        )
    }
}
