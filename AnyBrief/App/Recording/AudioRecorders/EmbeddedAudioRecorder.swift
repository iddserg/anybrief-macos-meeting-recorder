import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

final class EmbeddedAudioRecorder: AudioRecording {
    private let microphoneRecorder: EmbeddedMicrophoneRecorder
    private let systemRecorder: EmbeddedSystemAudioRecorder

    init(
        micURL: URL,
        systemURL: URL,
        microphoneVoiceProcessingEnabled: Bool = true,
        microphoneDeviceUID: String? = nil
    ) {
        microphoneRecorder = EmbeddedMicrophoneRecorder(
            outputURL: micURL,
            voiceProcessingEnabled: microphoneVoiceProcessingEnabled,
            preferredDeviceUID: microphoneDeviceUID
        )
        systemRecorder = EmbeddedSystemAudioRecorder(outputURL: systemURL)
    }

    static func prewarmSystemAudioCapture() async throws {
        try await EmbeddedSystemAudioRecorder.prewarmDisplay()
    }

    func start() async throws {
        guard await Self.microphoneAccessGranted() else {
            throw EmbeddedRecorderError.microphoneAccessDenied
        }

        do {
            try await systemRecorder.start()
            try microphoneRecorder.start()
        } catch {
            try? await systemRecorder.stop()
            microphoneRecorder.stop()
            throw error
        }
    }

    func stop() async throws {
        microphoneRecorder.stop()
        try await systemRecorder.stop()
    }

    func setMicrophonePaused(_ paused: Bool) throws {
        microphoneRecorder.setPaused(paused)
    }

    func setMicrophoneVoiceProcessingEnabled(_ enabled: Bool) throws {
        try microphoneRecorder.setVoiceProcessingEnabled(enabled)
    }

    func setMicrophoneDeviceUID(_ uid: String?) throws {
        try microphoneRecorder.setPreferredDeviceUID(uid)
    }

    func restartMicrophoneCapture() throws {
        try microphoneRecorder.restartCapture()
    }

    func restartSystemAudioCapture() async throws {
        try await systemRecorder.restartCapture()
    }

    func setSystemAudioInterruptionHandler(_ handler: (@Sendable (String) -> Void)?) {
        systemRecorder.setUnexpectedStopHandler(handler)
    }

    func padMicrophoneSilence(toDuration duration: TimeInterval) throws {
        try microphoneRecorder.padSilence(toDuration: duration)
    }

    func microphoneDiagnosticDescription() -> String {
        EmbeddedMicrophoneRecorder.currentInputDeviceDescription(
            preferredUID: microphoneRecorder.preferredDeviceUIDSnapshot
        )
    }

    func systemOutputDiagnosticDescription() -> String {
        EmbeddedSystemAudioRecorder.currentDefaultOutputDeviceDescription()
    }

    func audioLevels() -> AudioLevelSnapshot {
        let systemOutput = systemOutputDiagnosticDescription()
        return AudioLevelSnapshot(
            system: systemRecorder.level,
            microphone: microphoneRecorder.level,
            systemSource: "macOS system audio via \(systemOutput)",
            microphoneSource: microphoneDiagnosticDescription(),
            microphoneEchoCancellation: microphoneRecorder.echoCancellationStatus
        )
    }

    func outputActivity() -> AudioOutputActivity? {
        AudioOutputActivity(
            systemFramesWritten: systemRecorder.framesWritten,
            microphoneFramesWritten: microphoneRecorder.framesWritten
        )
    }

    private static func microphoneAccessGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

private final class EmbeddedMicrophoneRecorder {
    private let outputURL: URL
    private var voiceProcessingEnabled: Bool
    private var preferredDeviceUID: String?
    private let writeQueue = DispatchQueue(label: "pro.anybrief.microphone-audio-write")
    private let stateLock = NSLock()
    private var engine: AVAudioEngine?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private var converterOutputFormat: AVAudioFormat?
    private var _isRecording = false
    private var _isPaused = false
    private var _level: Double = 0
    private var _levelUpdatedAt = Date.distantPast
    private var _framesWritten: Int64 = 0
    private var _echoCancellationStatus: EchoCancellationStatus = .unknown

