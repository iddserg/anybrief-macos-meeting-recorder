import AVFoundation
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

    /// Native media decoding supports Voice Memos and movie containers without
    /// adding video codecs to the small ffmpeg binary used by finalization.
    func importAudio(inputURL: URL, outputURL: URL, logURL: URL) async throws {
        try prepareOutput(at: outputURL)
        let asset = AVURLAsset(url: inputURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw TranscriptionError(message: String(localized: "The file has no readable audio. Choose another file."))
        }
        let pcm: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcm)
        reader.add(output)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        do {
            try Task.checkCancellation()
            guard reader.startReading(), writer.startWriting() else {
                throw reader.error ?? writer.error ?? TranscriptionError(message: "Audio decoder could not start.")
            }
            writer.startSession(atSourceTime: .zero)
            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    guard writer.status == .writing else {
                        throw writer.error ?? TranscriptionError(message: "Audio writer stopped.")
                    }
                    try await Task.sleep(for: .milliseconds(10))
                }
                guard input.append(sample) else {
                    throw writer.error ?? TranscriptionError(message: "Audio conversion failed.")
                }
            }
            guard reader.status == .completed else {
                throw reader.error ?? TranscriptionError(message: "Audio decoding failed.")
            }
            input.markAsFinished()
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else {
                throw writer.error ?? TranscriptionError(message: "Audio conversion failed.")
            }
            try "Imported audio: mono, 16000 Hz\n".write(to: logURL, atomically: true, encoding: .utf8)
        } catch {
            reader.cancelReading()
            writer.cancelWriting()
            if Task.isCancelled || error is CancellationError { throw CancellationError() }
            try? error.localizedDescription.write(to: logURL, atomically: true, encoding: .utf8)
            throw TranscriptionError(message: String(localized: "The file has no readable audio. Choose another file."))
        }
    }
}
