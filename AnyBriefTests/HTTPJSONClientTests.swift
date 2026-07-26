import XCTest
@testable import AnyBrief

final class HTTPJSONClientTests: XCTestCase {
    func testSafeURLDescriptionDropsQueryAndFragment() {
        let url = URL(string: "https://api.example.test/v1/chat?token=secret#response")!

        XCTAssertEqual(
            HTTPJSONClient.safeURLDescription(url),
            "https://api.example.test/v1/chat"
        )
    }

    func testRetriesRetryableServerStatusWithExponentialDelay() async throws {
        var attempts = 0
        var delays: [UInt64] = []
        let session = SummarizationServiceTests.mockSession { request in
            attempts += 1
            let statusCode = attempts == 1 ? 500 : 200
            return (
                HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data("{}".utf8)
            )
        }
        let client = HTTPJSONClient(
            session: session,
            sleep: { nanoseconds in
                delays.append(nanoseconds)
            }
        )

        let data = try await client.send(
            requestBody: Data("{\"ok\":true}".utf8),
            apiURL: URL(string: "https://api.example.test/v1/chat")!,
            apiKey: "secret",
            timeout: 20,
            retryPolicy: HTTPRetryPolicy(maxAttempts: 2)
        )

        XCTAssertEqual(data, Data("{}".utf8))
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(delays, [1_000_000_000])
    }
}