    init(outputURL: URL, voiceProcessingEnabled: Bool, preferredDeviceUID: String?) {
        self.outputURL = outputURL
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.preferredDeviceUID = Self.normalizedDeviceUID(preferredDeviceUID)
    }

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        setEchoCancellationStatus(Self.configureVoiceProcessing(on: inputNode, enabled: voiceProcessingEnabled))
        let format = inputNode.outputFormat(forBus: 0)
        let recordingFormat = Self.recordingFormat(for: format)

        let file = try AVAudioFile(forWriting: outputURL, settings: recordingFormat.settings)
        writeQueue.sync {
            audioFile = file
            resetConversionState()
        }
        setFramesWritten(0)
        setRecording(true)
        setPaused(false)

        do {
            try startEngine(engine)
        } catch {
            setRecording(false)
            setEchoCancellationStatus(.unknown)
            writeQueue.sync {
                self.audioFile = nil
                resetConversionState()
            }
            throw error
        }
    }

    func stop() {
        setRecording(false)
        setPaused(false)
        setEchoCancellationStatus(.unknown)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        writeQueue.sync {
            self.audioFile = nil
            resetConversionState()
        }
    }

    func restartCapture() throws {
        guard isRecording else {
            throw EmbeddedRecorderError.microphoneRestartUnsupported
        }

        resetLevel()
        setEchoCancellationStatus(.unknown)
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil

        let hasAudioFile = writeQueue.sync { audioFile != nil }
        guard hasAudioFile else {
            throw EmbeddedRecorderError.microphoneRestartUnsupported
        }

        writeQueue.sync {
            resetConversionState()
        }
        try startEngine(AVAudioEngine())
        resetLevel()
    }

    func setVoiceProcessingEnabled(_ enabled: Bool) throws {
        stateLock.lock()
        let wasEnabled = voiceProcessingEnabled
        let shouldRestart = wasEnabled != enabled && _isRecording
        voiceProcessingEnabled = enabled
        stateLock.unlock()

        guard wasEnabled != enabled else {
            return
        }

        if shouldRestart {
            try restartCapture()
        } else if let inputNode = engine?.inputNode {
            setEchoCancellationStatus(Self.configureVoiceProcessing(on: inputNode, enabled: enabled))
        } else {
            setEchoCancellationStatus(.unknown)
        }
    }

    func setPreferredDeviceUID(_ uid: String?) throws {
        let normalizedUID = Self.normalizedDeviceUID(uid)
        stateLock.lock()
        let previousUID = preferredDeviceUID
        let changed = previousUID != normalizedUID
        preferredDeviceUID = normalizedUID
        let shouldRestart = changed && _isRecording
        stateLock.unlock()

        if shouldRestart {
            do {
                try restartCapture()
            } catch {
                stateLock.lock()
                preferredDeviceUID = previousUID
                stateLock.unlock()
                try? restartCapture()
                throw error
            }
        }
    }

    func padSilence(toDuration duration: TimeInterval) throws {
        guard duration.isFinite, duration > 0 else {
            return
        }

        var paddingError: Error?
        writeQueue.sync {
            guard self.isRecording,
                  let file = self.audioFile else {
                return
            }

            let sampleRate = file.processingFormat.sampleRate
            guard sampleRate > 0 else {
                paddingError = EmbeddedRecorderError.microphoneSilencePaddingFailed
                return
            }

            let targetFrames = Int64((duration * sampleRate).rounded(.down))
            var remainingFrames = targetFrames - self.framesWritten
            guard remainingFrames > 0 else {
                return
            }

            let maxChunkFrames = max(1, Int64(sampleRate))
            while remainingFrames > 0 {
                let chunkFrames = min(remainingFrames, maxChunkFrames)
                guard let buffer = Self.silentBuffer(
                    format: file.processingFormat,
                    frameCount: AVAudioFrameCount(chunkFrames)
                ) else {
                    paddingError = EmbeddedRecorderError.microphoneSilencePaddingFailed
                    return
                }

                do {
                    try file.write(from: buffer)
                    self.addFramesWritten(Int64(buffer.frameLength))
                    remainingFrames -= Int64(buffer.frameLength)
                } catch {
                    paddingError = error
                    return
                }
            }
        }

        if let paddingError {
            throw paddingError
        }
    }

