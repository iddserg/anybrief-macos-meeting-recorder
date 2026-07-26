import Foundation

struct SummaryRequest: Encodable {
    let model: String
    let messages: [SummaryMessage]
}

struct SummaryResponse: Decodable {
    struct Choice: Decodable {
        let message: SummaryMessage
    }

    let choices: [Choice]
}
