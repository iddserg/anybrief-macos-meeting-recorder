import Foundation

/// Shared, backward-compatible access to metadata stored beside meeting artifacts.
enum MeetingMetadataStore {
    static let skipMicrophoneFilename = ".anybrief-skip-microphone"

    static func skipsMicrophone(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(skipMicrophoneFilename).path)
    }

    static func setSkipsMicrophone(_ excluded: Bool, in folder: URL) throws {
        let url = folder.appendingPathComponent(skipMicrophoneFilename)
        if excluded {
            try Data().write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    static let importFilename = ".anybrief-import"

    static func isImported(in folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(importFilename).path)
    }

    static let titleFilename = ".anybrief-title"
    static let calendarFilename = ".anybrief-autopilot.json"

    static func load(from folder: URL) -> AutopilotRecordingMetadata? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(calendarFilename)) else { return nil }
        return try? JSONDecoder().decode(AutopilotRecordingMetadata.self, from: data)
    }

    static func storedTitle(in folder: URL) -> String? {
        guard let title = try? String(contentsOf: folder.appendingPathComponent(titleFilename), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return nil }
        return title
    }

    static func title(in folder: URL) -> String {
        storedTitle(in: folder) ?? load(from: folder)?.calendarEvent?.title ?? fallbackTitle(in: folder)
    }

    static func fallbackTitle(in folder: URL) -> String {
        if let title = storedTitle(in: folder) { return title }
        var name = folder.lastPathComponent
        name = name.replacingOccurrences(of: #"^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}_"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"^[a-z0-9]{10}_"#, with: "", options: .regularExpression)
        name = name.replacingOccurrences(of: #"_\d+m$"#, with: "", options: .regularExpression)
        return name.isEmpty ? folder.lastPathComponent : name
    }

    static func write(title: String, metadata: AutopilotRecordingMetadata, to folder: URL) throws {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            try title.write(to: folder.appendingPathComponent(titleFilename), atomically: true, encoding: .utf8)
        }
        if metadata.calendarEventUID != nil || metadata.systemSpeakersOverride != nil || metadata.calendarEvent != nil {
            try JSONEncoder().encode(metadata).write(to: folder.appendingPathComponent(calendarFilename), options: .atomic)
        }
    }
}
