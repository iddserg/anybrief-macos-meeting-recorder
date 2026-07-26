import Foundation

extension LocalAPIHandlers {
    func handleJobs(request: HTTPRequest) async throws -> HTTPResponse {
        let jobs = await jobRepository.load().sorted { $0.updatedAt > $1.updatedAt }
        let (limit, offset) = try pagination(from: request.query)
        let page = Array(jobs.dropFirst(offset).prefix(limit))
        let nextCursor = offset + page.count < jobs.count ? encodeCursor(offset + page.count) : nil

        return jsonResponse([
            "items": page.map(jobPayload),
            "nextCursor": nextCursor as Any,
        ], request: request)
    }

    func handleJobRoute(request: HTTPRequest) async throws -> HTTPResponse {
        let components = request.pathComponents
        guard components.count >= 2 else {
            throw APIError(status: 404, code: "not_found", message: "Job route not found.")
        }
        let jobID = components[1]

        if request.method == "POST", components.count == 3, components[2] == "cancel" {
            return try await handleJobCancel(jobID: jobID, request: request)
        }

        guard request.method == "GET", components.count == 2 else {
            throw APIError(status: 404, code: "not_found", message: "Job route not found.")
        }
        guard let job = await jobRepository.get(id: jobID) else {
            throw APIError(status: 404, code: "not_found", message: "Job not found.")
        }
        return jsonResponse(jobPayload(job), request: request)
    }

    func handleJobCancel(jobID: String, request: HTTPRequest) async throws -> HTTPResponse {
        guard let job = await jobRepository.get(id: jobID) else {
            throw APIError(status: 404, code: "not_found", message: "Job not found.")
        }
        guard !job.isTerminal else {
            throw APIError(status: 409, code: "job_not_cancellable", message: "Job is already terminal.")
        }
        if job.stage == .packaging || job.stage == .completed || job.stage == .partialSuccess {
            throw APIError(status: 409, code: "job_not_cancellable", message: "Job can no longer be cancelled.")
        }

        if let currentSession = await recordingAdapter.currentSession(), currentSession.jobId == jobID {
            let cancelledJob = try await recordingAdapter.cancel(jobId: jobID)
            return jsonResponse(["id": cancelledJob.id, "status": cancelledJob.status], request: request)
        }
        guard let cancelledJob = await pipelineOrchestrator.cancel(jobId: jobID) else {
            throw APIError(status: 409, code: "job_not_cancellable", message: "Job is not cancellable at this stage.")
        }
        return jsonResponse(["id": cancelledJob.id, "status": cancelledJob.status], request: request)
    }

    func handleMeetingsToday(request: HTTPRequest) async throws -> HTTPResponse {
        let meetings = try await meetings()
        let today = Calendar.current
        return jsonResponse([
            "items": meetings.filter { today.isDateInToday($0.job.createdAt) }.map(meetingPayload),
        ], request: request)
    }

    func handleMeetingsRecent(request: HTTPRequest) async throws -> HTTPResponse {
        let allMeetings = try await meetings().sorted { $0.job.createdAt > $1.job.createdAt }
        let (limit, offset) = try pagination(from: request.query)
        let page = Array(allMeetings.dropFirst(offset).prefix(limit))
        let nextCursor = offset + page.count < allMeetings.count ? encodeCursor(offset + page.count) : nil
        return jsonResponse([
            "items": page.map(meetingPayload),
            "nextCursor": nextCursor as Any,
        ], request: request)
    }

    func handleMeetingRoute(request: HTTPRequest) async throws -> HTTPResponse {
        let components = request.pathComponents
        guard components.count >= 2 else {
            throw APIError(status: 404, code: "not_found", message: "Meeting route not found.")
        }
        let meetingID = components[1]
        let meeting = try await loadMeeting(id: meetingID)

        if components.count == 2 {
            return jsonResponse(meetingPayload(meeting), request: request)
        }
        if components.count == 3, components[2] == "summary" {
            guard let summaryURL = meeting.summaryURL,
                  let data = try? Data(contentsOf: summaryURL) else {
                throw APIError(status: 404, code: "not_found", message: "Meeting summary not found.")
            }
            return response(status: 200, body: data, contentType: "text/markdown; charset=utf-8", request: request)
        }
        if components.count == 3, components[2] == "transcript" {
            if request.query["format"] == "txt" {
                guard let textURL = meeting.transcriptTextURL,
                      let data = try? Data(contentsOf: textURL) else {
                    throw APIError(status: 404, code: "not_found", message: "Meeting transcript not found.")
                }
                return response(status: 200, body: data, contentType: "text/plain; charset=utf-8", request: request)
            }
            guard let jsonURL = meeting.transcriptJSONURL,
                  let data = try? Data(contentsOf: jsonURL) else {
                throw APIError(status: 404, code: "not_found", message: "Meeting transcript JSON not found.")
            }
            return response(status: 200, body: data, contentType: "application/json", request: request)
        }

        throw APIError(status: 404, code: "not_found", message: "Meeting route not found.")
    }

    func loadMeeting(id: String) async throws -> MeetingRecord {
        guard let meeting = try await meetings().first(where: { $0.job.meetingId == id }) else {
            throw APIError(status: 404, code: "not_found", message: "Meeting not found.")
        }
        return meeting
    }

    func meetings() async throws -> [MeetingRecord] {
        let jobs = await jobRepository.load().sorted { $0.createdAt > $1.createdAt }
        return jobs.compactMap { job in
            guard let paths = try? storageService.findMeetingPaths(jobId: job.id, createdAt: job.createdAt) else {
                return nil
            }
            let summaryURL = paths.folderURL.appendingPathComponent("summary.md", isDirectory: false)
            let transcriptTextURL = paths.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
            let transcriptJSONURL = paths.folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
            let bundleURL = paths.folderURL.appendingPathComponent("bundle.zip", isDirectory: false)
            let hasSummary = fileManager.fileExists(atPath: summaryURL.path)
            let title = meetingTitle(folderURL: paths.folderURL, summaryURL: hasSummary ? summaryURL : nil)
            return MeetingRecord(
                job: job,
                folderURL: paths.folderURL,
                title: title,
                summaryURL: hasSummary ? summaryURL : nil,
                transcriptTextURL: fileManager.fileExists(atPath: transcriptTextURL.path) ? transcriptTextURL : nil,
                transcriptJSONURL: fileManager.fileExists(atPath: transcriptJSONURL.path) ? transcriptJSONURL : nil,
                bundleURL: fileManager.fileExists(atPath: bundleURL.path) ? bundleURL : nil
            )
        }
    }

    func meetingTitle(folderURL: URL, summaryURL: URL?) -> String {
        guard let summaryURL,
              let content = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            return folderURL.lastPathComponent
        }
        let contentLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let stripped = stripFrontmatter(lines: contentLines)
        return stripped.first(where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#")
        }) ?? folderURL.lastPathComponent
    }

    func stripFrontmatter(lines: [String]) -> [String] {
        guard lines.first == "---" else {
            return lines
        }
        guard let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return lines
        }
        return Array(lines[(closingIndex + 1)...])
    }

    func isFallbackSummary(url: URL) -> Bool {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return false
        }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.first == "---",
              let closingIndex = lines.dropFirst().firstIndex(of: "---") else {
            return false
        }
        let frontmatter = lines[1..<closingIndex].joined(separator: "\n")
        return frontmatter.contains("status: partial_success")
    }
}
