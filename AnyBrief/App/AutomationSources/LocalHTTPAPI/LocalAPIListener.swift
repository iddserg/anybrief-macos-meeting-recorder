import Foundation
import Network

protocol LocalAPIListenerFactoryProtocol {
    func makeListener(port: UInt16) throws -> NWListener
}

struct LocalAPIListenerFactory: LocalAPIListenerFactoryProtocol {
    func makeListener(port: UInt16) throws -> NWListener {
        let parameters = listenerParameters(port: port)
        return try NWListener(using: parameters)
    }

    func listenerParameters(port: UInt16) -> NWParameters {
        let parameters = NWParameters.tcp
        let nwPort = NWEndpoint.Port(rawValue: port) ?? 47_823
        let host = NWEndpoint.Host.ipv4(IPv4Address("127.0.0.1")!)
        parameters.requiredLocalEndpoint = .hostPort(host: host, port: nwPort)
        return parameters
    }
}

final class LocalAPIListener {
    typealias StateHandler = @Sendable (NWListener.State) -> Void
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let factory: LocalAPIListenerFactoryProtocol
    private let queue = DispatchQueue(label: "pro.anybrief.local-api")
    private var listener: NWListener?
    private var listenerPort: UInt16?

    init(factory: LocalAPIListenerFactoryProtocol = LocalAPIListenerFactory()) {
        self.factory = factory
    }

    func start(
        port: UInt16,
        stateHandler: @escaping StateHandler,
        requestHandler: @escaping RequestHandler
    ) throws {
        guard listenerPort != port || listener == nil else {
            return
        }

        stop()

        let listener = try factory.makeListener(port: port)
        listener.stateUpdateHandler = stateHandler
        listener.newConnectionHandler = { [queue] connection in
            let handler = HTTPConnectionHandler(
                connection: connection,
                queue: queue,
                requestHandler: requestHandler
            )
            handler.start()
        }
        listener.start(queue: queue)
        self.listener = listener
        listenerPort = port
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listenerPort = nil
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var pathComponents: [String] {
        path.split(separator: "/").map(String.init)
    }

    func jsonObject() throws -> [String: Any] {
        guard !body.isEmpty else {
            return [:]
        }
        let object = try JSONSerialization.jsonObject(with: body)
        guard let object = object as? [String: Any] else {
            throw APIError(status: 400, code: "invalid_request", message: "Expected a JSON object body.")
        }
        return object
    }
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    func encoded() -> Data {
        var response = "HTTP/1.1 \(statusCode) \(Self.reasonPhrase(for: statusCode))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = Data(response.utf8)
        data.append(body)
        return data
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 409: return "Conflict"
        case 413: return "Payload Too Large"
        case 422: return "Unprocessable Entity"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}

private final class HTTPConnectionHandler {
    /// Caps for a localhost API: headers stay small, bodies are settings-sized JSON.
    static let maxHeaderBytes = 64 * 1024
    static let maxBodyBytes = 10 * 1024 * 1024

    private enum ParseOutcome {
        case incomplete
        case request(HTTPRequest)
        case tooLarge
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let requestHandler: LocalAPIListener.RequestHandler
    private var buffer = Data()

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        requestHandler: @escaping LocalAPIListener.RequestHandler
    ) {
        self.connection = connection
        self.queue = queue
        self.requestHandler = requestHandler
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                return
            }
            if let data {
                self.buffer.append(data)
            }
            switch Self.parseRequest(from: self.buffer) {
            case let .request(request):
                Task { [weak self] in
                    guard let self else {
                        return
                    }
                    let response = await self.requestHandler(request)
                    self.send(response)
                }
                return
            case .tooLarge:
                self.send(Self.emptyResponse(statusCode: 413))
                return
            case .incomplete:
                break
            }
            if isComplete || error != nil {
                self.send(Self.emptyResponse(statusCode: 400))
                return
            }
            self.receive()
        }
    }

    private func send(_ response: HTTPResponse) {
        connection.send(content: response.encoded(), completion: .contentProcessed { [weak self] _ in
            self?.connection.cancel()
        })
    }

    private static func emptyResponse(statusCode: Int) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": "0",
                "Connection": "close",
            ],
            body: Data()
        )
    }

    private static func parseRequest(from data: Data) -> ParseOutcome {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maxHeaderBytes ? .tooLarge : .incomplete
        }
        guard headerRange.lowerBound <= maxHeaderBytes else {
            return .tooLarge
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return .incomplete
        }
        let headerLines = headerString.split(separator: "\r\n").map(String.init)
        guard let requestLine = headerLines.first else {
            return .incomplete
        }

        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLineParts.count >= 2 else {
            return .incomplete
        }

        var headers: [String: String] = [:]
        for line in headerLines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else {
                continue
            }
            headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
        }

        let contentLength = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        guard contentLength <= maxBodyBytes else {
            return .tooLarge
        }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else {
            return .incomplete
        }

        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        let target = String(requestLineParts[1])
        let components = URLComponents(string: "http://127.0.0.1\(target)")
        let query = Dictionary(
            (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
            uniquingKeysWith: { _, last in last }
        )

        return .request(HTTPRequest(
            method: String(requestLineParts[0]),
            path: components?.path ?? target,
            query: query,
            headers: headers,
            body: body
        ))
    }
}