    static func currentInputDeviceDescription(preferredUID: String? = nil) -> String {
        if let preferredUID = normalizedDeviceUID(preferredUID),
           let deviceID = MicrophoneDeviceCatalog.deviceID(forUID: preferredUID),
           let description = MicrophoneDeviceCatalog.description(for: deviceID) {
            return description
        }
        if let deviceID = MicrophoneDeviceCatalog.defaultInputDeviceID(),
           let description = MicrophoneDeviceCatalog.description(for: deviceID) {
            return description
        }
        return "none"
    }

    func setPaused(_ paused: Bool) {
        stateLock.lock()
        _isPaused = paused
        if paused {
            _level = 0
            _levelUpdatedAt = Date()
        }
        stateLock.unlock()
    }

    var level: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !_isPaused else {
            return 0
        }
        let silenceAfter = 0.35
        let elapsed = Date().timeIntervalSince(_levelUpdatedAt)
        guard elapsed > silenceAfter else {
            return _level
        }
        let decayed = _level * exp(-(elapsed - silenceAfter) * 5)
        return decayed > 0.01 ? decayed : 0
    }

    var framesWritten: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _framesWritten
    }

    var echoCancellationStatus: EchoCancellationStatus {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _echoCancellationStatus
    }

    var preferredDeviceUIDSnapshot: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return preferredDeviceUID
    }

    private func enqueueWrite(_ buffer: AVAudioPCMBuffer) {
        let paused = isPaused
        updateLevel(paused ? 0 : Self.rmsLevel(buffer))
        guard isRecording,
              let bufferCopy = Self.copy(buffer, silence: paused) else {
            return
        }

        writeQueue.async { [weak self] in
            guard let self, self.isRecording, let audioFile = self.audioFile else { return }
            do {
                let writableBuffer = try self.buffer(bufferCopy, convertedTo: audioFile.processingFormat)
                try audioFile.write(from: writableBuffer)
                self.addFramesWritten(Int64(writableBuffer.frameLength))
            } catch {
                // The stop path validates the final files. Avoid throwing from
                // the realtime audio callback path.
            }
        }
    }

    private var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRecording
    }

    private var isPaused: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isPaused
    }

    private func setRecording(_ value: Bool) {
        stateLock.lock()
        _isRecording = value
        if !value {
            _level = 0
            _levelUpdatedAt = Date()
        }
        stateLock.unlock()
    }

    private func updateLevel(_ value: Double) {
        stateLock.lock()
        _level = value > _level ? value : (_level * 0.72 + value * 0.28)
        _levelUpdatedAt = Date()
        stateLock.unlock()
    }

    private func resetLevel() {
        stateLock.lock()
        _level = 0
        _levelUpdatedAt = Date()
        stateLock.unlock()
    }

    private func setFramesWritten(_ value: Int64) {
        stateLock.lock()
        _framesWritten = value
        stateLock.unlock()
    }

    private func addFramesWritten(_ value: Int64) {
        stateLock.lock()
        _framesWritten += value
        stateLock.unlock()
    }

    private func setEchoCancellationStatus(_ value: EchoCancellationStatus) {
        stateLock.lock()
        _echoCancellationStatus = value
        stateLock.unlock()
    }

    private func startEngine(_ engine: AVAudioEngine) throws {
        let inputNode = engine.inputNode
        setEchoCancellationStatus(Self.configureVoiceProcessing(on: inputNode, enabled: voiceProcessingEnabled))
        try applyPreferredDevice(to: inputNode)
        let tapFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: tapFormat) { [weak self] buffer, _ in
            self?.enqueueWrite(buffer)
        }

        do {
            try engine.start()
            self.engine = engine
            setEchoCancellationStatus(Self.echoCancellationStatus(for: inputNode))
        } catch {
            inputNode.removeTap(onBus: 0)
            setEchoCancellationStatus(.unknown)
            throw error
        }
    }

    private func applyPreferredDevice(to inputNode: AVAudioInputNode) throws {
        stateLock.lock()
        let preferredUID = self.preferredDeviceUID
        stateLock.unlock()
        guard let preferredUID,
              let deviceID = MicrophoneDeviceCatalog.deviceID(forUID: preferredUID) else {
            return
        }
        guard let audioUnit = inputNode.audioUnit else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(kAudio_ParamError),
                userInfo: [NSLocalizedDescriptionKey: "Unable to access the microphone audio unit."]
            )
        }

        var mutableDeviceID = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Unable to select microphone \(preferredUID)."]
            )
        }
    }

    private static func normalizedDeviceUID(_ uid: String?) -> String? {
        guard let value = uid?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func configureVoiceProcessing(on inputNode: AVAudioInputNode, enabled: Bool) -> EchoCancellationStatus {
        do {
            try inputNode.setVoiceProcessingEnabled(enabled)
            if enabled {
                inputNode.isVoiceProcessingBypassed = false
                inputNode.isVoiceProcessingAGCEnabled = true
            }
            return echoCancellationStatus(for: inputNode)
        } catch {
            NSLog("AnyBrief failed to \(enabled ? "enable" : "disable") microphone voice processing: \(error.localizedDescription)")
            return .unknown
        }
    }

    private static func echoCancellationStatus(for inputNode: AVAudioInputNode) -> EchoCancellationStatus {
        guard inputNode.isVoiceProcessingEnabled else {
            return .disabled
        }
        return inputNode.isVoiceProcessingBypassed ? .disabled : .enabled
    }

    private static func recordingFormat(for inputFormat: AVAudioFormat) -> AVAudioFormat {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) ?? inputFormat
    }

    private func buffer(_ buffer: AVAudioPCMBuffer, convertedTo outputFormat: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard buffer.format != outputFormat else {
            cacheConversionState(converter: nil, inputFormat: buffer.format, outputFormat: outputFormat)
            return buffer
        }
        if let monoBuffer = Self.monoBuffer(buffer, outputFormat: outputFormat) {
            cacheConversionState(converter: nil, inputFormat: buffer.format, outputFormat: outputFormat)
            return monoBuffer
        }
        let converter = try cachedConverter(from: buffer.format, to: outputFormat)

        let sampleRateRatio = outputFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(
            max(1, Int(ceil(Double(buffer.frameLength) * sampleRateRatio)) + 1024)
        )
        guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw EmbeddedRecorderError.microphoneFormatConversionFailed
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: convertedBuffer, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }

            didProvideInput = true
            outStatus.pointee = .haveData
            return buffer
        }

        if let conversionError {
            throw conversionError
        }
        guard status != .error, convertedBuffer.frameLength > 0 else {
            throw EmbeddedRecorderError.microphoneFormatConversionFailed
        }

        return convertedBuffer
    }

    private func cachedConverter(from inputFormat: AVAudioFormat, to outputFormat: AVAudioFormat) throws -> AVAudioConverter {
        if let converter,
           let converterInputFormat,
           let converterOutputFormat,
           converterInputFormat == inputFormat,
           converterOutputFormat == outputFormat {
            return converter
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw EmbeddedRecorderError.microphoneFormatConversionFailed
        }

        cacheConversionState(converter: converter, inputFormat: inputFormat, outputFormat: outputFormat)
        return converter
    }

    private func cacheConversionState(
        converter: AVAudioConverter?,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        self.converter = converter
        converterInputFormat = inputFormat
        converterOutputFormat = outputFormat
    }

    private func resetConversionState() {
        converter = nil
        converterInputFormat = nil
        converterOutputFormat = nil
    }

    private static func monoBuffer(_ buffer: AVAudioPCMBuffer, outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard outputFormat.channelCount == 1,
              buffer.format.channelCount > 1,
              buffer.format.sampleRate == outputFormat.sampleRate,
              buffer.format.commonFormat == .pcmFormatFloat32,
              outputFormat.commonFormat == .pcmFormatFloat32,
              let source = buffer.floatChannelData?.pointee,
              let mono = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData?.pointee else {
            return nil
        }

        mono.frameLength = buffer.frameLength
        memcpy(destination, source, Int(buffer.frameLength) * MemoryLayout<Float>.size)
        return mono
    }

    private static func copy(_ buffer: AVAudioPCMBuffer, silence: Bool) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameCapacity
        ) else { return nil }
        copy.frameLength = buffer.frameLength

        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationList = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<sourceList.count {
            let source = sourceList[index]
            let destination = destinationList[index]
            guard let sourceData = source.mData, let destinationData = destination.mData else {
                continue
            }
            if silence {
                memset(destinationData, 0, Int(source.mDataByteSize))
            } else {
                memcpy(destinationData, sourceData, Int(source.mDataByteSize))
            }
        }

        return copy
    }

    private static func silentBuffer(format: AVAudioFormat, frameCount: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount

        let buffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for audioBuffer in buffers {
            guard let data = audioBuffer.mData else {
                continue
            }
            memset(data, 0, Int(audioBuffer.mDataByteSize))
        }
        return buffer
    }
}

