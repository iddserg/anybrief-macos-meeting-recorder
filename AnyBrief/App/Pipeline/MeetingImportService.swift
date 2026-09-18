import AVFoundation
import Foundation

/// Prepares a single imported audio track for the ordinary recording pipeline.
/// The selected file is read only; an incomplete preparation never creates a job.
actor MeetingImportService {
    private let storage: StorageServiceProtocol
    private let prepareAudio: @Sendable (URL, URL, URL) async throws -> Void

    init(storage: StorageServiceProtocol,
         prepareAudio: @escaping @Sendable (URL, URL, URL) async throws -> Void = { file, output, log in
             try await AudioConversionService().importAudio(inputURL: file, outputURL: output, logURL: log)
         }) {
        self.storage = storage
        self.prepareAudio = prepareAudio
    }

    func prepare(file: URL, title: String, date: Date) async throws -> RecordingSession {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw TranscriptionError(message: String(localized: "Choose an audio or video file."))
        }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw TranscriptionError(message: String(localized: "Enter a meeting title."))
        }
        try Task.checkCancellation()
        let jobID = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
        let paths = try storage.createMeetingFolder(jobId: jobID, startedAt: date)
        do {
            try FileManager.default.createDirectory(at: paths.jobLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await prepareAudio(file, paths.systemWavURL, paths.jobLogURL)
            let audio = try AVAudioFile(forReading: paths.systemWavURL)
            guard audio.length > 0 else {
                throw TranscriptionError(message: String(localized: "The file has no readable audio. Choose another file."))
            }
            try title.write(to: paths.folderURL.appendingPathComponent(MeetingMetadataStore.titleFilename), atomically: true, encoding: .utf8)
            try file.lastPathComponent.write(to: paths.folderURL.appendingPathComponent(MeetingMetadataStore.importFilename), atomically: true, encoding: .utf8)
            try Task.checkCancellation()
            return RecordingSession(jobId: jobID, pid: 0, paths: paths, startedAt: date,
                                    source: RecordingSession.fileImportSource, title: title, autoStopDisabled: true)
        } catch {
            try? FileManager.default.removeItem(at: paths.folderURL)
            throw error
        }
    }
}
