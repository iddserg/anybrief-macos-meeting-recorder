import AVFoundation
import Darwin
import XCTest
@testable import AnyBrief

/// Tests summary API requests and `summary.md` formatting.
final class SummarizationServiceTests: XCTestCase {
    func testSummarizePostsOpenAICompatibleRequest() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
            capturedRequest = request
            if let body = request.httpBodyStream.flatMap(Self.data(from:)) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }

            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"## Summary\\nDone\"}}]}"
                .data(using: .utf8)!
            return (response, data)
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            Self.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        settings.setTestSummaryPrompt("Write a short summary.")

        let summary = try await service.summarize(transcript: "hello transcript", settings: settings)

        XCTAssertEqual(summary, "## Summary\nDone")
        XCTAssertEqual(capturedRequest?.httpMethod, "POST")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(capturedBody?["model"] as? String, "gpt-test")

        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0], ["role": "system", "content": "Write a short summary."])
        XCTAssertEqual(messages[1], ["role": "user", "content": "hello transcript"])
    }

    func testSummarizeUsesLocalOllamaWithoutAuthorizationHeader() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
            capturedRequest = request
            if let body = request.httpBodyStream.flatMap(Self.data(from:)) {
                capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
            }
            return (
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                try Self.ollamaResponseData(content: "local ok")
            )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [Self.ollamaConfiguration(model: "llama3.2:latest")]

        let summary = try await service.summarize(transcript: "hello transcript", settings: settings)

        XCTAssertEqual(summary, "local ok")
        XCTAssertEqual(capturedRequest?.url?.absoluteString, OllamaDefaults.chatURLString)
        XCTAssertNil(capturedRequest?.value(forHTTPHeaderField: "Authorization"))
        let options = try XCTUnwrap(capturedBody?["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 32_768)
    }

    func testSummarizeUsesPromptForSelectedProvider() async throws {
        var capturedSystemPrompt = ""
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                capturedSystemPrompt = messages?.first?["content"] ?? ""
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: "local ok")
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [Self.ollamaConfiguration(model: "llama3.2:latest")]
        settings.setTestSummaryPrompt("Ollama prompt")

        _ = try await service.summarize(transcript: "hello transcript", settings: settings)

        XCTAssertEqual(capturedSystemPrompt, "Ollama prompt")
    }

    func testSummarizeSelectsPromptByMeetingTitlePattern() async throws {
        var capturedSystemPrompt = ""
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                capturedSystemPrompt = messages?.first?["content"] ?? ""
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: "local ok")
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [Self.ollamaConfiguration(model: "llama3.2:latest")]
        settings.prompts.items = [
            PromptItem(id: "assigned", name: "Assigned", text: "Assigned prompt"),
            PromptItem(id: "standup", name: "Standup", text: "Standup prompt", titlePatterns: ["standup"]),
        ]
        settings.prompts.summary.promptID = "assigned"

        _ = try await service.summarize(
            transcript: "hello transcript",
            settings: settings,
            meetingTitle: "Weekly STANDUP with team"
        )
        XCTAssertEqual(capturedSystemPrompt, "Standup prompt")

        _ = try await service.summarize(
            transcript: "hello transcript",
            settings: settings,
            meetingTitle: "Budget review"
        )
        XCTAssertEqual(capturedSystemPrompt, "Assigned prompt")
    }

    func testCleanupTranscriptUsesCleanupPromptAndConnections() async throws {
        var capturedSystemPrompt = ""
        var capturedModel: String?
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                capturedSystemPrompt = messages?.first?["content"] ?? ""
                capturedModel = body?["model"] as? String
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: "cleaned transcript")
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            Self.ollamaConfiguration(model: "summary-model"),
            Self.ollamaConfiguration(model: "cleanup-model"),
        ]
        settings.prompts.items = [
            PromptItem(id: "cleanup", name: "Cleanup", text: "Cleanup prompt"),
        ]
        settings.prompts.transcriptCleanup.promptID = "cleanup"
        settings.prompts.transcriptCleanup.connectionIDs = [settings.llm.connections[1].id]

        let cleaned = try await service.cleanupTranscript(transcript: "raw transcript", settings: settings)

        XCTAssertEqual(cleaned, "cleaned transcript")
        XCTAssertEqual(capturedSystemPrompt, "Cleanup prompt")
        XCTAssertEqual(capturedModel, "cleanup-model")
    }

    func testTranscriptCleanupInputPrefixesCalendarFrontmatter() async {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let event = Self.calendarEvent(title: "Sync with Alice")

        let withEvent = await service.transcriptCleanupInput(
            transcript: "[ 0m0s ] Speaker 1: hello",
            calendarEvent: event
        )
        XCTAssertTrue(withEvent.contains("Sync with Alice"))
        XCTAssertTrue(withEvent.hasSuffix("[ 0m0s ] Speaker 1: hello"))

        let withoutEvent = await service.transcriptCleanupInput(
            transcript: "[ 0m0s ] Speaker 1: hello",
            calendarEvent: nil
        )
        XCTAssertEqual(withoutEvent, "[ 0m0s ] Speaker 1: hello")
    }

    func testLLMChainsFallBackToAutoWhenSelectionIsEmptyOrDangling() {
        var settings = AppSettings.default
        let first = Self.ollamaConfiguration(model: "first")
        var second = Self.openAIConfiguration(model: "second", apiKeyRef: "summary-key")
        second.enabled = false
        settings.llm.connections = [first, second]

        // Empty selection = Auto: all enabled connections in pool order.
        XCTAssertEqual(settings.transcriptCleanupLLMChain.map(\.id), [first.id])
        XCTAssertEqual(settings.liveLLMChain.map(\.id), [first.id])

        // Explicit selection uses only that connection.
        settings.prompts.transcriptCleanup.connectionIDs = [first.id]
        settings.prompts.live.connectionID = first.id
        XCTAssertEqual(settings.transcriptCleanupLLMChain.map(\.id), [first.id])
        XCTAssertEqual(settings.liveLLMConnection?.id, first.id)

        // Dangling or disabled selections fall back to Auto.
        settings.prompts.transcriptCleanup.connectionIDs = ["missing-id"]
        settings.prompts.live.connectionID = second.id
        XCTAssertEqual(settings.transcriptCleanupLLMChain.map(\.id), [first.id])
        XCTAssertNil(settings.liveLLMConnection)
        XCTAssertEqual(settings.liveLLMChain.map(\.id), [first.id])
    }

    func testLLMServiceProcessesTextWithExplicitPromptAndConnection() async throws {
        var capturedRequest: URLRequest?
        var capturedBody: [String: Any]?
        let service = LLMService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
                capturedRequest = request
                if let body = request.httpBodyStream.flatMap(Self.data(from:)) {
                    capturedBody = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.summaryResponseData(content: "live output")
                )
            }
        )

        var settings = AppSettings.default
        let connection = Self.openAIConfiguration(model: "gpt-live", apiKeyRef: "summary-key")
        settings.llm.connections = [connection]
        settings.setTestSummaryPrompt("Stored summary prompt")

        let output = try await service.process(
            text: "live transcript text",
            prompt: "Live prompt",
            connections: [connection],
            settings: settings
        )

        XCTAssertEqual(output.text, "live output")
        XCTAssertEqual(capturedRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
        XCTAssertEqual(capturedBody?["model"] as? String, "gpt-live")
        let messages = try XCTUnwrap(capturedBody?["messages"] as? [[String: String]])
        XCTAssertEqual(messages[0], ["role": "system", "content": "Live prompt"])
        XCTAssertEqual(messages[1], ["role": "user", "content": "live transcript text"])
    }

    func testLLMServiceReportsConnectionFallbackProgress() async throws {
        let service = LLMService(
            keychainStore: MockKeychainStore(values: [
                "first-key": "first-secret",
                "second-key": "second-secret",
            ]),
            session: Self.mockSession { request in
                if request.url?.host == "first.example" {
                    return (
                        HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil)!,
                        Data()
                    )
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.summaryResponseData(content: "fallback output")
                )
            }
        )

        var first = Self.openAIConfiguration(
            model: "first-model",
            apiKeyRef: "first-key",
            apiURL: "https://first.example/v1/chat/completions"
        )
        first.name = "First"
        first.retryCount = 1
        var second = Self.openAIConfiguration(
            model: "second-model",
            apiKeyRef: "second-key",
            apiURL: "https://second.example/v1/chat/completions"
        )
        second.name = "Second"
        second.retryCount = 1
        var settings = AppSettings.default
        settings.llm.connections = [first, second]

        var events: [LLMProgressEvent] = []
        let output = try await service.process(
            text: "transcript",
            prompt: "prompt",
            connections: [first, second],
            settings: settings,
            progress: { event in
                events.append(event)
            }
        )

        XCTAssertEqual(output.text, "fallback output")
        XCTAssertEqual(events.map(\.connectionName), ["First", "First", "Second", "Second"])
        XCTAssertEqual(events.map(\.connectionIndex), [1, 1, 2, 2])
        XCTAssertNil(events[0].fallbackFrom)
        XCTAssertEqual(events[2].fallbackFrom, "First")
        guard case .started = events[0].kind else {
            return XCTFail("Expected the first connection to start.")
        }
        guard case .failed = events[1].kind else {
            return XCTFail("Expected the first connection to fail.")
        }
        guard case .started = events[2].kind else {
            return XCTFail("Expected the fallback connection to start.")
        }
        guard case .completed = events[3].kind else {
            return XCTFail("Expected the fallback connection to complete.")
        }
    }

    func testSummarizeAppendsSpeakerContextToSystemPrompt() async throws {
        var capturedSystemPrompt = ""
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                capturedSystemPrompt = messages?.first?["content"] ?? ""
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.summaryResponseData(content: "## Summary\nDone")
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            Self.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        settings.setTestSummaryPrompt("Write a short summary.")
        settings.setTestSpeakerContext("Mic = Sergey Ignatov, CTO")

        _ = try await service.summarize(transcript: "hello transcript", settings: settings)

        XCTAssertEqual(
            capturedSystemPrompt,
            """
            Write a short summary.

            Additional speaker context:
            Mic = Sergey Ignatov, CTO
            """
        )
    }

    func testSummarizeSubstitutesPromptLanguageVariable() async throws {
        var capturedSystemPrompt = ""
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                capturedSystemPrompt = messages?.first?["content"] ?? ""
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: "local ok")
                )
            }
        )

        var settings = AppSettings.default
        settings.application.locale = "ru"
        settings.llm.connections = [Self.ollamaConfiguration(model: "llama3.2:latest")]
        settings.setTestSummaryPrompt("Write in %lang%.")

        _ = try await service.summarize(transcript: "hello transcript", settings: settings)

        XCTAssertEqual(capturedSystemPrompt, "Write in Russian.")
    }

    func testSummarizeSubstitutesSystemPromptLanguageWithCurrentLanguage() async throws {
        let previousAppleLanguages = UserDefaults.standard.object(forKey: "AppleLanguages")
        UserDefaults.standard.set(["ru"], forKey: "AppleLanguages")
        defer {
            if let previousAppleLanguages {
                UserDefaults.standard.set(previousAppleLanguages, forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            }
        }

        var capturedSystemPrompt = ""
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                capturedSystemPrompt = messages?.first?["content"] ?? ""
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: "local ok")
                )
            }
        )

        var settings = AppSettings.default
        settings.application.locale = "system"
        settings.llm.connections = [Self.ollamaConfiguration(model: "llama3.2:latest")]
        settings.setTestSummaryPrompt("Write in %lang%.")

        _ = try await service.summarize(transcript: "hello transcript", settings: settings)

        XCTAssertEqual(capturedSystemPrompt, "Write in Russian.")
    }

    func testLocalOllamaRejectsTimestampOnlySummaryForLongTranscript() async throws {
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: "[ 0m0s262ms - 0m2s692ms ] [ 0m2s692ms - 0m4s142ms ]")
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [Self.ollamaConfiguration(model: "gemma4:latest")]
        let transcript = Array(repeating: "[ 0m0s - 0m5s ] Speaker 1: обсуждаем задачу, риски, решение и дальнейшие действия.", count: 80)
            .joined(separator: "\n")

        do {
            _ = try await service.summarize(transcript: transcript, settings: settings)
            XCTFail("Expected local Ollama timestamp-only response to be rejected.")
        } catch let error as SummarizationError {
            guard case .lowQualitySummary = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLocalOllamaChunksLongTranscriptAndCombinesSummaries() async throws {
        var callCount = 0
        var finalRequestContent = ""
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                callCount += 1
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                finalRequestContent = messages?.last?["content"] ?? ""
                let content: String
                if finalRequestContent.contains("## Part 1") {
                    content = """
                    ## Итог
                    Команда обсудила антифрод-задачи, договорилась о следующем шаге и зафиксировала риски интеграции. Ответственный проверит данные, разработчики подготовят изменения, а продукт уточнит приоритеты.
                    """
                } else {
                    content = """
                    ## Часть
                    В этой части обсуждали антифрод-разработку, статусы задач, риски интеграции, владельцев действий и ближайшие договоренности. Нужно проверить данные и синхронизировать план.
                    """
                }
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: content)
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [Self.ollamaConfiguration(model: "gemma4:latest")]
        let transcript = Array(repeating: "[ 0m0s - 0m5s ] Speaker 1: обсуждаем задачу, риски, решение, данные, интеграцию и дальнейшие действия команды.", count: 260)
            .joined(separator: "\n")

        let summary = try await service.summarize(transcript: transcript, settings: settings)

        XCTAssertGreaterThan(callCount, 1)
        XCTAssertTrue(finalRequestContent.contains("## Part 1"))
        XCTAssertTrue(summary.contains("## Итог"))
    }

    func testLocalOllamaUsesConfiguredChunkSettings() async throws {
        var chunkRequestLengths: [Int] = []
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: [:]),
            session: Self.mockSession { request in
                let body = request.httpBodyStream.flatMap(Self.data(from:))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                let messages = body?["messages"] as? [[String: String]]
                let userContent = messages?.last?["content"] ?? ""
                let isFinalRequest = userContent.contains("## Part 1")
                if !isFinalRequest {
                    chunkRequestLengths.append(userContent.count)
                }
                let content = """
                ## Итог
                Команда обсудила статус, риски, владельцев дальнейших действий и план проверки данных. Важно сохранить контекст по решениям, блокерам, ответственным и следующим шагам.
                """
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    try Self.ollamaResponseData(content: content)
                )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            Self.ollamaConfiguration(model: "gemma4:latest", chunkThreshold: 4_000, chunkSize: 2_000)
        ]
        let transcript = Array(repeating: "[ 0m0s - 0m5s ] Speaker 1: обсуждаем задачу, риски, решение, данные, интеграцию и дальнейшие действия команды.", count: 90)
            .joined(separator: "\n")

        _ = try await service.summarize(transcript: transcript, settings: settings)

        XCTAssertGreaterThan(chunkRequestLengths.count, 3)
        XCTAssertTrue(chunkRequestLengths.allSatisfy { $0 <= 2_000 })
    }

    func testSummarizeRetriesServerErrors() async throws {
        var attempts = 0
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
            attempts += 1
            let statusCode = attempts == 1 ? 500 : 200
            let data = attempts == 1
                ? Data()
                : #"{"choices":[{"message":{"role":"assistant","content":"retry ok"}}]}"#.data(using: .utf8)!
            return (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        settings.llm.connections[0].retryCount = 2

        let summary = try await service.summarize(transcript: "transcript", settings: settings)

        XCTAssertEqual(summary, "retry ok")
        XCTAssertEqual(attempts, 2)
    }

    func testSummarizeRetriesRetryableHTTPStatusesWithExponentialBackoff() async throws {
        var attempts = 0
        let sleepRecorder = SleepRecorder()
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
            attempts += 1
            let statusCode = attempts < 3 ? 429 : 200
            let data = statusCode == 200
                ? #"{"choices":[{"message":{"role":"assistant","content":"done"}}]}"#.data(using: .utf8)!
                : Data()
            return (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
            },
            sleep: { value in
                await sleepRecorder.record(value)
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        settings.llm.connections[0].retryCount = 3

        let summary = try await service.summarize(transcript: "transcript", settings: settings)
        let sleepValues = await sleepRecorder.values()

        XCTAssertEqual(summary, "done")
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleepValues, [1_000_000_000, 2_000_000_000])
    }

    func testSummarizeDoesNotRetryNonRetryableHTTPStatus() async throws {
        var attempts = 0
        let sleepRecorder = SleepRecorder()
        let service = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
            attempts += 1
            return (
                HTTPURLResponse(url: request.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!,
                Data()
            )
            },
            sleep: { value in
                await sleepRecorder.record(value)
            }
        )

        var settings = AppSettings.default
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        settings.llm.connections[0].retryCount = 3

        do {
            _ = try await service.summarize(transcript: "transcript", settings: settings)
            XCTFail("Expected summarize to throw for HTTP 422.")
        } catch let error as SummarizationError {
            guard case let .http(statusCode, apiURL) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(statusCode, 422)
            XCTAssertEqual(apiURL.absoluteString, "https://summary.example/v1/chat/completions")
        }
        let sleepValues = await sleepRecorder.values()

        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleepValues, [])
    }

    func testWriteSummaryCreatesFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()
        let date = Date(timeIntervalSince1970: 1_776_880_800)

        try await service.writeSummary(
            "Summary unavailable",
            to: folder,
            date: date,
            durationMinutes: 42,
            speakers: 3,
            model: "gpt-test"
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("date: 2026-04-22T18:00:00.000Z"))
        XCTAssertTrue(markdown.contains("duration: 42"))
        XCTAssertTrue(markdown.contains("speakers: 3"))
        XCTAssertTrue(markdown.contains("model: \"gpt-test\""))
        XCTAssertTrue(markdown.contains("Summary unavailable"))
        XCTAssertTrue(markdown.contains("Recorded with [AnyBrief](https://anybrief.pro)"))
    }

    func testWriteSummaryCanOmitAnyBriefFooter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()

        try await service.writeSummary(
            "Summary without footer",
            to: folder,
            date: Date(timeIntervalSince1970: 1_777_000_000),
            durationMinutes: 10,
            speakers: 1,
            model: "gpt-test",
            includeFooter: false
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("Summary without footer"))
        XCTAssertFalse(markdown.contains("Recorded with [AnyBrief](https://anybrief.pro)"))
    }

    func testWriteSummaryIncludesPartialSuccessFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()

        try await service.writeSummary(
            """
            ## Summary
            Черновик - summary недоступен
            """,
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 5,
            speakers: 2,
            model: "gpt-test",
            status: "partial_success",
            summaryError: "summary_api_failed"
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("status: partial_success"))
        XCTAssertTrue(markdown.contains("summary_error: summary_api_failed"))
    }

    func testWriteSummaryIncludesProviderFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()

        try await service.writeSummary(
            "# Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 5,
            speakers: 2,
            model: "gpt-test",
            provider: SummaryProviderMetadata(
                type: .openAICompatible,
                title: "OpenAI-compatible",
                model: "gpt-test",
                apiURL: "https://summary.example/v1/chat/completions",
                timeoutSec: 120,
                retryCount: 3,
                commandPreset: nil,
                commandLine: nil,
                ollamaContextLength: nil,
                ollamaChunkThreshold: nil,
                ollamaChunkSize: nil
            )
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("summary_provider:"))
        XCTAssertTrue(markdown.contains("  type: \"openai_compatible\""))
        XCTAssertTrue(markdown.contains("  title: \"OpenAI-compatible\""))
        XCTAssertTrue(markdown.contains("  model: \"gpt-test\""))
        XCTAssertTrue(markdown.contains("  api_url: \"https://summary.example/v1/chat/completions\""))
        XCTAssertTrue(markdown.contains("  timeout_sec: 120"))
        XCTAssertTrue(markdown.contains("  retry_count: 3"))
        XCTAssertFalse(markdown.contains("  context_present:"))
        XCTAssertFalse(markdown.contains("  context_chars:"))
    }

    func testWriteSummaryCLIProviderFrontmatterExcludesAPIAndOllamaFields() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()

        try await service.writeSummary(
            "# Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 5,
            speakers: 2,
            model: "gpt-test",
            provider: SummaryProviderMetadata(
                type: .commandLine,
                title: "CLI",
                model: "gpt-test",
                apiURL: nil,
                timeoutSec: 120,
                retryCount: nil,
                commandPreset: "codex",
                commandLine: "/usr/local/bin/codex exec --skip-git-repo-check --json -",
                ollamaContextLength: nil,
                ollamaChunkThreshold: nil,
                ollamaChunkSize: nil
            )
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("summary_provider:"))
        XCTAssertTrue(markdown.contains("  type: \"cli\""))
        XCTAssertTrue(markdown.contains("  command_preset: \"codex\""))
        XCTAssertTrue(markdown.contains("  command: \"/usr/local/bin/codex exec --skip-git-repo-check --json -\""))
        XCTAssertFalse(markdown.contains("  api_url:"))
        XCTAssertFalse(markdown.contains("  retry_count:"))
        XCTAssertFalse(markdown.contains("  context_length:"))
        XCTAssertFalse(markdown.contains("  chunk_threshold:"))
        XCTAssertFalse(markdown.contains("  chunk_size:"))
    }

    func testWriteSummaryLocalOllamaProviderFrontmatterExcludesOpenAISettings() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()

        try await service.writeSummary(
            "# Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 5,
            speakers: 2,
            model: "gemma4:latest",
            provider: SummaryProviderMetadata(
                type: .localOllama,
                title: "Local Ollama",
                model: "gemma4:latest",
                apiURL: OllamaDefaults.chatURLString,
                timeoutSec: 120,
                retryCount: 3,
                commandPreset: nil,
                commandLine: nil,
                ollamaContextLength: 32768,
                ollamaChunkThreshold: 16000,
                ollamaChunkSize: 12000
            )
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("  type: \"local_ollama\""))
        XCTAssertTrue(markdown.contains("  api_url: \"http://127.0.0.1:11434/api/chat\""))
        XCTAssertTrue(markdown.contains("  context_length: 32768"))
        XCTAssertFalse(markdown.contains("https://api.aitunnel.ru/v1/chat/completions"))
        XCTAssertFalse(markdown.contains("  command_preset:"))
        XCTAssertFalse(markdown.contains("  command:"))
    }

    func testWriteSummaryDropsOldProviderBlockWhenPreservingFrontmatterWithBlankLines() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()
        let preservedFrontmatter = """
        date: 2026-05-28T10:19:02.380Z
        duration: 0
        speakers: 0
        model: "old-model"
        summary_provider:
          type: "local_ollama"
          title: "Local Ollama"
          api_url: "http://127.0.0.1:11434/api/chat"

          api_url: "https://api.aitunnel.ru/v1/chat/completions"
          timeout_sec: 120
          context_chars: 16
        calendar:
          title: "Keep this"
        """

        try await service.writeSummary(
            "# Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 5,
            speakers: 2,
            model: "gpt-test",
            provider: SummaryProviderMetadata(
                type: .commandLine,
                title: "CLI",
                model: "gpt-test",
                apiURL: nil,
                timeoutSec: 120,
                retryCount: nil,
                commandPreset: "codex",
                commandLine: "/usr/local/bin/codex exec --skip-git-repo-check --json -",
                ollamaContextLength: nil,
                ollamaChunkThreshold: nil,
                ollamaChunkSize: nil
            ),
            preservedFrontmatter: preservedFrontmatter
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("  type: \"cli\""))
        XCTAssertTrue(markdown.contains("calendar:"))
        XCTAssertTrue(markdown.contains("  title: \"Keep this\""))
        XCTAssertFalse(markdown.contains("https://api.aitunnel.ru/v1/chat/completions"))
        XCTAssertEqual(markdown.components(separatedBy: "summary_provider:").count - 1, 1)
    }

    func testWriteSummaryDoesNotAppendPreservedProviderSettingsToCLIProvider() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()
        let preservedFrontmatter = """
        summary_provider:
          type: "openai_compatible"
          title: "OpenAI-compatible"
          api_url: "https://routerai.ru/api/v1/chat/completions"
          timeout_sec: 120
          retry_count: 3
        calendar:
          title: "Keep calendar"
        """

        try await service.writeSummary(
            "# Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 5,
            speakers: 2,
            model: "claude",
            provider: SummaryProviderMetadata(
                type: .commandLine,
                title: "CLI",
                model: "",
                apiURL: nil,
                timeoutSec: 120,
                retryCount: nil,
                commandPreset: "claude",
                commandLine: #"/usr/local/bin/claude -p --output-format text"#,
                ollamaContextLength: nil,
                ollamaChunkThreshold: nil,
                ollamaChunkSize: nil
            ),
            preservedFrontmatter: preservedFrontmatter
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("summary_provider:"))
        XCTAssertTrue(markdown.contains("  type: \"cli\""))
        XCTAssertTrue(markdown.contains("  command_preset: \"claude\""))
        XCTAssertTrue(markdown.contains("calendar:"))
        XCTAssertFalse(markdown.contains("routerai.ru"))
        XCTAssertFalse(markdown.contains("  api_url:"))
        XCTAssertFalse(markdown.contains("  retry_count:"))
        XCTAssertEqual(markdown.components(separatedBy: "summary_provider:").count - 1, 1)
    }

    func testWriteSummaryIncludesCalendarFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()
        let startAt = Date(timeIntervalSince1970: 1_777_000_000)
        let endAt = startAt.addingTimeInterval(1800)
        let event = CalendarEvent(
            uid: "calendar-uid-20260424T100000Z",
            originalUID: "calendar-uid",
            calendarName: "work",
            title: "Design Review",
            startAt: startAt,
            endAt: endAt,
            timeZone: "Asia/Novosibirsk",
            location: "Zoom",
            notes: "Agenda\\nDiscuss product flow",
            organizer: CalendarParticipant(
                name: "Serg",
                email: "serg@example.com",
                role: "CHAIR",
                status: "ACCEPTED",
                rsvp: nil
            ),
            attendees: [
                CalendarParticipant(
                    name: "Dasha",
                    email: "dasha@example.com",
                    role: "REQ-PARTICIPANT",
                    status: "ACCEPTED",
                    rsvp: true
                )
            ],
            meetingURLs: ["https://zoom.us/j/123"],
            participantCount: 2,
            hasMeetingURL: true,
            recurrenceRule: "FREQ=WEEKLY",
            recurrenceID: nil
        )

        try await service.writeSummary(
            "# Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 30,
            speakers: 2,
            model: "gpt-test",
            metadata: SummaryMetadata(
                transcription: SummaryTranscriptionMetadata(
                    provider: "whisper_cpp",
                    model: "medium",
                    language: "ru",
                    acceleration: "metal",
                    speakersMode: "fixed",
                    speakersCount: 2,
                    systemSpeakers: "2",
                    microphoneSpeakers: 1,
                    threshold: 0.7
                ),
                audio: SummaryAudioMetadata(
                    system: SummaryAudioTrackMetadata(
                        status: "recorded",
                        durationSeconds: 1800,
                        sizeBytes: 1024,
                        segments: 10,
                        speakers: 2
                    ),
                    microphone: SummaryAudioTrackMetadata(
                        status: "recorded_no_speech",
                        durationSeconds: 1800,
                        sizeBytes: 512,
                        segments: 0,
                        speakers: 0
                    )
                ),
                calendar: event,
                warnings: ["microphone_degraded: microphone capture restarted with partial audio"]
            )
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("calendar:"))
        XCTAssertTrue(markdown.contains("transcription:"))
        XCTAssertTrue(markdown.contains("  provider: \"whisper_cpp\""))
        XCTAssertTrue(markdown.contains("  model: \"medium\""))
        XCTAssertTrue(markdown.contains("  language: \"ru\""))
        XCTAssertTrue(markdown.contains("  acceleration: \"metal\""))
        XCTAssertTrue(markdown.contains("  uid: \"calendar-uid-20260424T100000Z\""))
        XCTAssertTrue(markdown.contains("  title: \"Design Review\""))
        XCTAssertTrue(markdown.contains("  meeting_urls:"))
        XCTAssertTrue(markdown.contains("    - \"https://zoom.us/j/123\""))
        XCTAssertTrue(markdown.contains("  organizer:"))
        XCTAssertTrue(markdown.contains("    email: \"serg@example.com\""))
        XCTAssertTrue(markdown.contains("  attendees:"))
        XCTAssertTrue(markdown.contains("      email: \"dasha@example.com\""))
        XCTAssertTrue(markdown.contains("  recurrence_rule: \"FREQ=WEEKLY\""))
        XCTAssertTrue(markdown.contains("warnings:"))
        XCTAssertTrue(markdown.contains("  - \"microphone_degraded: microphone capture restarted with partial audio\""))
    }

    func testSummarizationInputIncludesCalendarFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let startAt = Date(timeIntervalSince1970: 1_777_000_000)
        let event = CalendarEvent(
            uid: "calendar-uid-20260424T100000Z",
            originalUID: "calendar-uid",
            calendarName: "work",
            title: "Anti-Fraud Planning",
            startAt: startAt,
            endAt: startAt.addingTimeInterval(1800),
            timeZone: "Asia/Novosibirsk",
            location: nil,
            notes: "Discuss rollout risks and owners",
            organizer: nil,
            attendees: [],
            meetingURLs: [],
            participantCount: 4,
            hasMeetingURL: true,
            recurrenceRule: nil,
            recurrenceID: nil
        )

        let input = await service.summarizationInput(
            transcript: "Speaker 1: hello",
            metadata: SummaryMetadata(
                transcription: SummaryTranscriptionMetadata(
                    speakersMode: "auto",
                    speakersCount: 2,
                    systemSpeakers: "auto",
                    microphoneSpeakers: 1,
                    threshold: 0.7
                ),
                audio: SummaryAudioMetadata(
                    system: SummaryAudioTrackMetadata(
                        status: "recorded",
                        durationSeconds: 1800,
                        sizeBytes: 1024,
                        segments: 10,
                        speakers: 2
                    ),
                    microphone: SummaryAudioTrackMetadata(
                        status: "recorded_no_speech",
                        durationSeconds: 1800,
                        sizeBytes: 512,
                        segments: 0,
                        speakers: 0
                    )
                ),
                calendar: event
            )
        )

        XCTAssertTrue(input.contains("Meeting metadata frontmatter:"))
        XCTAssertTrue(input.contains("calendar:"))
        XCTAssertTrue(input.contains("  title: \"Anti-Fraud Planning\""))
        XCTAssertTrue(input.contains("Discuss rollout risks and owners"))
        XCTAssertTrue(input.contains("Transcript:\nSpeaker 1: hello"))
    }

    func testWriteSummaryPreservesExistingMetadataFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()
        let preservedFrontmatter = """
        date: 2026-05-18T01:00:00.000Z
        duration: 31
        speakers: 3
        model: "old-model"
        transcription:
          speakers_mode: "auto"
          speakers_count: 2
        calendar:
          title: "Important Calendar Event"
          notes: |
            Planning context from calendar
        """

        try await service.writeSummary(
            "# New Summary",
            to: folder,
            date: Date(timeIntervalSince1970: 1_777_000_000),
            durationMinutes: 31,
            speakers: 3,
            model: "new-model",
            preservedFrontmatter: preservedFrontmatter
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )
        XCTAssertTrue(markdown.contains("model: \"new-model\""))
        XCTAssertFalse(markdown.contains("model: \"old-model\""))
        XCTAssertTrue(markdown.contains("transcription:"))
        XCTAssertTrue(markdown.contains("calendar:"))
        XCTAssertTrue(markdown.contains("  title: \"Important Calendar Event\""))
        XCTAssertTrue(markdown.contains("Planning context from calendar"))
    }

    func testWriteSummaryEscapesBackslashesInYamlFrontmatter() async throws {
        let service = SummarizationService(keychainStore: MockKeychainStore(values: [:]))
        let folder = try makeTemporaryDirectory()

        try await service.writeSummary(
            "Summary unavailable",
            to: folder,
            date: Date(timeIntervalSince1970: 1_776_880_800),
            durationMinutes: 1,
            speakers: 1,
            model: #"gpt\test"#
        )

        let markdown = try String(
            contentsOf: folder.appendingPathComponent("summary.md", isDirectory: false),
            encoding: .utf8
        )

        XCTAssertTrue(markdown.contains(#"model: "gpt\\test""#))
    }

    func testMockSessionsKeepHandlersIsolatedAcrossConcurrentRequests() async throws {
        var settings = AppSettings.default
        settings.llm.connections = [
            SummarizationServiceTests.openAIConfiguration(model: "gpt-test", apiKeyRef: "summary-key")
        ]
        let stableSettings = settings

        let firstService = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"choices":[{"message":{"role":"assistant","content":"first"}}]}"#.data(using: .utf8)!
                )
            }
        )
        let secondService = SummarizationService(
            keychainStore: MockKeychainStore(values: ["summary-key": "secret"]),
            session: Self.mockSession { request in
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
                return (
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    #"{"choices":[{"message":{"role":"assistant","content":"second"}}]}"#.data(using: .utf8)!
                )
            }
        )

        async let firstSummary = firstService.summarize(transcript: "one", settings: stableSettings)
        async let secondSummary = secondService.summarize(transcript: "two", settings: stableSettings)

        let results = try await (firstSummary, secondSummary)
        XCTAssertEqual(Set([results.0, results.1]), ["first", "second"])
    }

    func testCommandLineProviderRunsInTranscriptFolder() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "hello transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var settings = AppSettings.default
        settings.llm.connections = [
            .cli(commandLine: #"cat >/dev/null; printf "folder:%s transcript:%s" "$PWD" "$(cat transcript.txt)""#)
        ]
        settings.llm.connections[0].timeoutSec = 5

        let summary = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
            .summarize(
                transcript: "hello transcript",
                settings: settings,
                workingDirectory: folder,
                transcriptURL: transcriptURL
            )

        XCTAssertTrue(summary.contains(folder.lastPathComponent))
        XCTAssertTrue(summary.contains("transcript:hello transcript"))
    }

    func testCommandLineProviderReceivesPromptContextsAndTranscriptPath() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "file transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var settings = AppSettings.default
        settings.llm.connections = [
            .cli(commandLine: #"printf "%s" "$(cat)""#)
        ]
        settings.setTestSummaryPrompt("CLI prompt text")
        settings.setTestSpeakerContext("Speaker context text")
        settings.llm.connections[0].timeoutSec = 5

        let summary = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
            .summarize(
                transcript: "input transcript",
                settings: settings,
                workingDirectory: folder,
                transcriptURL: transcriptURL
            )

        XCTAssertTrue(summary.contains("CLI prompt text"))
        XCTAssertTrue(summary.contains("Speaker context text"))
        XCTAssertTrue(summary.contains(transcriptURL.path))
        XCTAssertTrue(summary.contains("input transcript"))
    }

    func testCommandLineProviderDrainsLargeOutputPipes() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "hello transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var settings = AppSettings.default
        settings.llm.connections = [
            .cli(commandLine: #"yes err | head -c 1048576 >&2; yes out | head -c 1048576; printf "done""#)
        ]
        settings.llm.connections[0].timeoutSec = 5

        let summary = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
            .summarize(
                transcript: "hello transcript",
                settings: settings,
                workingDirectory: folder,
                transcriptURL: transcriptURL
            )

        XCTAssertTrue(summary.hasSuffix("done"))
    }

    func testCodexPresetAllowsMeetingFoldersOutsideGitRepository() {
        let command = CLISummaryProvider.resolvedCommand(.cli(preset: "codex"))

        XCTAssertTrue(command.contains("codex"))
        XCTAssertTrue(command.contains("exec"))
        XCTAssertTrue(command.contains("--skip-git-repo-check"))
        XCTAssertTrue(command.contains("--ignore-user-config"))
        XCTAssertTrue(command.contains("--json"))
        XCTAssertTrue(command.hasSuffix(" -"))
    }

    func testCodexPresetCanLoadUserConfigurationWhenExplicitlyEnabled() {
        var configuration = SummaryProviderConfiguration.cli(preset: "codex")
        configuration.cliCodexIgnoreUserConfig = false

        let command = CLISummaryProvider.resolvedCommand(configuration)

        XCTAssertFalse(command.contains("--ignore-user-config"))
    }

    func testCodexAPIPreflightTreatsUnauthorizedAsReachable() async throws {
        let session = Self.mockSession { request in
            XCTAssertEqual(
                request.url?.absoluteString,
                "https://chatgpt.com/backend-api/codex/models"
            )
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let target = try XCTUnwrap(CLIAPIReachabilityTarget(preset: "codex"))

        let statusCode = try await CLIAPIReachabilityChecker(session: session).check(target)

        XCTAssertEqual(statusCode, 401)
    }

    func testClaudeAPIPreflightUsesAnthropicAPI() async throws {
        let session = Self.mockSession { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/models")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let target = try XCTUnwrap(CLIAPIReachabilityTarget(preset: "claude"))

        let statusCode = try await CLIAPIReachabilityChecker(session: session).check(target)

        XCTAssertEqual(statusCode, 403)
    }

    func testCLIPreflightRejectsServerFailure() async throws {
        let session = Self.mockSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        let target = try XCTUnwrap(CLIAPIReachabilityTarget(preset: "codex"))

        do {
            _ = try await CLIAPIReachabilityChecker(session: session).check(target)
            XCTFail("Expected server error")
        } catch {
            XCTAssertEqual(CLIAPIReachabilityChecker.reason(for: error), "HTTP 503")
        }
    }

    func testClaudePresetUsesStrictEmptyMCPConfiguration() {
        let command = CLISummaryProvider.resolvedCommand(.cli(preset: "claude"))

        XCTAssertTrue(command.contains("claude"))
        XCTAssertTrue(command.contains("--strict-mcp-config"))
        XCTAssertTrue(command.contains(#"--mcp-config '{"mcpServers":{}}'"#))
        XCTAssertFalse(command.contains(#"--mcp-config '{}'"#))
        XCTAssertFalse(command.contains("--bare"))
    }

    func testPresetIgnoresStoredCustomCommandLine() {
        let command = CLISummaryProvider.resolvedCommand(
            .cli(preset: "claude", commandLine: #"printf "wrong""#)
        )

        XCTAssertTrue(command.contains("claude"))
        XCTAssertFalse(command.contains("printf"))
    }

    func testCustomPresetUsesCustomCommandLine() {
        let command = CLISummaryProvider.resolvedCommand(
            .cli(preset: "custom", commandLine: #"printf "ok""#)
        )

        XCTAssertTrue(command.contains("printf"))
        XCTAssertTrue(command.contains("ok"))
    }

    func testCLIDiagnosticExplainsClaudeAuthenticationFailure() async throws {
        let settings = AppSettings.default

        let configuration = SummaryProviderConfiguration.cli(
            commandLine: #"printf "Not logged in · Please run /login\n" >&2; exit 1"#
        )

        do {
            _ = try await CLIDiagnostics().diagnose(
                configuration: configuration,
                settings: settings,
                openAIAPIKey: ""
            )
            XCTFail("Expected Claude auth diagnostic failure")
        } catch {
            let message = error.localizedDescription
            // Locale-independent: the localized message keeps the product name
            // and the backticked commands verbatim.
            XCTAssertTrue(message.contains("Claude CLI"))
            XCTAssertTrue(message.contains("claude auth login"))
            XCTAssertTrue(message.contains("claude setup-token"))
        }
    }

    func testOpencodePresetUsesPromptFileAttachment() {
        let command = CLISummaryProvider.resolvedCommand(.cli(preset: "opencode"))

        XCTAssertTrue(command.contains("opencode"))
        XCTAssertTrue(command.contains("run"))
        XCTAssertTrue(command.contains("--format default"))
        XCTAssertTrue(command.contains(#"--file "$ANYBRIEF_SUMMARY_PROMPT_FILE""#))
    }

    func testOpencodePresetDetectsStdoutErrorLine() {
        let stdout = "\u{001B}[0m\n> build · glm-5:cloud\n\u{001B}[91m\u{001B}[1mError: \u{001B}[0mForbidden: remote model is unavailable\n"

        XCTAssertEqual(
            CLISummaryProvider.opencodeErrorMessage(from: stdout),
            "Error: Forbidden: remote model is unavailable"
        )
    }

    func testCodexJSONSummaryParsesLastAgentMessageAndIgnoresWarnings() {
        let stdout = """
        {"type":"thread.started","thread_id":"abc"}
        2026-05-28T09:57:02Z WARN noisy non-json line
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"first draft"}}
        {"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"final summary"}}
        {"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":1}}
        """

        XCTAssertEqual(CLISummaryProvider.codexJSONSummary(from: stdout), "final summary")
    }

    func testCommandLineProviderFailureKeepsMultilineStderrDetails() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "hello transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var settings = AppSettings.default
        settings.llm.connections = [
            .cli(commandLine: #"printf "Reading prompt from stdin...\nActual failure\n" >&2; exit 7"#)
        ]
        settings.llm.connections[0].timeoutSec = 5

        do {
            _ = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
                .summarize(
                    transcript: "hello transcript",
                    settings: settings,
                    workingDirectory: folder,
                    transcriptURL: transcriptURL
                )
            XCTFail("Expected CLI failure")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("exit_code=7"))
            XCTAssertTrue(message.contains("Reading prompt from stdin... | Actual failure"))
        }
    }

    func testCommandLineProviderFailureKeepsStdoutDetailsWhenStderrIsEmpty() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "hello transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var settings = AppSettings.default
        settings.llm.connections = [
            .cli(commandLine: #"printf "Your organization does not have access to Claude.\nPlease login again.\n"; exit 1"#)
        ]
        settings.llm.connections[0].timeoutSec = 5

        do {
            _ = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
                .summarize(
                    transcript: "hello transcript",
                    settings: settings,
                    workingDirectory: folder,
                    transcriptURL: transcriptURL
                )
            XCTFail("Expected CLI failure")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("exit_code=1"))
            XCTAssertTrue(message.contains("stderr=<empty>"))
            XCTAssertTrue(message.contains("stdout=Your organization does not have access to Claude. | Please login again."))
        }
    }

    func testCommandLineProviderEarlyExitDoesNotCrashOnClosedStdin() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "hello transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var settings = AppSettings.default
        settings.llm.connections = [
            .cli(commandLine: #"printf "cli crashed before reading stdin\n" >&2; exit 11"#)
        ]
        settings.llm.connections[0].timeoutSec = 5

        do {
            _ = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
                .summarize(
                    transcript: String(repeating: "large transcript ", count: 200_000),
                    settings: settings,
                    workingDirectory: folder,
                    transcriptURL: transcriptURL
                )
            XCTFail("Expected CLI failure")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("exit_code=11"))
            XCTAssertTrue(message.contains("cli crashed before reading stdin"))
        }
    }

    func testCommandLineProviderOverallTimeoutTerminatesDescendantProcesses() async throws {
        let folder = try makeTemporaryDirectory()
        let transcriptURL = folder.appendingPathComponent("transcript.txt", isDirectory: false)
        try "hello transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        var configuration = SummaryProviderConfiguration.cli(
            commandLine: #"/bin/sh -c 'sleep 30 & echo $! > child.pid; wait'"#
        )
        configuration.timeoutSec = 1
        configuration.retryCount = 1
        var settings = AppSettings.default
        settings.llm.connections = [configuration]

        do {
            _ = try await SummarizationService(keychainStore: MockKeychainStore(values: [:]))
                .summarize(
                    transcript: "hello transcript",
                    settings: settings,
                    workingDirectory: folder,
                    transcriptURL: transcriptURL
                )
            XCTFail("Expected CLI timeout")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("timed out after 1s"))
        }

        let childPIDURL = folder.appendingPathComponent("child.pid", isDirectory: false)
        let childPIDText = try String(contentsOf: childPIDURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let childPID = try XCTUnwrap(pid_t(childPIDText))
        XCTAssertEqual(kill(childPID, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    static func mockSession(handler: @escaping SummaryURLProtocol.Handler) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [SummaryURLProtocol.tokenHeader: UUID().uuidString]
        configuration.protocolClasses = [SummaryURLProtocol.self]
        let token = configuration.httpAdditionalHeaders?[SummaryURLProtocol.tokenHeader] as? String ?? UUID().uuidString
        SummaryURLProtocol.register(handler: handler, for: token)
        return URLSession(configuration: configuration)
    }

    static func openAIConfiguration(
        model: String,
        apiKeyRef: String,
        apiURL: String = "https://summary.example/v1/chat/completions"
    ) -> SummaryProviderConfiguration {
        var configuration = SummaryProviderConfiguration.openAI()
        configuration.openAIAPIURL = apiURL
        configuration.openAIAPIKeyKeychainRef = apiKeyRef
        configuration.openAIModel = model
        return configuration
    }

    static func calendarEvent(title: String) -> CalendarEvent {
        let start = Date(timeIntervalSince1970: 1_777_000_000)
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

    static func ollamaConfiguration(
        model: String,
        chunkThreshold: Int? = nil,
        chunkSize: Int? = nil
    ) -> SummaryProviderConfiguration {
        var configuration = SummaryProviderConfiguration.ollama()
        configuration.ollamaModel = model
        configuration.ollamaChunkThreshold = chunkThreshold
        configuration.ollamaChunkSize = chunkSize
        return configuration
    }

    private static func summaryResponseData(content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": content,
                    ],
                ],
            ],
        ])
    }

    private static func ollamaResponseData(content: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "message": [
                "role": "assistant",
                "content": content,
            ],
            "done": true,
        ])
    }

    private static func data(from stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}

/// Tests meeting finalization outputs and state transitions.
final class FinalizationServiceTests: XCTestCase {
    func testFinalizeCreatesBundleRenamesFolderCleansTmpAndMarksJobCompleted() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingFolderURL = rootURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        let tmpURL = meetingFolderURL.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)

        let systemWavURL = tmpURL.appendingPathComponent("system.wav", isDirectory: false)
        let micWavURL = tmpURL.appendingPathComponent("mic.wav", isDirectory: false)
        let transcriptURL = meetingFolderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        let mergedJSONURL = meetingFolderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        let summaryURL = meetingFolderURL.appendingPathComponent("summary.md", isDirectory: false)
        let jobLogURL = rootURL.appendingPathComponent("job.log", isDirectory: false)
        let zipInvocationURL = rootURL.appendingPathComponent("zip-contents.txt", isDirectory: false)

        try Data("system".utf8).write(to: systemWavURL)
        try Data("mic".utf8).write(to: micWavURL)
        try Data("transcript".utf8).write(to: transcriptURL)
        try Data("[]".utf8).write(to: mergedJSONURL)
        try Data("# Summary".utf8).write(to: summaryURL)
        try Data().write(to: jobLogURL)

        let scriptsURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        let ffmpegScriptURL = scriptsURL.appendingPathComponent("ffmpeg", isDirectory: false)
        let zipScriptURL = scriptsURL.appendingPathComponent("zip", isDirectory: false)
        try Self.writeExecutable(
            """
            #!/bin/sh
            input=""
            output=""
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-i" ]; then
                shift
                input="$1"
              fi
              output="$1"
              shift
            done
            cp "$input" "$output"
            """,
            to: ffmpegScriptURL
        )
        try Self.writeExecutable(
            """
            #!/bin/sh
            bundle="$2"
            shift 2
            : > "$bundle"
            printf '%s\n' "$@" > "\(zipInvocationURL.path)"
            """,
            to: zipScriptURL
        )

        let session = RecordingSession(
            jobId: "job-1",
            pid: 123,
            paths: MeetingPaths(
                folderURL: meetingFolderURL,
                tmpURL: tmpURL,
                systemWavURL: systemWavURL,
                micWavURL: micWavURL,
                jobLogURL: jobLogURL
            ),
            startedAt: Date(timeIntervalSince1970: 1_777_000_000),
            source: "manual",
            title: "job-1",
            autoStopDisabled: false
        )

        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: "job-1",
                meetingId: "job-1",
                status: "summarizing",
                stage: .packaging,
                source: "manual",
                createdAt: session.startedAt,
                updatedAt: session.startedAt
            )
        )

        let loggingService = LoggingService()
        let storageService = TestStorageService(fileManager: fileManager)
        let stateRecorder = AppStateRecorder()
        let service = FinalizationService(
            storageService: storageService,
            jobRepository: jobRepository,
            loggingService: loggingService,
            appStateDidChange: { state in
                await stateRecorder.record(state)
            },
            fileManager: fileManager,
            ffmpegURLResolver: { ffmpegScriptURL },
            zipURLResolver: { zipScriptURL },
            durationResolver: { _ in 42 * 60 }
        )

        try await service.finalize(session: session, summary: "# Summary")

        let finalFolderURL = rootURL.appendingPathComponent("2026-04-24_11-00_42m", isDirectory: true)
        XCTAssertTrue(fileManager.fileExists(atPath: finalFolderURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("summary.md").path))
        XCTAssertTrue(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("transcript.txt").path))
        XCTAssertTrue(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("bundle.zip").path))
        let archivedEntries = try String(contentsOf: zipInvocationURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        XCTAssertEqual(
            Set(archivedEntries),
            ["summary.md", "transcript.txt", "transcript_merged.json", "system_audio.mp3", "microphone_audio.mp3"]
        )
        // Audio and JSON are inside bundle.zip only — not at folder level
        XCTAssertFalse(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("system_audio.mp3").path))
        XCTAssertFalse(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("microphone_audio.mp3").path))
        XCTAssertFalse(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("transcript_merged.json").path))
        XCTAssertFalse(fileManager.fileExists(atPath: finalFolderURL.appendingPathComponent("tmp").path))

        let jobValue = await jobRepository.get(id: "job-1")
        let job = try XCTUnwrap(jobValue)
        XCTAssertEqual(job.status, "completed")
        XCTAssertEqual(job.stage, .completed)
        XCTAssertNotNil(job.completedAt)
        let states = await stateRecorder.states
        XCTAssertEqual(states.count, 1)
        if let state = states.first {
            switch state {
            case .idle:
                break
            default:
                XCTFail("Expected app state to return to idle.")
            }
        } else {
            XCTFail("Expected one app state transition.")
        }
    }

    static func writeExecutable(_ contents: String, to url: URL) throws {
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    static func stubExecutable(named name: String, in rootURL: URL, contents: String) throws -> URL {
        let scriptsURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: scriptsURL, withIntermediateDirectories: true)
        let scriptURL = scriptsURL.appendingPathComponent(name, isDirectory: false)
        try writeExecutable(contents, to: scriptURL)
        return scriptURL
    }

    static let ffmpegScript = """
    #!/bin/sh
    input=""
    output=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-i" ]; then
        shift
        input="$1"
      fi
      output="$1"
      shift
    done
    cp "$input" "$output"
    """

    static let zipScript = """
    #!/bin/sh
    touch "$2"
    """
}

