import XCTest
@testable import AnyBrief

final class PostProcessingServiceTests: XCTestCase {
    private var sandboxURL: URL!

    override func setUpWithError() throws {
        sandboxURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sandboxURL, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let sandboxURL, FileManager.default.fileExists(atPath: sandboxURL.path) {
            try FileManager.default.removeItem(at: sandboxURL)
        }
    }

    func testOverwriteCannotDeleteSourceThroughSamePathOrSymlink() async throws {
        let meeting = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
        let source = meeting.appendingPathComponent("summary.md")
        let original = "# Original summary\n"
        try original.write(to: source, atomically: true, encoding: .utf8)
        let alias = sandboxURL.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: meeting)
        for destination in [meeting, alias] {
            let rule = PostProcessingRuleConfiguration(
                title: "Self export", calendarTitlePattern: "meeting",
                destinationFolderPath: destination.path, filenameTemplate: "summary.md",
                conflictBehavior: .overwrite
            )
            let result = await PostProcessingService().export(
                from: meeting, settings: PostProcessingSettings(enabled: true, rules: [rule]), ruleID: rule.id
            )
            XCTAssertEqual(result.status, .failed)
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
        }
    }

    func testMatchesContainsTitleIgnoringColonAndCase() {
        let rule = PostProcessingRuleConfiguration(
            title: "WEB Media",
            calendarTitlePattern: "[WEB, Media] Admon Anti-fraud products",
            destinationFolderPath: "/tmp"
        )

        XCTAssertTrue(PostProcessingService.matches(
            title: "[WEB, Media] Admon: Anti-fraud products (разработка продуктов антифрода)",
            rule: rule
        ))
    }

    func testExportCopiesOnlySummaryMarkdownToExistingDestination() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try """
        ---
        title: test
        ---

        ## Цель встречи
        Обсудить антифрод витрину
        """.write(to: meetingURL.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
        try "transcript".write(to: meetingURL.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)

        let rule = PostProcessingRuleConfiguration(
            title: "WEB Media",
            calendarTitlePattern: "[WEB, Media] Admon Anti-fraud products",
            destinationFolderPath: destinationURL.path
        )
        let settings = PostProcessingSettings(enabled: true, rules: [rule])
        let service = PostProcessingService()

        let result = await service.exportIfNeeded(
            from: meetingURL,
            settings: settings,
            calendarEvent: calendarEvent(title: "[WEB, Media] Admon: Anti-fraud products")
        )

        XCTAssertEqual(result.status, .exported)
        let files = try FileManager.default.contentsOfDirectory(atPath: destinationURL.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files.first, "2026-06-22 [WEB, Media] Admon - Anti-fraud products — summary — Обсудить антифрод витрину.md")
        let copiedSummary = try String(contentsOf: destinationURL.appendingPathComponent(files[0]), encoding: .utf8)
        XCTAssertTrue(copiedSummary.contains("Обсудить антифрод витрину"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.appendingPathComponent("transcript.txt").path))
    }

    func testExportSkipsWhenDestinationFileAlreadyExists() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "Summary body".write(to: meetingURL.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

        let filename = "2026-06-22 Продуктовый комитет — summary — Summary body.md"
        try "existing".write(to: destinationURL.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        let rule = PostProcessingRuleConfiguration(
            title: "Продуктовый комитет",
            calendarTitlePattern: "Продуктовый комитет",
            destinationFolderPath: destinationURL.path
        )

        let result = await PostProcessingService().exportIfNeeded(
            from: meetingURL,
            settings: PostProcessingSettings(enabled: true, rules: [rule]),
            calendarEvent: calendarEvent(title: "Продуктовый комитет")
        )

        XCTAssertEqual(result.status, .skipped)
        let existing = try String(contentsOf: destinationURL.appendingPathComponent(filename), encoding: .utf8)
        XCTAssertEqual(existing, "existing")
    }

    func testExportSkipsPartialSuccessSummary() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try """
        ---
        status: partial_success
        summary_error: summary_api_failed
        ---
        ## Summary
        Черновик - summary недоступен
        ## Transcript
        Raw transcript
        """.write(to: meetingURL.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)

        let rule = PostProcessingRuleConfiguration(
            title: "Продуктовый комитет",
            calendarTitlePattern: "Продуктовый комитет",
            destinationFolderPath: destinationURL.path
        )

        let result = await PostProcessingService().exportIfNeeded(
            from: meetingURL,
            settings: PostProcessingSettings(enabled: true, rules: [rule]),
            calendarEvent: calendarEvent(title: "Продуктовый комитет")
        )

        XCTAssertEqual(result.status, .skipped)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty)
    }

    func testExportCopiesSummaryAndTranscriptWithTypeToken() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "Summary body".write(
            to: meetingURL.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Transcript body".write(
            to: meetingURL.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        let rule = PostProcessingRuleConfiguration(
            title: "Продуктовый комитет",
            calendarTitlePattern: "Продуктовый комитет",
            destinationFolderPath: destinationURL.path,
            exportContent: .both,
            filenameTemplate: "{date} {calendarTitle} {type}.md"
        )

        let result = await PostProcessingService().exportIfNeeded(
            from: meetingURL,
            settings: PostProcessingSettings(enabled: true, rules: [rule]),
            calendarEvent: calendarEvent(title: "Продуктовый комитет")
        )

        XCTAssertEqual(result.status, .exported)
        XCTAssertEqual(
            Set(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path)),
            [
                "2026-06-22 Продуктовый комитет summary.md",
                "2026-06-22 Продуктовый комитет transcript.md",
            ]
        )
        XCTAssertEqual(
            Set(PostProcessingService.recordedDestinationURLs(from: meetingURL)),
            Set([
                destinationURL.appendingPathComponent("2026-06-22 Продуктовый комитет summary.md"),
                destinationURL.appendingPathComponent("2026-06-22 Продуктовый комитет transcript.md"),
            ])
        )
    }

    func testRecordedDestinationURLsDropsDeletedExports() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "Transcript body".write(
            to: meetingURL.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        let exportedURL = destinationURL.appendingPathComponent("Sync transcript.md")
        let rule = PostProcessingRuleConfiguration(
            title: "Sync",
            calendarTitlePattern: "Sync",
            destinationFolderPath: destinationURL.path,
            exportContent: .transcript,
            filenameTemplate: "{calendarTitle} {type}.md"
        )

        _ = await PostProcessingService().exportIfNeeded(
            from: meetingURL,
            settings: PostProcessingSettings(enabled: true, rules: [rule]),
            calendarEvent: calendarEvent(title: "Sync")
        )
        XCTAssertEqual(PostProcessingService.recordedDestinationURLs(from: meetingURL), [exportedURL])

        try FileManager.default.removeItem(at: exportedURL)

        XCTAssertTrue(PostProcessingService.recordedDestinationURLs(from: meetingURL).isEmpty)
    }

    func testTranscriptOnlyExportWorksWithoutSummary() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "Transcript body".write(
            to: meetingURL.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        let rule = PostProcessingRuleConfiguration(
            title: "Sync",
            calendarTitlePattern: "Sync",
            destinationFolderPath: destinationURL.path,
            exportContent: .transcript,
            filenameTemplate: "{calendarTitle} {type}.md"
        )

        let result = await PostProcessingService().exportIfNeeded(
            from: meetingURL,
            settings: PostProcessingSettings(enabled: true, rules: [rule]),
            calendarEvent: calendarEvent(title: "Sync")
        )

        XCTAssertEqual(result.status, .exported)
        XCTAssertEqual(
            try String(contentsOf: destinationURL.appendingPathComponent("Sync transcript.md"), encoding: .utf8),
            "Transcript body"
        )
    }

    func testBothExportRequiresTypeTokenToAvoidFilenameCollision() async throws {
        let meetingURL = sandboxURL.appendingPathComponent("meeting", isDirectory: true)
        let destinationURL = sandboxURL.appendingPathComponent("drive", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        try "Summary".write(
            to: meetingURL.appendingPathComponent("summary.md"),
            atomically: true,
            encoding: .utf8
        )
        try "Transcript".write(
            to: meetingURL.appendingPathComponent("transcript.txt"),
            atomically: true,
            encoding: .utf8
        )
        let rule = PostProcessingRuleConfiguration(
            title: "Sync",
            calendarTitlePattern: "Sync",
            destinationFolderPath: destinationURL.path,
            exportContent: .both,
            filenameTemplate: "{calendarTitle}.md"
        )

        let result = await PostProcessingService().exportIfNeeded(
            from: meetingURL,
            settings: PostProcessingSettings(enabled: true, rules: [rule]),
            calendarEvent: calendarEvent(title: "Sync")
        )

        XCTAssertEqual(result.status, .failed)
        XCTAssertTrue(result.message.contains("{type}"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destinationURL.path).isEmpty)
    }

    func testLegacyRuleDefaultsToSummaryExport() throws {
        let data = Data("""
        {
          "id": "legacy",
          "title": "Legacy",
          "enabled": true,
          "matchMode": "contains",
          "calendarTitlePattern": "Legacy",
          "destinationFolderPath": "/tmp",
          "filenameTemplate": "{date}.md",
          "conflictBehavior": "skip"
        }
        """.utf8)

        let rule = try JSONDecoder().decode(PostProcessingRuleConfiguration.self, from: data)

        XCTAssertEqual(rule.exportContent, .summary)
    }

    private func calendarEvent(title: String) -> CalendarEvent {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(identifier: "Asia/Novosibirsk")
        components.year = 2026
        components.month = 6
        components.day = 22
        components.hour = 10
        let start = components.date!
        return CalendarEvent(
            uid: UUID().uuidString,
            originalUID: UUID().uuidString,
            calendarName: "Work",
            title: title,
            startAt: start,
            endAt: start.addingTimeInterval(3_600),
            timeZone: "Asia/Novosibirsk",
            location: nil,
            notes: nil,
            organizer: nil,
            attendees: [],
            meetingURLs: [],
            participantCount: 0,
            hasMeetingURL: false,
            recurrenceRule: nil,
            recurrenceID: nil
        )
    }
}
