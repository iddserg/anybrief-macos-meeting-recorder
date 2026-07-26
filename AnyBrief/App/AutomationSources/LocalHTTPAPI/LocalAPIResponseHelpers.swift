import Foundation

extension LocalAPIHandlers {
    var allowedOrigins: Set<String> {
        ["http://127.0.0.1", "http://localhost"]
    }

    var iso8601: ISO8601DateFormatter {
        LocalAPIResponseFormatting.iso8601
    }

    func currentRecordingPayload(for session: RecordingSession) -> [String: Any] {
        [
            "jobId": session.jobId,
            "meetingId": session.jobId,
            "status": "recording",
            "source": session.source,
            "title": session.title,
            "startedAt": iso8601.string(from: session.startedAt),
            "autoStopDisabled": session.autoStopDisabled,
            "microphoneDegraded": session.microphoneDegraded,
            "warnings": session.recordingWarnings,
        ]
    }

    func jobPayload(_ job: Job) -> [String: Any] {
        [
            "id": job.id,
            "meetingId": job.meetingId,
            "status": job.status,
            "stage": job.stage.rawValue,
            "progressPercent": job.progressPercent ?? 0,
            "source": job.source,
            "createdAt": iso8601.string(from: job.createdAt),
            "updatedAt": iso8601.string(from: job.updatedAt),
            "completedAt": job.completedAt.map(iso8601.string(from:)) as Any,
            "warnings": job.warnings,
            "error": job.error.map { error in
                [
                    "code": error.code,
                    "message": error.message,
                    "stage": error.stage as Any,
                    "retryable": error.retryable,
                ]
            } as Any,
        ]
    }

    func meetingPayload(_ meeting: MeetingRecord) -> [String: Any] {
        [
            "id": meeting.job.meetingId,
            "jobId": meeting.job.id,
            "title": meeting.title,
            "status": meeting.job.status,
            "stage": meeting.job.stage.rawValue,
            "createdAt": iso8601.string(from: meeting.job.createdAt),
            "summaryPath": meeting.summaryURL?.path as Any,
            "zipPath": meeting.bundleURL?.path as Any,
            "transcriptPath": meeting.transcriptTextURL?.path as Any,
            "fallbackSummary": meeting.summaryURL.map(isFallbackSummary(url:)) ?? false,
        ]
    }

    func permissionRow(kind: PermissionService.PermissionKind, apiKind: String) async -> [String: Any] {
        let status = await permissionService.check(kind)
        return [
            "kind": apiKind,
            "status": permissionLabel(status),
            "lastCheckedAt": await permissionService.lastCheckedAt(for: kind).map(iso8601.string(from:)) as Any,
        ]
    }

    func permissionLabel(_ status: PermissionService.PermissionStatus) -> String {
        switch status {
        case .granted:
            return "granted"
        case .denied:
            return "missing"
        case .notDetermined:
            return "unknown"
        }
    }

    func pagination(from query: [String: String]) throws -> (limit: Int, offset: Int) {
        let limit = min(max(Int(query["limit"] ?? "50") ?? 50, 1), 500)
        let offset = try decodeCursor(query["cursor"])
        return (limit, offset)
    }

    func decodeCursor(_ value: String?) throws -> Int {
        guard let value, !value.isEmpty else {
            return 0
        }
        guard let data = Data(base64Encoded: value),
              let text = String(data: data, encoding: .utf8),
              let offset = Int(text), offset >= 0 else {
            throw APIError(status: 400, code: "invalid_request", message: "Invalid cursor.")
        }
        return offset
    }

    func encodeCursor(_ offset: Int) -> String {
        Data(String(offset).utf8).base64EncodedString()
    }

    func enforceCooldown(_ lastEventAt: Date?, seconds: TimeInterval, code: String, message: String) throws {
        guard let lastEventAt, Date().timeIntervalSince(lastEventAt) < seconds else {
            return
        }
        throw APIError(status: 409, code: code, message: message)
    }

    func jsonResponse(_ payload: Any, request: HTTPRequest) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return response(status: 200, body: data, contentType: "application/json", request: request)
    }

    func errorResponse(
        status: Int,
        code: String,
        message: String,
        details: [String: Any] = [:],
        request: HTTPRequest
    ) -> HTTPResponse {
        jsonResponse([
            "error": [
                "code": code,
                "message": message,
                "details": details,
            ],
        ], request: request, status: status)
    }

    func jsonResponse(_ payload: Any, request: HTTPRequest, status: Int) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return response(status: status, body: data, contentType: "application/json", request: request)
    }

    func response(status: Int, body: Data, contentType: String?, request: HTTPRequest) -> HTTPResponse {
        var headers = [
            "Content-Length": "\(body.count)",
            "Connection": "close",
        ]
        if let contentType {
            headers["Content-Type"] = contentType
        }
        if let origin = request.headers["origin"], allowedOrigins.contains(origin) {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Access-Control-Allow-Headers"] = "Content-Type, X-API-Key"
            headers["Access-Control-Allow-Methods"] = "GET, POST, PUT, OPTIONS"
            headers["Vary"] = "Origin"
        }
        return HTTPResponse(statusCode: status, headers: headers, body: body)
    }

    func logRequest(_ request: HTTPRequest) async {
        let apiKey = request.headers["x-api-key"] != nil ? "***" : "<missing>"
        let origin = request.headers["origin"] ?? "<none>"
        await loggingService.log(
            "HTTP \(request.method) \(request.path) origin=\(origin) X-API-Key: \(apiKey)",
            level: .info,
            component: "LocalAPI"
        )
    }
}

private enum LocalAPIResponseFormatting {
    static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = .current
        return formatter
    }()
}