private final class EmbeddedSystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let displayCache = SystemAudioDisplayCache()

    private let outputURL: URL
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let writeQueue = DispatchQueue(label: "pro.anybrief.system-audio-write")
    private var _isRecording = false
    private var _level: Double = 0
    private var _framesWritten: Int64 = 0
    private var streamStoppedUnexpectedly = false
    private var unexpectedStopHandler: (@Sendable (String) -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    static func prewarmDisplay() async throws {
        _ = try await displayCache.display()
    }

    func start() async throws {
        let display = try await Self.displayCache.display()
        do {
            try await startCapture(on: display, resetFrames: true)
        } catch {
            Self.displayCache.invalidate()
            try await startCapture(on: try await Self.displayCache.refreshedDisplay(), resetFrames: true)
        }
    }

    private func startCapture(on display: SCDisplay, resetFrames: Bool) async throws {
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 10, timescale: 1)
        config.queueDepth = 8

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: writeQueue)
        setRecording(true)
        if resetFrames {
            setFramesWritten(0)
        }
        setStreamStoppedUnexpectedly(false)
        do {
            try await stream.startCapture()
        } catch {
            setRecording(false)
            throw error
        }

        self.stream = stream
    }

    func restartCapture() async throws {
        guard isRecording else {
            throw EmbeddedRecorderError.systemAudioRestartUnsupported
        }

        let previousStream = stream
        stream = nil
        if let previousStream {
            try? await previousStream.stopCapture()
        }

        writeQueue.sync {
            self.converter = nil
            self.converterInputFormat = nil
        }

        let display = try await Self.displayCache.refreshedDisplay()
        do {
            try await startCapture(on: display, resetFrames: false)
        } catch {
            Self.displayCache.invalidate()
            try await startCapture(on: try await Self.displayCache.refreshedDisplay(), resetFrames: false)
        }
    }

    func stop() async throws {
        setRecording(false)
        do {
            try await stream?.stopCapture()
        } catch {
            if didStreamStopUnexpectedly {
                cleanup()
                throw RecorderAlreadyStoppedError(message: error.localizedDescription)
            }
            throw error
        }
        cleanup()
    }

    private var isRecording: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isRecording
    }

    private var didStreamStopUnexpectedly: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return streamStoppedUnexpectedly
    }

    var level: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _level
    }

    var framesWritten: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _framesWritten
    }

    private func setRecording(_ value: Bool) {
        stateLock.lock()
        _isRecording = value
        if !value {
            _level = 0
        }
        stateLock.unlock()
    }

    private func updateLevel(_ value: Double) {
        stateLock.lock()
        _level = value > _level ? value : (_level * 0.72 + value * 0.28)
        stateLock.unlock()
    }

    private func setFramesWritten(_ value: Int64) {
        stateLock.lock()
        _framesWritten = value
        stateLock.unlock()
    }

    private func addFramesWritten(_ value: Int64) {
        stateLock.lock()
        _framesWritten += value
        stateLock.unlock()
    }

    private func setStreamStoppedUnexpectedly(_ value: Bool) {
        stateLock.lock()
        streamStoppedUnexpectedly = value
        stateLock.unlock()
    }

    func setUnexpectedStopHandler(_ handler: (@Sendable (String) -> Void)?) {
        stateLock.lock()
        unexpectedStopHandler = handler
        stateLock.unlock()
    }

    private func unexpectedStopHandlerSnapshot() -> (@Sendable (String) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return unexpectedStopHandler
    }

    private func isCurrentStream(_ candidate: SCStream) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stream === candidate
    }

    private func cleanup() {
        writeQueue.sync {
            self.audioFile = nil
            self.converter = nil
            self.converterInputFormat = nil
        }
        stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .audio, isRecording else { return }
        write(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error?) {
        guard isCurrentStream(stream) else {
            NSLog("AnyBrief ignored stale system audio stream stop callback.")
            return
        }

        let wasRecording = isRecording
        if wasRecording {
            setStreamStoppedUnexpectedly(true)
        }
        let message = error?.localizedDescription ?? "unknown ScreenCaptureKit stream error"
        NSLog("AnyBrief system audio stream stopped unexpectedly: \(message)")
        if wasRecording {
            unexpectedStopHandlerSnapshot()?(message)
        }
    }

    private func write(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = sampleBuffer.formatDescription,
              let asbdPointer = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        else { return }

        var asbd = asbdPointer.pointee
        guard let sourceFormat = AVAudioFormat(streamDescription: &asbd) else { return }

        if audioFile == nil {
            let interleavedSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: asbd.mSampleRate,
                AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let file: AVAudioFile
            do {
                file = try AVAudioFile(forWriting: outputURL, settings: interleavedSettings)
            } catch {
                NSLog("AnyBrief failed to create system audio file at \(outputURL.path): \(error.localizedDescription)")
                return
            }
            audioFile = file
        }

        guard let file = audioFile else { return }
        prepareConverterIfNeeded(from: sourceFormat, to: file.processingFormat)

        let frameCount = AVAudioFrameCount(sampleBuffer.numSamples)
        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: frameCount
        ) else { return }
        sourceBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard status == noErr else { return }
        updateLevel(Self.rmsLevel(sourceBuffer))

        if let converter {
            guard let destinationBuffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: frameCount
            ) else { return }

            var conversionError: NSError?
            converter.convert(to: destinationBuffer, error: &conversionError) { _, outputStatus in
                outputStatus.pointee = .haveData
                return sourceBuffer
            }
            if conversionError == nil {
                do {
                    try file.write(from: destinationBuffer)
                    addFramesWritten(Int64(destinationBuffer.frameLength))
                } catch {
                    // The stop path validates the final files. Avoid throwing
                    // from ScreenCaptureKit's sample callback path.
                }
            }
        } else {
            do {
                try file.write(from: sourceBuffer)
                addFramesWritten(Int64(sourceBuffer.frameLength))
            } catch {
                // The stop path validates the final files. Avoid throwing from
                // ScreenCaptureKit's sample callback path.
            }
        }
    }

    private func prepareConverterIfNeeded(from sourceFormat: AVAudioFormat, to destinationFormat: AVAudioFormat) {
        guard sourceFormat != destinationFormat else {
            converter = nil
            converterInputFormat = nil
            return
        }

        if converter == nil || converterInputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: destinationFormat)
            converterInputFormat = sourceFormat
        }
    }

    static func currentDefaultOutputDeviceDescription() -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return "unknown"
        }

        let name = audioObjectStringProperty(kAudioObjectPropertyName, for: deviceID) ?? "unknown"
        let uid = audioObjectStringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) ?? "unknown"
        return "\(name) [\(uid)]"
    }

    private static func audioObjectStringProperty(_ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "" as CFString
        var dataSize = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )
        guard status == noErr else {
            return nil
        }
        return value as String
    }
}

