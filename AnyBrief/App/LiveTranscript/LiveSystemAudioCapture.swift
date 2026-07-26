import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class LiveSystemAudioCapture: NSObject, LiveAudioCapturing, SCStreamOutput, SCStreamDelegate {
    private let ringBuffer: LiveAudioRingBuffer
    private let fileManager: FileManager
    private let chunkSampleRate = 16_000.0
    private let captureQueue = DispatchQueue(label: "pro.anybrief.live-transcript-system-audio")
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?
    private var isCapturing = false
    private var receivedAudioBuffers = 0
    private var appendedAudioBuffers = 0
    private var droppedAudioBuffers = 0
    private var lastAudioAt: Date?
    private var lastDropReason: String?
    private lazy var workDirectoryURL = fileManager.temporaryDirectory
        .appendingPathComponent("anybrief-live-transcript-\(UUID().uuidString.lowercased())", isDirectory: true)

    init(
        maxBufferedDuration: TimeInterval = 35,
        fileManager: FileManager = .default
    ) {
        ringBuffer = LiveAudioRingBuffer(maxDuration: maxBufferedDuration)
        self.fileManager = fileManager
        super.init()
    }

    func start() async throws {
        guard !capturing else {
            return
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            NSLog("AnyBrief live transcript capture unavailable: no displays from SCShareableContent")
            throw LiveTranscriptError.audioCaptureUnavailable
        }
        NSLog(
            "AnyBrief live transcript capture preparing: displays=\(content.displays.count), windows=\(content.windows.count), apps=\(content.applications.count), displayID=\(display.displayID)"
        )

        try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
        ringBuffer.reset()
        resetCounters()

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        config.queueDepth = 8

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)
        setCapturing(true)

        do {
            try await stream.startCapture()
        } catch {
            setCapturing(false)
            recordDrop("stream start failed: \(error.localizedDescription)")
            NSLog("AnyBrief live transcript capture start failed: \(error.localizedDescription)")
            throw error
        }

        self.stream = stream
        NSLog("AnyBrief live transcript capture started: workDir=\(workDirectoryURL.path)")
    }

    func stop() async {
        setCapturing(false)
        let diagnostics = diagnostics()
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        captureQueue.sync {
            converter = nil
            converterInputFormat = nil
            converterOutputFormat = nil
        }
        ringBuffer.reset()
        try? fileManager.removeItem(at: workDirectoryURL)
        NSLog(
            "AnyBrief live transcript capture stopped: received=\(diagnostics.receivedAudioBuffers), appended=\(diagnostics.appendedAudioBuffers), dropped=\(diagnostics.droppedAudioBuffers), bufferedSeconds=\(String(format: "%.2f", diagnostics.bufferedDuration)), lastDrop=\(diagnostics.lastDropReason ?? "none")"
        )
    }

    func writeRecentChunk(duration: TimeInterval) async throws -> LiveAudioChunk? {
        guard let snapshot = ringBuffer.snapshot(duration: duration),
              snapshot.duration >= 2 else {
            return nil
        }

        try fileManager.createDirectory(at: workDirectoryURL, withIntermediateDirectories: true)
        let url = workDirectoryURL.appendingPathComponent(
            "live-\(Int(Date().timeIntervalSince1970 * 1000)).wav",
            isDirectory: false
        )
        try Self.write(samples: snapshot.samples, sampleRate: snapshot.sampleRate, targetSampleRate: chunkSampleRate, to: url)
        let metrics = Self.audioMetrics(for: snapshot.samples)
        let byteSize = (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return LiveAudioChunk(
            url: url,
            duration: snapshot.duration,
            sampleCount: snapshot.samples.count,
            peakAmplitude: metrics.peak,
            rmsAmplitude: metrics.rms,
            byteSize: byteSize
        )
    }

    func diagnostics() -> LiveAudioCaptureDiagnostics {
        let bufferDiagnostics = ringBuffer.diagnostics()
        stateLock.lock()
        let diagnostics = LiveAudioCaptureDiagnostics(
            isCapturing: isCapturing,
            receivedAudioBuffers: receivedAudioBuffers,
            appendedAudioBuffers: appendedAudioBuffers,
            droppedAudioBuffers: droppedAudioBuffers,
            bufferedSamples: bufferDiagnostics.samples,
            bufferedDuration: bufferDiagnostics.duration,
            sampleRate: bufferDiagnostics.sampleRate,
            lastAudioAt: lastAudioAt,
            lastDropReason: lastDropReason
        )
        stateLock.unlock()
        return diagnostics
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, capturing else {
            return
        }
        append(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error?) {
        if capturing {
            setCapturing(false)
        }
        let message = error?.localizedDescription ?? "unknown ScreenCaptureKit stream error"
        NSLog("AnyBrief live transcript system audio stream stopped: \(message)")
    }

    private var capturing: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isCapturing
    }

    private func setCapturing(_ value: Bool) {
        stateLock.lock()
        isCapturing = value
        stateLock.unlock()
    }

    private func append(_ sampleBuffer: CMSampleBuffer) {
        recordReceivedAudioBuffer()

        guard let formatDescription = sampleBuffer.formatDescription,
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else {
            recordDrop("missing audio format description")
            return
        }

        var asbd = asbdPointer.pointee
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd),
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: sourceFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              ) else {
            recordDrop("unsupported audio format")
            return
        }

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard frameCount > 0,
              let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: frameCount
              ) else {
            recordDrop("empty or unsupported audio frame buffer")
            return
        }
        sourceBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            recordDrop("CMSampleBufferCopyPCMDataIntoAudioBufferList failed: \(status)")
            return
        }
        guard let monoBuffer = convertToMonoFloat(sourceBuffer, outputFormat: monoFormat) else {
            recordDrop("audio converter returned no mono buffer")
            return
        }
        guard let samples = Self.floatSamples(from: monoBuffer), !samples.isEmpty else {
            recordDrop("mono buffer had no float samples")
            return
        }

        ringBuffer.append(samples: samples, sampleRate: monoFormat.sampleRate)
        recordAppendedAudioBuffer()
    }

    private func convertToMonoFloat(
        _ sourceBuffer: AVAudioPCMBuffer,
        outputFormat: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        if sourceBuffer.format == outputFormat {
            return sourceBuffer
        }

        if converter == nil ||
            converterInputFormat != sourceBuffer.format ||
            converterOutputFormat != outputFormat {
            converter = AVAudioConverter(from: sourceBuffer.format, to: outputFormat)
            converterInputFormat = sourceBuffer.format
            converterOutputFormat = outputFormat
        }

        guard let converter,
              let destinationBuffer = AVAudioPCMBuffer(
                  pcmFormat: outputFormat,
                  frameCapacity: sourceBuffer.frameLength
              ) else {
            return nil
        }

        var conversionError: NSError?
        var didProvideInput = false
        converter.convert(to: destinationBuffer, error: &conversionError) { _, outputStatus in
            if didProvideInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outputStatus.pointee = .haveData
            return sourceBuffer
        }

        guard conversionError == nil, destinationBuffer.frameLength > 0 else {
            return nil
        }
        return destinationBuffer
    }

    private static func floatSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let data = buffer.floatChannelData?.pointee else {
            return nil
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else {
            return []
        }

        return Array(UnsafeBufferPointer(start: data, count: frameCount))
    }

    private static func audioMetrics(for samples: [Float]) -> (peak: Float, rms: Float) {
        guard !samples.isEmpty else {
            return (0, 0)
        }

        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let absolute = abs(sample)
            peak = max(peak, absolute)
            sumSquares += Double(sample * sample)
        }
        return (peak, Float(sqrt(sumSquares / Double(samples.count))))
    }

    private static func write(
        samples: [Float],
        sampleRate: Double,
        targetSampleRate: Double,
        to url: URL
    ) throws {
        guard let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ),
        let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        ),
        let sourceData = sourceBuffer.floatChannelData?.pointee else {
            throw LiveTranscriptError.audioChunkWriteFailed
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            if let baseAddress = source.baseAddress {
                sourceData.update(from: baseAddress, count: samples.count)
            }
        }

        guard let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ),
        let converter = AVAudioConverter(from: sourceFormat, to: processingFormat) else {
            throw LiveTranscriptError.audioChunkWriteFailed
        }

        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetSampleRate / sampleRate)
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: processingFormat,
            frameCapacity: max(1, outputFrameCapacity)
        ) else {
            throw LiveTranscriptError.audioChunkWriteFailed
        }

        var conversionError: NSError?
        var didProvideInput = false
        converter.convert(to: outputBuffer, error: &conversionError) { _, outputStatus in
            if didProvideInput {
                outputStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outputStatus.pointee = .haveData
            return sourceBuffer
        }
        if conversionError != nil || outputBuffer.frameLength == 0 {
            throw LiveTranscriptError.audioChunkWriteFailed
        }

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: outputBuffer)
    }

    private func resetCounters() {
        stateLock.lock()
        receivedAudioBuffers = 0
        appendedAudioBuffers = 0
        droppedAudioBuffers = 0
        lastAudioAt = nil
        lastDropReason = nil
        stateLock.unlock()
    }

    private func recordReceivedAudioBuffer() {
        stateLock.lock()
        receivedAudioBuffers += 1
        lastAudioAt = Date()
        stateLock.unlock()
    }

    private func recordAppendedAudioBuffer() {
        stateLock.lock()
        appendedAudioBuffers += 1
        stateLock.unlock()
    }

    private func recordDrop(_ reason: String) {
        stateLock.lock()
        droppedAudioBuffers += 1
        lastDropReason = reason
        stateLock.unlock()
    }
}

