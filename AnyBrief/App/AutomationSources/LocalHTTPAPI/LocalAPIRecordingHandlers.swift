import Foundation

extension LocalAPIHandlers {
    func handleStatus(request: HTTPRequest) async throws -> HTTPResponse {
        let currentSession = await recordingAdapter.currentSession()
        let jobs = await jobRepository.load()
        let activeJob = jobs.first { !$0.isTerminal }

        let microphone = await permissionService.check(.microphone)
        let systemAudio = await permissionService.check(.screenRecording)
        let notifications = await permissionService.check(.notifications)
        let settings = await appSettingsStore.load(using: loggingService)
        let calendarConnected = isCalendarConnected(settings)

        return jsonResponse([
            "app": "running",
            "recording": currentSession != nil,
            "currentJobId": currentSession?.jobId as Any,
            "calendarConnected": calendarConnected,
            "permissions": [
                "microphone": permissionLabel(microphone),
                "systemAudio": permissionLabel(systemAudio),
                "calendar": calendarConnected ? "granted" : "missing",
                "notifications": permissionLabel(notifications),
            ],
            "currentStage": currentSession != nil ? "recording" : (activeJob?.stage.rawValue as Any),
        ], request: request)
    }

    func handlePermissions(request: HTTPRequest) async throws -> HTTPResponse {
        let rows = await [
            permissionRow(kind: .microphone, apiKind: "microphone"),
            permissionRow(kind: .screenRecording, apiKind: "system_audio"),
            calendarConnectionRow(),
            permissionRow(kind: .notifications, apiKind: "notifications"),
        ]
        return jsonResponse(["permissions": rows], request: request)
    }

    func handleRecordingStart(request: HTTPRequest) async throws -> HTTPResponse {
        try enforceCooldown(lastRecordingStartAt, seconds: 2, code: "invalid_state", message: "Recording start is rate-limited.")
        let body = try request.jsonObject()
        let title = (body["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let session = try await recordingAdapter.start(
            jobId: JobIDGenerator.make(),
            source: "manual",
            title: title?.isEmpty == false ? title! : "Manual recording"
        )
        lastRecordingStartAt = Date()
        return jsonResponse([
            "jobId": session.jobId,
            "meetingId": session.jobId,
            "status": "recording",
        ], request: request)
    }

    func handleRecordingStop(request: HTTPRequest) async throws -> HTTPResponse {
        let body = try request.jsonObject()
        let requestedJobID = body["jobId"] as? String
        if let requestedJobID,
           let currentSession = await recordingAdapter.currentSession(),
           currentSession.jobId != requestedJobID {
            throw APIError(status: 409, code: "no_active_recording", message: "Requested job is not the active recording.")
        }

        let session = try await recordingAdapter.stop()
        await pipelineOrchestrator.enqueue(session: session)
        return jsonResponse([
            "jobId": session.jobId,
            "meetingId": session.jobId,
            "status": "recorded",
        ], request: request)
    }

    func handleDisableAutoStop(request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let session = try await recordingAdapter.disableAutoStop()
            return jsonResponse([
                "jobId": session.jobId,
                "autoStopDisabled": session.autoStopDisabled,
            ], request: request)
        } catch is NoActiveRecordingError {
            throw APIError(status: 409, code: "no_active_recording", message: "There is no active recording.")
        } catch is NotCalendarRecordingError {
            throw APIError(status: 422, code: "not_a_calendar_recording", message: "Auto-stop can only be disabled for calendar recordings.")
        }
    }

    func handleCurrentRecording(request: HTTPRequest) async throws -> HTTPResponse {
        guard let session = await recordingAdapter.currentSession() else {
            return jsonResponse(NSNull(), request: request)
        }
        return jsonResponse(currentRecordingPayload(for: session), request: request)
    }
}