/// Tests startup recovery decisions against persisted jobs and on-disk artifacts.
final class StartupRecoveryServiceTests: XCTestCase {
    func testRecoveryMarksInterruptedRecordingFailedAndPreservesTmp() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let dayURL = meetingsURL.appendingPathComponent("2026-04-24", isDirectory: true)
        let folderURL = dayURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: tmpURL.appendingPathComponent("system.wav", isDirectory: false))
        try Data("wav".utf8).write(to: tmpURL.appendingPathComponent("mic.wav", isDirectory: false))

        let createdAt = localDate(year: 2026, month: 4, day: 24, hour: 11, minute: 0)
        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: "job-1",
                meetingId: "job-1",
                status: "recording",
                stage: .recording,
                source: "manual",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )

        let service = StartupRecoveryService(
            jobRepository: jobRepository,
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(),
            resumeJob: { _, _ in
                XCTFail("Recording jobs must not be resumed.")
            }
        )

        await service.recoverJobs()

        let recoveredJob = await jobRepository.get(id: "job-1")
        let job = try XCTUnwrap(recoveredJob)
        XCTAssertEqual(job.status, "failed")
        XCTAssertEqual(job.error?.code, "recording_interrupted")
        XCTAssertTrue(fileManager.fileExists(atPath: tmpURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: tmpURL.appendingPathComponent("system.wav").path))
        XCTAssertTrue(fileManager.fileExists(atPath: tmpURL.appendingPathComponent("mic.wav").path))
    }

    func testRecoveryAggregatesInterruptedRecordingNotifications() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let dayURL = meetingsURL.appendingPathComponent("2026-04-24", isDirectory: true)
        let interruptedFolderURL = dayURL.appendingPathComponent("2026-04-24_11-00_job-1_inprogress", isDirectory: true)
        let orphanFolderURL = dayURL.appendingPathComponent("2026-04-24_12-00_orphan-job_inprogress", isDirectory: true)
        try fileManager.createDirectory(at: interruptedFolderURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: orphanFolderURL, withIntermediateDirectories: true)

        let createdAt = localDate(year: 2026, month: 4, day: 24, hour: 11, minute: 0)
        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: "job-1",
                meetingId: "job-1",
                status: "recording",
                stage: .recording,
                source: "manual",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )
        let notifications = RecoveryNotificationRecorder()
        let service = StartupRecoveryService(
            jobRepository: jobRepository,
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(),
            fileManager: fileManager,
            notifyInterruptedRecording: { body in
                await notifications.record(body)
            },
            resumeJob: { _, _ in
                XCTFail("Interrupted recordings must not be resumed.")
            }
        )

        await service.recoverJobs()

        let bodies = await notifications.currentValue()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("2") == true)
        let duplicateInterruptedJob = await jobRepository.get(id: "orphan-2026-04-24_11-00_job-1_inprogress")
        let orphanJob = await jobRepository.get(id: "orphan-2026-04-24_12-00_orphan-job_inprogress")
        XCTAssertNil(duplicateInterruptedJob)
        XCTAssertNotNil(orphanJob)
    }

    func testRecoveryResumesRecoverableJobFromSavedStage() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let dayURL = meetingsURL.appendingPathComponent("2026-04-24", isDirectory: true)
        let folderURL = dayURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        let sttSystemURL = tmpURL.appendingPathComponent("stt-system", isDirectory: true)
        try fileManager.createDirectory(at: sttSystemURL, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: tmpURL.appendingPathComponent("mic.wav", isDirectory: false))
        try """
        [00:00] Speaker A: hello
        """.write(
            to: sttSystemURL.appendingPathComponent("system_combined.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        let createdAt = localDate(year: 2026, month: 4, day: 24, hour: 11, minute: 0)
        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: "job-2",
                meetingId: "job-2",
                status: "processing",
                stage: .transcribingMic,
                source: "manual",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )
        let recorder = RecoveryResumeRecorder()
        let service = StartupRecoveryService(
            jobRepository: jobRepository,
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(),
            resumeJob: { session, stage in
                await recorder.record(jobId: session.jobId, stage: stage, folderPath: session.paths.folderURL.path)
            }
        )

        await service.recoverJobs()

        let recordedResume = await recorder.currentValue()
        let resume = try XCTUnwrap(recordedResume)
        XCTAssertEqual(resume.jobId, "job-2")
        XCTAssertEqual(resume.stage, .transcribingMic)
        XCTAssertEqual(resume.folderPath, folderURL.path)
    }

    func testRecoveryFailsJobWhenStageInputsAreMissing() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let dayURL = meetingsURL.appendingPathComponent("2026-04-24", isDirectory: true)
        let folderURL = dayURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let createdAt = localDate(year: 2026, month: 4, day: 24, hour: 11, minute: 0)
        let jobRepository = InMemoryJobRepository()
        await jobRepository.upsert(
            Job(
                id: "job-3",
                meetingId: "job-3",
                status: "summarizing",
                stage: .summarizing,
                source: "manual",
                createdAt: createdAt,
                updatedAt: createdAt
            )
        )

        let service = StartupRecoveryService(
            jobRepository: jobRepository,
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(),
            resumeJob: { _, _ in
                XCTFail("Jobs with missing inputs must not be resumed.")
            }
        )

        await service.recoverJobs()

        let failedJob = await jobRepository.get(id: "job-3")
        let job = try XCTUnwrap(failedJob)
        XCTAssertEqual(job.status, "failed")
        XCTAssertEqual(job.error?.code, "artifacts_missing")
    }

    func testRecoveryMarksOrphanedInProgressFolderFailedAndPreservesTmp() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let dayURL = meetingsURL.appendingPathComponent("2026-04-24", isDirectory: true)
        let folderURL = dayURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: tmpURL.appendingPathComponent("system.wav", isDirectory: false))

        let jobRepository = InMemoryJobRepository()
        let service = StartupRecoveryService(
            jobRepository: jobRepository,
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(),
            fileManager: fileManager,
            resumeJob: { _, _ in
                XCTFail("Orphaned recording folders must not be resumed.")
            }
        )

        await service.recoverJobs()

        let recoveredJob = await jobRepository.get(id: "orphan-2026-04-24_11-00_inprogress")
        let job = try XCTUnwrap(recoveredJob)
        XCTAssertEqual(job.status, "failed")
        XCTAssertEqual(job.error?.code, "recording_interrupted")
        XCTAssertTrue(fileManager.fileExists(atPath: tmpURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: tmpURL.appendingPathComponent("system.wav").path))
    }

    func testRecoveryDoesNotNotifyAgainForPreviouslyRecoveredOrphanedFolderWithUUID() async throws {
        let fileManager = FileManager.default
        let rootURL = try makeTemporaryDirectory()
        let meetingsURL = rootURL.appendingPathComponent("meetings", isDirectory: true)
        let dayURL = meetingsURL.appendingPathComponent("2026-05-21", isDirectory: true)
        let folderName = "2026-05-21_14-00_54368946-917a-499d-b1d9-ae598a9d9d00_inprogress"
        let folderURL = dayURL.appendingPathComponent(folderName, isDirectory: true)
        try fileManager.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let jobRepository = InMemoryJobRepository()
        let notifications = RecoveryNotificationRecorder()
        let service = StartupRecoveryService(
            jobRepository: jobRepository,
            storageService: TestStorageService(fileManager: fileManager, meetingsDirectoryURL: meetingsURL),
            loggingService: LoggingService(),
            fileManager: fileManager,
            notifyInterruptedRecording: { body in
                await notifications.record(body)
            },
            resumeJob: { _, _ in
                XCTFail("Orphaned recording folders must not be resumed.")
            }
        )

        await service.recoverJobs()
        await service.recoverJobs()

        let bodies = await notifications.currentValue()
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("1") == true)

        let recoveredJob = await jobRepository.get(id: "orphan-\(folderName)")
        let job = try XCTUnwrap(recoveredJob)
        XCTAssertEqual(job.status, "failed")
        XCTAssertEqual(job.error?.code, "recording_interrupted")
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(
            timeZone: .current,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }
}

