import Foundation

struct OllamaChatRequest: Encodable {
    let model: String
    let messages: [SummaryMessage]
    let stream: Bool
    let options: OllamaChatOptions
}

struct OllamaChatOptions: Encodable {
    let numCtx: Int

    enum CodingKeys: String, CodingKey {
        case numCtx = "num_ctx"
    }
}

struct OllamaChatResponse: Decodable {
    let message: SummaryMessage
}
