import Foundation

struct OllamaModel: Identifiable, Equatable {
    let id: String
    let name: String
}

enum OllamaModelDiscoveryError: LocalizedError {
    case unavailable(detail: String)
    case noModels

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail):
            return "Could not connect to local Ollama: \(detail)"
        case .noModels:
            return "Ollama is running, but no local models were found."
        }
    }
}

/// Loads local model names from Ollama's discovery endpoints.
/// Docs:
/// - https://docs.ollama.com/api/tags
/// - https://docs.ollama.com/openai
actor OllamaModelDiscoveryService {
    struct ContextInfo: Equatable {
        let runningContextLength: Int?
        let modelMaxContextLength: Int?
        let modelfileContextLength: Int?
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable {
            let name: String
        }

        let models: [Model]
    }

    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func fetchModels() async throws -> [String] {
        guard let url = URL(string: OllamaDefaults.tagsURLString) else {
            throw OllamaModelDiscoveryError.unavailable(detail: "Invalid discovery URL.")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            throw OllamaModelDiscoveryError.unavailable(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaModelDiscoveryError.unavailable(detail: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaModelDiscoveryError.unavailable(detail: "HTTP \(http.statusCode).")
        }

        let decoded: TagsResponse
        do {
            decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        } catch {
            throw OllamaModelDiscoveryError.unavailable(detail: "Invalid response payload.")
        }

        let models = Array(Set(decoded.models.map(\.name).filter { !$0.isEmpty })).sorted()
        guard !models.isEmpty else {
            throw OllamaModelDiscoveryError.noModels
        }
        return models
    }

    func fetchContextInfo(for model: String) async throws -> ContextInfo {
        async let runningContextLength = fetchRunningContextLength(for: model)
        async let showContextInfo = fetchShowContextInfo(for: model)
        let (running, show) = try await (runningContextLength, showContextInfo)
        return ContextInfo(
            runningContextLength: running,
            modelMaxContextLength: show.modelMaxContextLength,
            modelfileContextLength: show.modelfileContextLength
        )
    }

    private func fetchRunningContextLength(for model: String) async throws -> Int? {
        guard let url = URL(string: OllamaDefaults.psURLString) else {
            throw OllamaModelDiscoveryError.unavailable(detail: "Invalid ps URL.")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: url)
        } catch {
            throw OllamaModelDiscoveryError.unavailable(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaModelDiscoveryError.unavailable(detail: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaModelDiscoveryError.unavailable(detail: "HTTP \(http.statusCode).")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else {
            throw OllamaModelDiscoveryError.unavailable(detail: "Invalid ps response payload.")
        }

        let selected = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let runningModel = models.first { item in
            let name = item["model"] as? String ?? item["name"] as? String ?? ""
            return name == selected || name.hasPrefix(selected + ":") || selected.hasPrefix(name + ":")
        }
        return runningModel?["context_length"] as? Int
    }

    private func fetchShowContextInfo(for model: String) async throws -> ContextInfo {
        guard let url = URL(string: OllamaDefaults.showURLString) else {
            throw OllamaModelDiscoveryError.unavailable(detail: "Invalid show URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.trimmingCharacters(in: .whitespacesAndNewlines),
        ])

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch {
            throw OllamaModelDiscoveryError.unavailable(detail: error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw OllamaModelDiscoveryError.unavailable(detail: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw OllamaModelDiscoveryError.unavailable(detail: "HTTP \(http.statusCode).")
        }

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OllamaModelDiscoveryError.unavailable(detail: "Invalid show response payload.")
        }

        let modelInfo = root["model_info"] as? [String: Any] ?? [:]
        let modelMaxContextLength = modelInfo
            .filter { $0.key.hasSuffix(".context_length") }
            .compactMap { $0.value as? Int }
            .max()
        let modelfileContextLength = Self.parseModelfileContextLength(from: root["parameters"] as? String)

        return ContextInfo(
            runningContextLength: nil,
            modelMaxContextLength: modelMaxContextLength,
            modelfileContextLength: modelfileContextLength
        )
    }

    private static func parseModelfileContextLength(from parameters: String?) -> Int? {
        guard let parameters else { return nil }
        for line in parameters.components(separatedBy: .newlines) {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count == 2, parts[0] == "num_ctx", let value = Int(parts[1]) {
                return value
            }
        }
        return nil
    }
}
