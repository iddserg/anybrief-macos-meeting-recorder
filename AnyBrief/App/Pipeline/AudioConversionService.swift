import Foundation

/// Converts audio between the canonical pipeline formats.
final class AudioConversionService {
    private let fileManager: FileManager
    private let ffmpegURLResolver: () throws -> URL

    init(
        fileManager: FileManager = .default,
        ffmpegURLResolver: @escaping () throws -> URL = CLIPathResolver.resolveFfmpeg
    ) {
        self.fileManager = fileManager
        self.ffmpegURLResolver = ffmpegURLResolver
    }

    func convertToMP3(inputURL: URL, outputURL: URL) throws {
        try prepareOutput(at: outputURL)

        let process = Process()
        process.executableURL = try ffmpegURLResolver()
        process.arguments = [
            "-y",
            "-i", inputURL.path,
            "-codec:a", "libmp3lame",
            "-qscale:a", "4",
            outputURL.path,
        ]
        try PipelineProcessRunner.run(
            process,
            errorContext: "ffmpeg failed converting \(inputURL.lastPathComponent)"
        )
    }

    /// Normalizes archived audio before STT. Both transcription engines receive
    /// the same uncompressed mono 16 kHz input instead of decoding MP3 themselves.
    func convertToTranscriptionWAV(inputURL: URL, outputURL: URL) throws {
        try prepareOutput(at: outputURL)

        let process = Process()
        process.executableURL = try ffmpegURLResolver()
        process.arguments = [
            "-y",
            "-i", inputURL.path,
            "-vn",
            "-ac", "1",
            "-ar", "16000",
            "-codec:a", "pcm_s16le",
            outputURL.path,
        ]
        try PipelineProcessRunner.run(
            process,
            errorContext: "ffmpeg failed normalizing \(inputURL.lastPathComponent) for transcription"
        )
    }

    private func prepareOutput(at outputURL: URL) throws {
        try fileManager.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: outputURL.path) {
            try fileManager.removeItem(at: outputURL)
        }
    }
}