private final class LiveAudioRingBuffer {
    private let lock = NSLock()
    private let maxDuration: TimeInterval
    private var sampleRate: Double?
    private var samples: [Float] = []

    init(maxDuration: TimeInterval) {
        self.maxDuration = maxDuration
    }

    func append(samples newSamples: [Float], sampleRate newSampleRate: Double) {
        lock.lock()
        defer { lock.unlock() }

        guard newSampleRate > 0 else {
            return
        }

        if sampleRate != newSampleRate {
            sampleRate = newSampleRate
            samples.removeAll(keepingCapacity: true)
        }

        samples.append(contentsOf: newSamples)
        let maxSamples = max(1, Int(maxDuration * newSampleRate))
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    func snapshot(duration: TimeInterval) -> LiveAudioSampleSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let sampleRate, sampleRate > 0, !samples.isEmpty else {
            return nil
        }

        let requestedSamples = max(1, Int(duration * sampleRate))
        let suffix = samples.suffix(requestedSamples)
        return LiveAudioSampleSnapshot(
            sampleRate: sampleRate,
            samples: Array(suffix),
            duration: Double(suffix.count) / sampleRate
        )
    }

    func reset() {
        lock.lock()
        samples.removeAll(keepingCapacity: true)
        sampleRate = nil
        lock.unlock()
    }

    func diagnostics() -> (sampleRate: Double?, samples: Int, duration: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }

        let duration = sampleRate.map { Double(samples.count) / $0 } ?? 0
        return (sampleRate, samples.count, duration)
    }
}

private struct LiveAudioSampleSnapshot {
    let sampleRate: Double
    let samples: [Float]
    let duration: TimeInterval
}