private final class SystemAudioDisplayCache {
    private let lock = NSLock()
    private var cachedDisplay: SCDisplay?

    func display() async throws -> SCDisplay {
        if let display = currentDisplay {
            return display
        }

        return try await refreshedDisplay()
    }

    func refreshedDisplay() async throws -> SCDisplay {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )

        guard let display = content.displays.first else {
            throw EmbeddedRecorderError.noDisplayFound
        }

        cache(display)
        return display
    }

    func invalidate() {
        lock.lock()
        cachedDisplay = nil
        lock.unlock()
    }

    private func cache(_ display: SCDisplay) {
        lock.lock()
        cachedDisplay = display
        lock.unlock()
    }

    private var currentDisplay: SCDisplay? {
        lock.lock()
        defer { lock.unlock() }
        return cachedDisplay
    }
}

private extension AVAudioPCMBuffer {
    var normalizedRMSLevel: Double {
        let buffers = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        var sum: Double = 0
        var sampleCount = 0

        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            for index in 0..<count {
                let sample = Double(samples[index])
                sum += sample * sample
            }
            sampleCount += count
        }

        guard sampleCount > 0 else { return 0 }
        let rms = sqrt(sum / Double(sampleCount))
        let db = 20 * log10(max(rms, 0.000_001))
        return min(1, max(0, (db + 55) / 55))
    }
}

private extension EmbeddedMicrophoneRecorder {
    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        buffer.normalizedRMSLevel
    }
}

private extension EmbeddedSystemAudioRecorder {
    static func rmsLevel(_ buffer: AVAudioPCMBuffer) -> Double {
        buffer.normalizedRMSLevel
    }
}
