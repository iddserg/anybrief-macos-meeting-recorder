import Foundation

/// Merges system and microphone transcript tracks and writes final transcript files.
actor TranscriptMergeService {
    private let fileManager: FileManager
    private let encoder: JSONEncoder

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func merge(system: [TranscriptSegment], mic: [TranscriptSegment]) -> [TranscriptSegment] {
        (system + mic).sorted { lhs, rhs in
            if lhs.startTime != rhs.startTime {
                return lhs.startTime < rhs.startTime
            }

            return sourcePriority(lhs.sourceTrack) < sourcePriority(rhs.sourceTrack)
        }
    }

    func write(system: [TranscriptSegment], mic: [TranscriptSegment], meetingFolder: URL) throws -> [TranscriptSegment] {
        let segments = merge(system: system, mic: mic)
        try fileManager.createDirectory(at: meetingFolder, withIntermediateDirectories: true)

        let jsonURL = meetingFolder.appendingPathComponent("transcript_merged.json", isDirectory: false)
        let textURL = meetingFolder.appendingPathComponent("transcript.txt", isDirectory: false)

        try encoder.encode(segments).write(to: jsonURL, options: .atomic)
        let text = makePlainText(from: segments)
        try text.write(to: meetingFolder.appendingPathComponent("transcript_raw.txt"), atomically: true, encoding: .utf8)
        try text.write(to: textURL, atomically: true, encoding: .utf8)
        return segments
    }

    /// Recovery of older jobs must rebuild the input from recognition results,
    /// never from transcript.txt, which may already contain an LLM response.
    func rawTranscript(in meetingFolder: URL) throws -> String {
        let rawURL = meetingFolder.appendingPathComponent("transcript_raw.txt")
        if fileManager.fileExists(atPath: rawURL.path) {
            return try String(contentsOf: rawURL, encoding: .utf8)
        }
        let data = try Data(contentsOf: meetingFolder.appendingPathComponent("transcript_merged.json"))
        let segments = try JSONDecoder().decode([TranscriptSegment].self, from: data)
        let text = makePlainText(from: segments)
        try text.write(to: rawURL, atomically: true, encoding: .utf8)
        return text
    }

    private func sourcePriority(_ sourceTrack: SourceTrack) -> Int {
        switch sourceTrack {
        case .system:
            return 0
        case .mic:
            return 1
        }
    }

    private func makePlainText(from segments: [TranscriptSegment]) -> String {
        segments
            .map { "[\(formatTimestamp($0.startTime))] \($0.speaker): \(inlineText($0.text))" }
            .joined(separator: "\n")
            .appending(segments.isEmpty ? "" : "\n")
    }

    /// Collapses internal newlines so each segment occupies exactly one line in transcript.txt.
    private func inlineText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func formatTimestamp(_ time: TimeInterval) -> String {
        let totalMilliseconds = Int((time * 1_000).rounded())
        let hours = totalMilliseconds / 3_600_000
        let minutes = totalMilliseconds / 60_000 % 60
        let seconds = totalMilliseconds / 1_000 % 60
        let milliseconds = totalMilliseconds % 1_000

        return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, milliseconds)
    }
}
