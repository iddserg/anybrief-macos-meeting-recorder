import Foundation

extension SummarizationService {
    func yamlScalar(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    func summaryProviderFrontmatter(_ provider: SummaryProviderMetadata) -> [String] {
        var lines = [
            "summary_provider:",
            "  type: \(yamlScalar(provider.type.rawValue))",
            "  title: \(yamlScalar(provider.title))",
        ]
        if !provider.model.isEmpty {
            lines.append("  model: \(yamlScalar(provider.model))")
        }
        if let apiURL = provider.apiURL, !apiURL.isEmpty {
            lines.append("  api_url: \(yamlScalar(apiURL))")
        }
        lines.append("  timeout_sec: \(provider.timeoutSec)")
        if let retryCount = provider.retryCount {
            lines.append("  retry_count: \(retryCount)")
        }
        if let commandPreset = provider.commandPreset, !commandPreset.isEmpty {
            lines.append("  command_preset: \(yamlScalar(commandPreset))")
        }
        if let commandLine = provider.commandLine, !commandLine.isEmpty {
            lines.append("  command: \(yamlScalar(commandLine))")
        }
        if let ollamaContextLength = provider.ollamaContextLength {
            lines.append("  context_length: \(ollamaContextLength)")
        }
        if let ollamaChunkThreshold = provider.ollamaChunkThreshold {
            lines.append("  chunk_threshold: \(ollamaChunkThreshold)")
        }
        if let ollamaChunkSize = provider.ollamaChunkSize {
            lines.append("  chunk_size: \(ollamaChunkSize)")
        }
        return lines
    }

    func metadataFrontmatter(_ metadata: SummaryMetadata) -> [String] {
        var lines = [
            "transcription:",
            "  provider: \(yamlScalar(metadata.transcription.provider))",
            "  model: \(yamlScalar(metadata.transcription.model))",
        ]
        if let language = metadata.transcription.language, !language.isEmpty {
            lines.append("  language: \(yamlScalar(language))")
        }
        if let acceleration = metadata.transcription.acceleration, !acceleration.isEmpty {
            lines.append("  acceleration: \(yamlScalar(acceleration))")
        }
        lines.append(contentsOf: [
            "  diarization_enabled: \(metadata.transcription.diarizationEnabled)",
            "  speakers_mode: \(yamlScalar(metadata.transcription.speakersMode))",
            "  speakers_count: \(metadata.transcription.speakersCount)",
            "  system_speakers: \(yamlScalar(metadata.transcription.systemSpeakers))",
            "  microphone_speakers: \(metadata.transcription.microphoneSpeakers)",
            "  threshold: \(format(metadata.transcription.threshold))",
            "audio:",
        ])
        lines.append(contentsOf: trackFrontmatter("system", metadata.audio.system))
        lines.append(contentsOf: trackFrontmatter("microphone", metadata.audio.microphone))
        if let calendar = metadata.calendar {
            lines.append(contentsOf: calendarFrontmatter(calendar))
        }
        if !metadata.warnings.isEmpty {
            lines.append("warnings:")
            lines.append(contentsOf: metadata.warnings.map { "  - \(yamlScalar($0))" })
        }
        return lines
    }

    func preservedMetadataFrontmatter(from frontmatter: String) -> [String] {
        let generatedKeys = [
            "date:",
            "duration:",
            "speakers:",
            "model:",
            "summary_provider:",
            "status:",
            "summary_error:",
            "warnings:",
        ]
        var preserved: [String] = []
        var skippingGeneratedBlock = false
        for line in frontmatter.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isTopLevelLine = !trimmed.isEmpty && line == trimmed
            if generatedKeys.contains(where: { trimmed.hasPrefix($0) }) {
                skippingGeneratedBlock = trimmed.hasSuffix(":")
                continue
            }
            if skippingGeneratedBlock, !isTopLevelLine {
                continue
            }
            skippingGeneratedBlock = false
            preserved.append(line)
        }
        return preserved
    }

    func calendarFrontmatter(_ event: CalendarEvent) -> [String] {
        var lines = [
            "calendar:",
            "  uid: \(yamlScalar(event.uid))",
            "  original_uid: \(yamlScalar(event.originalUID))",
            "  calendar_name: \(yamlScalar(event.calendarName))",
            "  title: \(yamlScalar(event.title))",
            "  start_at: \(yamlScalar(isoFormatter.string(from: event.startAt)))",
            "  end_at: \(yamlScalar(isoFormatter.string(from: event.endAt)))",
            "  timezone: \(yamlScalar(event.timeZone))",
            "  participant_count: \(event.participantCount)",
            "  has_meeting_url: \(event.hasMeetingURL)",
        ]
        if let location = event.location, !location.isEmpty {
            lines.append("  location: \(yamlScalar(location))")
        }
        if let notes = event.notes, !notes.isEmpty {
            lines.append("  notes: \(yamlBlockScalar(notes, indent: 4))")
        }
        if !event.meetingURLs.isEmpty {
            lines.append("  meeting_urls:")
            lines.append(contentsOf: event.meetingURLs.map { "    - \(yamlScalar($0))" })
        }
        if let organizer = event.organizer {
            lines.append("  organizer:")
            lines.append(contentsOf: participantFrontmatter(organizer, indent: 4))
        }
        if !event.attendees.isEmpty {
            lines.append("  attendees:")
            for attendee in event.attendees {
                lines.append("    -")
                lines.append(contentsOf: participantFrontmatter(attendee, indent: 6))
            }
        }
        if let recurrenceRule = event.recurrenceRule, !recurrenceRule.isEmpty {
            lines.append("  recurrence_rule: \(yamlScalar(recurrenceRule))")
        }
        if let recurrenceID = event.recurrenceID {
            lines.append("  recurrence_id: \(yamlScalar(isoFormatter.string(from: recurrenceID)))")
        }
        return lines
    }

    func participantFrontmatter(_ participant: CalendarParticipant, indent: Int) -> [String] {
        let prefix = String(repeating: " ", count: indent)
        var lines: [String] = []
        if let name = participant.name, !name.isEmpty {
            lines.append("\(prefix)name: \(yamlScalar(name))")
        }
        if let email = participant.email, !email.isEmpty {
            lines.append("\(prefix)email: \(yamlScalar(email))")
        }
        if let role = participant.role, !role.isEmpty {
            lines.append("\(prefix)role: \(yamlScalar(role))")
        }
        if let status = participant.status, !status.isEmpty {
            lines.append("\(prefix)status: \(yamlScalar(status))")
        }
        if let rsvp = participant.rsvp {
            lines.append("\(prefix)rsvp: \(rsvp)")
        }
        return lines.isEmpty ? ["\(prefix){}"] : lines
    }

    func trackFrontmatter(_ name: String, _ track: SummaryAudioTrackMetadata) -> [String] {
        [
            "  \(name):",
            "    status: \(yamlScalar(track.status))",
            "    duration_sec: \(format(track.durationSeconds))",
            "    size_bytes: \(track.sizeBytes)",
            "    segments: \(track.segments)",
            "    speakers: \(track.speakers)",
        ]
    }

    func format(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded.rounded() == rounded {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.2f", rounded)
    }

    func yamlBlockScalar(_ value: String, indent: Int) -> String {
        let prefix = String(repeating: " ", count: indent)
        let body = value
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "\(prefix)\($0)" }
            .joined(separator: "\n")
        return "|\n\(body)"
    }
}