final class MockKeychainStore: SecretStoreProtocol {
    private var values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func save(key: String, value: String) throws {
        values[key] = value
    }

    func load(key: String) -> String? {
        values[key]
    }

    func delete(key: String) {
        values.removeValue(forKey: key)
    }
}

final class SummaryURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    static let tokenHeader = "X-Summary-Protocol-Token"

    private static let lock = NSLock()
    private static var handlers: [String: Handler] = [:]

    static func register(handler: @escaping Handler, for token: String) {
        lock.lock()
        handlers[token] = handler
        lock.unlock()
    }

    private static func handler(for request: URLRequest) -> Handler? {
        guard let token = request.value(forHTTPHeaderField: tokenHeader) else {
            return nil
        }

        lock.lock()
        let handler = handlers[token]
        lock.unlock()
        return handler
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler(for: request) else {
            client?.urlProtocol(self, didFailWithError: SummarizationError.apiUnavailable)
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

extension XCTestCase {
    func makeTemporaryDirectory(file: StaticString = #filePath, line: UInt = #line) throws -> URL {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        addTeardownBlock {
            if FileManager.default.fileExists(atPath: directoryURL.path) {
                try? FileManager.default.removeItem(at: directoryURL)
            }
        }
        return directoryURL
    }
}

actor InMemoryJobRepository: JobRepositoryProtocol {
    private var jobs: [Job] = []

    func load() async -> [Job] {
        jobs
    }

    func save(_ jobs: [Job]) async {
        self.jobs = jobs
    }

    func upsert(_ job: Job) async {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.append(job)
        }
    }

    func get(id: String) async -> Job? {
        jobs.first(where: { $0.id == id })
    }
}

