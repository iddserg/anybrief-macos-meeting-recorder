import Foundation

/// Presentation of the scalar metadata emitted by SummarizationService, not a general YAML parser.
struct MeetingTechnicalDetails: Sendable {
    struct Row: Identifiable, Sendable {
        let id: String
        let title: String
        let value: String
    }
    struct Section: Identifiable, Sendable {
        let id: String
        let title: String
        let rows: [Row]
    }
    let sections: [Section]
    var copyText: String {
        sections.map { section in
            ([section.title] + section.rows.map { "\($0.title): \($0.value)" }).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    init(summary: String) {
        let values = Self.scalars(in: summary)
        let definitions: [(String, String, [(String, String)])] = [
            ("", String(localized: "Recording details"), [
                ("date", String(localized: "Date")), ("duration", String(localized: "Duration (minutes)")),
                ("speakers", String(localized: "Speakers")), ("model", String(localized: "Model")),
                ("status", String(localized: "Status")), ("summary_error", String(localized: "Summary error"))]),
            ("summary_provider", String(localized: "Summary"), [
                ("type", String(localized: "Connection type")), ("title", String(localized: "Name")),
                ("model", String(localized: "Model")), ("api_url", String(localized: "API address")),
                ("timeout_sec", String(localized: "Timeout (sec)")), ("retry_count", String(localized: "Retries")),
                ("command_preset", String(localized: "Preset")), ("command", String(localized: "Command")),
                ("context_length", String(localized: "Context length")),
                ("chunk_threshold", String(localized: "Chunking threshold")), ("chunk_size", String(localized: "Chunk size"))]),
            ("transcription", String(localized: "Transcription"), [
                ("provider", String(localized: "Recognition engine")), ("model", String(localized: "Model")),
                ("language", String(localized: "Language")), ("acceleration", String(localized: "Acceleration")),
                ("diarization_enabled", String(localized: "Speaker separation")),
                ("speakers_mode", String(localized: "Speaker count mode")),
                ("speakers_count", String(localized: "Configured speaker count")),
                ("system_speakers", String(localized: "System audio speakers")),
                ("microphone_speakers", String(localized: "Microphone speakers")),
                ("threshold", String(localized: "Speaker separation threshold"))]),
            ("audio.system", String(localized: "System audio"), Self.audioFields),
            ("audio.microphone", String(localized: "Microphone"), Self.audioFields),
        ]
        sections = definitions.compactMap { prefix, title, fields in
            let rows = fields.compactMap { key, label -> Row? in
                let path = prefix.isEmpty ? key : "\(prefix).\(key)"
                guard let value = values[path] else { return nil }
                return Row(id: path, title: label, value: Self.display(value, key: key))
            }
            return rows.isEmpty ? nil : Section(id: prefix, title: title, rows: rows)
        }
    }

    private static var audioFields: [(String, String)] { [
        ("status", String(localized: "Status")), ("duration_sec", String(localized: "Duration (seconds)")),
        ("size_bytes", String(localized: "File size")), ("segments", String(localized: "Speech segments")),
        ("speakers", String(localized: "Speakers"))
    ] }

    static func scalars(in summary: String) -> [String: String] {
        let lines = summary.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") else { return [:] }
        var parents: [(indent: Int, key: String)] = []
        var result: [String: String] = [:]
        for line in lines[1..<end] {
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            while let last = parents.last, last.indent >= indent { parents.removeLast() }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon])
            guard !key.isEmpty, key.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { continue }
            let value = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            let path = (parents.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty || value == "|" || value == ">" {
                parents.append((indent, key))
            } else {
                result[path] = (try? JSONDecoder().decode(String.self, from: Data(value.utf8))) ?? value
            }
        }
        return result
    }

    private static func display(_ value: String, key: String) -> String {
        if value.isEmpty { return String(localized: "Not specified") }
        if key == "diarization_enabled" {
            if value == "true" { return String(localized: "Enabled") }
            if value == "false" { return String(localized: "Disabled") }
        }
        if key == "size_bytes", let bytes = Int64(value), bytes >= 0 {
            return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
                + " (\(bytes.formatted()) \(String(localized: "bytes")))"
        }
        if key == "date" {
            let parser = ISO8601DateFormatter()
            parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let dateWithFractions = parser.date(from: value)
            parser.formatOptions = [.withInternetDateTime]
            if let date = dateWithFractions ?? parser.date(from: value) {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .medium
                return formatter.string(from: date) + " (\(TimeZone.current.abbreviation(for: date) ?? TimeZone.current.identifier))"
            }
        }
        if ["provider", "type", "acceleration", "speakers_mode", "system_speakers", "status", "command_preset"].contains(key) {
            switch value {
            case "fluid_audio_stt": return "FluidAudio"
            case "whisper_cpp": return "Whisper.cpp"
            case "core_ml": return "Core ML"
            case "cli": return "CLI"
            case "openai_compatible": return "OpenAI-compatible API"
            case "ollama": return "Ollama"
            case "codex": return "Codex"
            case "claude": return "Claude"
            case "auto": return String(localized: "Automatic")
            case "fixed": return String(localized: "Fixed count")
            case "max": return String(localized: "Maximum count")
            case "disabled": return String(localized: "Disabled")
            case "recorded": return String(localized: "Recorded")
            case "recorded_no_speech": return String(localized: "Recorded, no speech detected")
            case "missing": return String(localized: "Audio file missing")
            case "invalid": return String(localized: "Invalid audio file")
            default: break
            }
        }
        return value
    }
}