final class TestStorageService: StorageServiceProtocol {
    private let fileManager: FileManager
    let meetingsDirectoryURL: URL

    init(fileManager: FileManager, meetingsDirectoryURL: URL = FileManager.default.temporaryDirectory) {
        self.fileManager = fileManager
        self.meetingsDirectoryURL = meetingsDirectoryURL
    }

    func prepareStorage(using loggingService: LoggingService) async throws {}

    func createMeetingFolder(jobId: String, startedAt: Date) throws -> MeetingPaths {
        let folderURL = meetingsDirectoryURL.appendingPathComponent("\(jobId)_inprogress", isDirectory: true)
        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        let logsURL = meetingsDirectoryURL.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: tmpURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsURL, withIntermediateDirectories: true)

        let jobLogURL = logsURL.appendingPathComponent("\(jobId).log", isDirectory: false)
        if !fileManager.fileExists(atPath: jobLogURL.path) {
            fileManager.createFile(atPath: jobLogURL.path, contents: nil)
        }

        return MeetingPaths(
            folderURL: folderURL,
            tmpURL: tmpURL,
            systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
            micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
            jobLogURL: jobLogURL
        )
    }

    func renameMeetingFolder(from paths: MeetingPaths, duration: TimeInterval) throws -> URL {
        let finalURL = paths.folderURL.deletingLastPathComponent()
            .appendingPathComponent("2026-04-24_11-00_42m", isDirectory: true)
        try fileManager.moveItem(at: paths.folderURL, to: finalURL)
        return finalURL
    }

    func findMeetingPaths(jobId: String, createdAt: Date) throws -> MeetingPaths? {
        let dayURL = meetingsDirectoryURL.appendingPathComponent("2026-04-24", isDirectory: true)
        let folderURL = dayURL.appendingPathComponent("2026-04-24_11-00_inprogress", isDirectory: true)
        guard fileManager.fileExists(atPath: folderURL.path) else {
            return nil
        }

        let tmpURL = folderURL.appendingPathComponent("tmp", isDirectory: true)
        return MeetingPaths(
            folderURL: folderURL,
            tmpURL: tmpURL,
            systemWavURL: tmpURL.appendingPathComponent("system.wav", isDirectory: false),
            micWavURL: tmpURL.appendingPathComponent("mic.wav", isDirectory: false),
            jobLogURL: meetingsDirectoryURL.appendingPathComponent("\(jobId).log", isDirectory: false)
        )
    }

    func cleanupTemporaryArtifacts(for paths: MeetingPaths) throws {
        if fileManager.fileExists(atPath: paths.tmpURL.path) {
            try fileManager.removeItem(at: paths.tmpURL)
        }
    }
}

actor AppStateRecorder {
    private(set) var states: [AppState] = []

    func record(_ state: AppState) {
        states.append(state)
    }

    func lastState() -> AppState? {
        states.last
    }
}

actor NotificationRecorder {
    typealias Value = (category: String, title: String, body: String)

    private var notifications: [Value] = []

    func record(category: String, title: String, body: String) {
        notifications.append((category, title, body))
    }

    func currentValue() -> Value? {
        notifications.last
    }

    func values() -> [Value] {
        notifications
    }
}

private actor SleepRecorder {
    private var recordedValues: [UInt64] = []

    func record(_ value: UInt64) {
        recordedValues.append(value)
    }

    func values() -> [UInt64] {
        recordedValues
    }
}

final class FixedAppSettingsStore: AppSettingsStoreProtocol {
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func load(using loggingService: LoggingService) async -> AppSettings {
        settings
    }

    func save(_ settings: AppSettings) async throws {}
}

private actor RecoveryResumeRecorder {
    struct Value {
        let jobId: String
        let stage: JobStage
        let folderPath: String
    }

    private(set) var value: Value?

    func record(jobId: String, stage: JobStage, folderPath: String) {
        value = Value(jobId: jobId, stage: stage, folderPath: folderPath)
    }

    func currentValue() -> Value? {
        value
    }
}

private actor RecoveryNotificationRecorder {
    private(set) var bodies: [String] = []

    func record(_ body: String) {
        bodies.append(body)
    }

    func currentValue() -> [String] {
        bodies
    }
}


private extension AppSettings {
    mutating func setTestSummaryPrompt(_ text: String) {
        prompts.items = [PromptItem(id: "test-prompt", name: "Test prompt", text: text)]
        prompts.summary.promptID = "test-prompt"
    }

    mutating func setTestSpeakerContext(_ text: String) {
        prompts.items.append(PromptItem(id: "test-speaker-context", name: "Speaker context", text: text))
        prompts.summary.speakerContextPromptID = "test-speaker-context"
    }
}
