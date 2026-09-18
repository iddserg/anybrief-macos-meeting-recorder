import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import Foundation
import ScreenCaptureKit

final class EmbeddedAudioRecorder: AudioRecording {
    // A non-nil tap format attempts to reconfigure the input node. During an
    // audio-device transition outputFormat(forBus:) can briefly describe the
    // device that just disappeared, and AVFAudio terminates the process with an
    // Objective-C exception when that format no longer matches the hardware.
    // Let AVAudioEngine negotiate the live input format instead; enqueueWrite
    // already converts each captured buffer to the recording file's format.
    static var hardwareNegotiatedMicrophoneTapFormat: AVAudioFormat? { nil }

    private let microphoneRecorder: EmbeddedMicrophoneRecorder
    private let systemRecorder: EmbeddedSystemAudioRecorder
    private let captureTimeline: AudioCaptureTimeline
    private let audioDeviceRouteMonitor = AudioDeviceRouteMonitor()

    init(
        micURL: URL,
        systemURL: URL,
        microphoneVoiceProcessingEnabled: Bool = true,
        microphoneDeviceUID: String? = nil,
        systemAudioApplicationBundleIdentifier: String? = nil
    ) {
        let captureTimeline = AudioCaptureTimeline()
        self.captureTimeline = captureTimeline
        microphoneRecorder = EmbeddedMicrophoneRecorder(
            outputURL: micURL,
            voiceProcessingEnabled: microphoneVoiceProcessingEnabled,
            preferredDeviceUID: microphoneDeviceUID,
            captureTimeline: captureTimeline
        )
        systemRecorder = EmbeddedSystemAudioRecorder(
            outputURL: systemURL,
            captureTimeline: captureTimeline,
            applicationBundleIdentifier: systemAudioApplicationBundleIdentifier
        )
    }

    static func prewarmSystemAudioCapture() async throws {
        try await EmbeddedSystemAudioRecorder.prewarmDisplay()
    }

    func start() async throws {
        guard await Self.microphoneAccessGranted() else {
            throw EmbeddedRecorderError.microphoneAccessDenied
        }

        try await AudioFormatChangeRetry.run {
            captureTimeline.reset()
            try await startCapture()
        }
    }

    private func startCapture() async throws {
        do {
            try await systemRecorder.start()
            try microphoneRecorder.start()
        } catch {
            try? await systemRecorder.stop()
            microphoneRecorder.stop()
            throw error
        }
    }

    static func isAudioFormatNotSupported(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.code == Int(kAudioUnitErr_FormatNotSupported) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error {
            return isAudioFormatNotSupported(underlying)
        }
        return false
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

    func setMicrophoneDeviceUID(_ uid: String?) async throws {
        try await microphoneRecorder.setPreferredDeviceUID(uid)
    }

    func setSystemAudioApplicationBundleIdentifier(_ bundleIdentifier: String?) async throws {
        try await systemRecorder.setApplicationBundleIdentifier(bundleIdentifier)
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

    func setAudioDeviceRouteChangeHandler(_ handler: (@Sendable () -> Void)?) {
        audioDeviceRouteMonitor.setHandler(handler)
    }

    func setSystemAudioSourceEventHandler(_ handler: (@Sendable (SystemAudioSourceEvent) -> Void)?) {
        systemRecorder.setSourceEventHandler(handler)
    }

    func padMicrophoneSilence(toDuration duration: TimeInterval) throws {
        try microphoneRecorder.padSilence(
            toDuration: min(duration, captureTimeline.elapsedTime)
        )
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
            systemSource: "\(systemRecorder.sourceDescription) via \(systemOutput)",
            systemApplicationName: systemRecorder.selectedApplicationName,
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

private final class AudioDeviceRouteMonitor: @unchecked Sendable {
    private let callbackQueue = DispatchQueue(label: "pro.anybrief.audio-device-route")
    private let stateLock = NSLock()
    private var handler: (@Sendable () -> Void)?
    private var inputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var outputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private lazy var listenerBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.notifyHandler()
    }

    init() {
        let audioSystem = AudioObjectID(kAudioObjectSystemObject)
        let inputStatus = AudioObjectAddPropertyListenerBlock(
            audioSystem,
            &inputAddress,
            callbackQueue,
            listenerBlock
        )
        let outputStatus = AudioObjectAddPropertyListenerBlock(
            audioSystem,
            &outputAddress,
            callbackQueue,
            listenerBlock
        )
        if inputStatus != noErr || outputStatus != noErr {
            NSLog(
                "AnyBrief: unable to observe default audio device changes (input=%d, output=%d)",
                inputStatus,
                outputStatus
            )
        }
    }

    deinit {
        let audioSystem = AudioObjectID(kAudioObjectSystemObject)
        AudioObjectRemovePropertyListenerBlock(
            audioSystem,
            &inputAddress,
            callbackQueue,
            listenerBlock
        )
        AudioObjectRemovePropertyListenerBlock(
            audioSystem,
            &outputAddress,
            callbackQueue,
            listenerBlock
        )
    }

    func setHandler(_ handler: (@Sendable () -> Void)?) {
        stateLock.lock()
        self.handler = handler
        stateLock.unlock()
    }

    private func notifyHandler() {
        stateLock.lock()
        let handler = handler
        stateLock.unlock()
        handler?()
    }
}

private final class EmbeddedMicrophoneRecorder {
    private let outputURL: URL
    private var voiceProcessingEnabled: Bool
    private var preferredDeviceUID: String?
    private let captureTimeline: AudioCaptureTimeline
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

    init(
        outputURL: URL,
        voiceProcessingEnabled: Bool,
        preferredDeviceUID: String?,
        captureTimeline: AudioCaptureTimeline
    ) {
        self.outputURL = outputURL
        self.voiceProcessingEnabled = voiceProcessingEnabled
        self.preferredDeviceUID = Self.normalizedDeviceUID(preferredDeviceUID)
        self.captureTimeline = captureTimeline
    }

    func start() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        try configureInputNode(inputNode)
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
            try startEngine(engine, inputNodeAlreadyConfigured: true)
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

    func setPreferredDeviceUID(_ uid: String?) async throws {
        let normalizedUID = Self.normalizedDeviceUID(uid)
        let (previousUID, shouldRestart) = replacePreferredDeviceUID(with: normalizedUID)

        if shouldRestart {
            do {
                try await AudioFormatChangeRetry.run {
                    try self.restartCapture()
                }
            } catch {
                restorePreferredDeviceUID(previousUID)
                try? await AudioFormatChangeRetry.run {
                    try self.restartCapture()
                }
                throw error
            }
        }
    }

    private func replacePreferredDeviceUID(with uid: String?) -> (previousUID: String?, shouldRestart: Bool) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let previousUID = preferredDeviceUID
        preferredDeviceUID = uid
        let previousDeviceID = Self.captureDeviceID(for: previousUID)
        let nextDeviceID = Self.captureDeviceID(for: uid)
        return (previousUID, previousDeviceID != nextDeviceID && _isRecording)
    }

    private func restorePreferredDeviceUID(_ uid: String?) {
        stateLock.lock()
        preferredDeviceUID = uid
        stateLock.unlock()
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

    private func enqueueWrite(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        let paused = isPaused
        updateLevel(paused ? 0 : Self.rmsLevel(buffer))
        guard isRecording,
              let bufferCopy = Self.copy(buffer, silence: paused) else {
            return
        }
        let bufferDuration = Double(buffer.frameLength) / buffer.format.sampleRate
        let timelineStart = captureTimeline.relativeStartTime(
            hostTime: time.isHostTimeValid ? time.hostTime : nil,
            bufferDuration: bufferDuration
        )

        writeQueue.async { [weak self] in
            guard let self, self.isRecording, let audioFile = self.audioFile else { return }
            do {
                let writableBuffer = try self.buffer(bufferCopy, convertedTo: audioFile.processingFormat)
                try self.padSilenceIfNeeded(
                    before: timelineStart,
                    in: audioFile
                )
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

    private func startEngine(_ engine: AVAudioEngine, inputNodeAlreadyConfigured: Bool = false) throws {
        let inputNode = engine.inputNode
        if !inputNodeAlreadyConfigured {
            try configureInputNode(inputNode)
        }
        inputNode.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: EmbeddedAudioRecorder.hardwareNegotiatedMicrophoneTapFormat
        ) { [weak self] buffer, time in
            self?.enqueueWrite(buffer, at: time)
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

    /// Selecting Bluetooth input can change its sample rate and channel layout.
    /// Apply the device before asking AVAudioEngine for the format so the file
    /// and tap never retain the previous device's now-invalid format.
    private func configureInputNode(_ inputNode: AVAudioInputNode) throws {
        setEchoCancellationStatus(Self.configureVoiceProcessing(on: inputNode, enabled: voiceProcessingEnabled))
        try applyPreferredDevice(to: inputNode)
    }

    private func applyPreferredDevice(to inputNode: AVAudioInputNode) throws {
        stateLock.lock()
        let preferredUID = self.preferredDeviceUID
        stateLock.unlock()
        guard let preferredUID,
              let deviceID = MicrophoneDeviceCatalog.deviceID(forUID: preferredUID) else {
            return
        }
        // AVAudioEngine already follows the default input. Reassigning that same
        // Bluetooth device through the Audio Unit can force a second profile
        // transition and temporarily invalidate the format reported by the node.
        guard deviceID != MicrophoneDeviceCatalog.defaultInputDeviceID() else {
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

    private static func captureDeviceID(for preferredUID: String?) -> AudioDeviceID? {
        if let preferredUID,
           let preferredDeviceID = MicrophoneDeviceCatalog.deviceID(forUID: preferredUID) {
            return preferredDeviceID
        }
        return MicrophoneDeviceCatalog.defaultInputDeviceID()
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

    private func padSilenceIfNeeded(before timelineStart: TimeInterval, in file: AVAudioFile) throws {
        let frames = AudioTimelineAlignment.silenceFrames(
            before: timelineStart,
            sampleRate: file.processingFormat.sampleRate,
            framesWritten: framesWritten
        )
        try writeSilence(frames: frames, to: file)
    }

    private func writeSilence(frames: Int64, to file: AVAudioFile) throws {
        var remainingFrames = frames
        let maxChunkFrames = max(1, Int64(file.processingFormat.sampleRate))
        while remainingFrames > 0 {
            let chunkFrames = min(remainingFrames, maxChunkFrames)
            guard let buffer = Self.silentBuffer(
                format: file.processingFormat,
                frameCount: AVAudioFrameCount(chunkFrames)
            ) else {
                throw EmbeddedRecorderError.microphoneSilencePaddingFailed
            }
            try file.write(from: buffer)
            addFramesWritten(Int64(buffer.frameLength))
            remainingFrames -= Int64(buffer.frameLength)
        }
    }
}

enum AudioFormatChangeRetry {
    static let defaultDelays: [Duration] = [
        .milliseconds(350),
        .milliseconds(600),
        .milliseconds(900),
        .milliseconds(1_200),
        .milliseconds(1_600),
    ]

    static func run(
        delays: [Duration] = defaultDelays,
        sleeper: (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        operation: () async throws -> Void
    ) async throws {
        var retryIndex = 0
        while true {
            do {
                try await operation()
                return
            } catch {
                guard EmbeddedAudioRecorder.isAudioFormatNotSupported(error),
                      retryIndex < delays.count else {
                    throw error
                }
                let delay = delays[retryIndex]
                retryIndex += 1
                NSLog(
                    "AnyBrief microphone format changed; retrying capture after %.2f seconds (%d/%d).",
                    delay.timeInterval,
                    retryIndex,
                    delays.count
                )
                try await sleeper(delay)
            }
        }
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

private actor SystemAudioFilterUpdateGate {
    func perform<T>(_ operation: () async throws -> T) async rethrows -> T {
        try await operation()
    }
}

private final class EmbeddedSystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    private static let displayCache = SystemAudioDisplayCache()

    private let outputURL: URL
    private let captureTimeline: AudioCaptureTimeline
    private let stateLock = NSLock()
    private let filterUpdateGate = SystemAudioFilterUpdateGate()
    private var stream: SCStream?
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let writeQueue = DispatchQueue(label: "pro.anybrief.system-audio-write")
    private var _isRecording = false
    private var _level: Double = 0
    private var _levelUpdatedAt = Date.distantPast
    private var _framesWritten: Int64 = 0
    private var applicationBundleIdentifier: String?
    private var selectedApplicationProcessIdentifiers: Set<pid_t> = []
    private var _sourceDescription = "macOS system audio"
    private var streamStoppedUnexpectedly = false
    private var unexpectedStopHandler: (@Sendable (String) -> Void)?
    private var sourceEventHandler: (@Sendable (SystemAudioSourceEvent) -> Void)?
    private var applicationProcessMonitorTask: Task<Void, Never>?

    init(
        outputURL: URL,
        captureTimeline: AudioCaptureTimeline,
        applicationBundleIdentifier: String? = nil
    ) {
        self.outputURL = outputURL
        self.captureTimeline = captureTimeline
        let normalizedBundleIdentifier = applicationBundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.applicationBundleIdentifier = normalizedBundleIdentifier?.isEmpty == false
            ? normalizedBundleIdentifier
            : nil
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
        startApplicationProcessMonitor()
    }

    private func startCapture(on display: SCDisplay, resetFrames: Bool) async throws {
        let selection = try await contentFilter(
            on: display,
            applicationBundleIdentifier: selectedApplicationBundleIdentifier,
            allowUnavailableApplication: true
        )
        let filter = selection.filter
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
        self.stream = stream
        setApplicationSelection(
            bundleIdentifier: selectedApplicationBundleIdentifier,
            processIdentifiers: selection.processIdentifiers,
            sourceDescription: selection.sourceDescription
        )
        setRecording(true)
        if resetFrames {
            setFramesWritten(0)
        }
        setStreamStoppedUnexpectedly(false)
        do {
            try await stream.startCapture()
        } catch {
            setRecording(false)
            if self.stream === stream {
                self.stream = nil
            }
            throw error
        }
    }

    func restartCapture() async throws {
        try await filterUpdateGate.perform {
            guard self.isRecording else {
                throw EmbeddedRecorderError.systemAudioRestartUnsupported
            }

            let previousStream = self.stream
            self.stream = nil
            if let previousStream {
                try? await previousStream.stopCapture()
            }

            self.writeQueue.sync {
                self.converter = nil
                self.converterInputFormat = nil
            }

            let display = try await Self.displayCache.refreshedDisplay()
            do {
                try await self.startCapture(on: display, resetFrames: false)
            } catch {
                Self.displayCache.invalidate()
                try await self.startCapture(
                    on: try await Self.displayCache.refreshedDisplay(),
                    resetFrames: false
                )
            }
        }
    }

    func setApplicationBundleIdentifier(_ bundleIdentifier: String?) async throws {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedBundleIdentifier = trimmed?.isEmpty == false ? trimmed : nil
        try await filterUpdateGate.perform {
            guard normalizedBundleIdentifier != self.selectedApplicationBundleIdentifier else {
                return
            }

            let display = try await Self.displayCache.display()
            let selection = try await self.contentFilter(
                on: display,
                applicationBundleIdentifier: normalizedBundleIdentifier
            )
            if let stream = self.stream {
                try await stream.updateContentFilter(selection.filter)
            }
            self.setApplicationSelection(
                bundleIdentifier: normalizedBundleIdentifier,
                processIdentifiers: selection.processIdentifiers,
                sourceDescription: selection.sourceDescription
            )
        }
    }

    func stop() async throws {
        applicationProcessMonitorTask?.cancel()
        applicationProcessMonitorTask = nil
        try await filterUpdateGate.perform {
            self.setRecording(false)
            do {
                try await self.stream?.stopCapture()
            } catch {
                if self.didStreamStopUnexpectedly {
                    self.cleanup()
                    throw RecorderAlreadyStoppedError(message: error.localizedDescription)
                }
                throw error
            }
            self.cleanup()
        }
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

    var sourceDescription: String {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _sourceDescription
    }

    var selectedApplicationName: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return applicationBundleIdentifier == nil ? nil : _sourceDescription
    }

    private var selectedApplicationBundleIdentifier: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return applicationBundleIdentifier
    }

    private var selectedProcessIdentifiers: Set<pid_t> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedApplicationProcessIdentifiers
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
        _levelUpdatedAt = Date()
        stateLock.unlock()
    }

    private func setFramesWritten(_ value: Int64) {
        stateLock.lock()
        _framesWritten = value
        stateLock.unlock()
    }

    private func setApplicationSelection(
        bundleIdentifier: String?,
        processIdentifiers: Set<pid_t>,
        sourceDescription: String
    ) {
        stateLock.lock()
        applicationBundleIdentifier = bundleIdentifier
        selectedApplicationProcessIdentifiers = processIdentifiers
        _sourceDescription = sourceDescription
        _level = 0
        _levelUpdatedAt = Date()
        stateLock.unlock()
    }

    private func markSelectedApplicationUnavailable(
        _ bundleIdentifier: String
    ) -> (applicationName: String, processIdentifiers: [pid_t])? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if applicationBundleIdentifier == bundleIdentifier {
            guard !selectedApplicationProcessIdentifiers.isEmpty else {
                return nil
            }
            let previousProcessIdentifiers = selectedApplicationProcessIdentifiers.sorted()
            let applicationName = _sourceDescription
            selectedApplicationProcessIdentifiers = []
            _level = 0
            _levelUpdatedAt = Date()
            return (applicationName, previousProcessIdentifiers)
        }
        return nil
    }

    private func contentFilter(
        on display: SCDisplay,
        applicationBundleIdentifier: String?,
        allowUnavailableApplication: Bool = false
    ) async throws -> (
        filter: SCContentFilter,
        processIdentifiers: Set<pid_t>,
        sourceDescription: String
    ) {
        guard let applicationBundleIdentifier else {
            return (
                SCContentFilter(display: display, excludingWindows: []),
                [],
                "macOS system audio"
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: false
        )
        let applications = content.applications.filter {
            $0.bundleIdentifier == applicationBundleIdentifier
        }
        guard let application = applications.first else {
            if allowUnavailableApplication {
                return (
                    SCContentFilter(
                        display: display,
                        including: [],
                        exceptingWindows: []
                    ),
                    [],
                    applicationBundleIdentifier
                )
            }
            throw EmbeddedRecorderError.systemAudioApplicationUnavailable(applicationBundleIdentifier)
        }
        let currentDisplay = content.displays.first(where: { $0.displayID == display.displayID })
            ?? content.displays.first
            ?? display
        return (
            SCContentFilter(
                display: currentDisplay,
                including: applications,
                exceptingWindows: []
            ),
            Set(applications.map(\.processID)),
            application.applicationName
        )
    }

    private func startApplicationProcessMonitor() {
        applicationProcessMonitorTask?.cancel()
        applicationProcessMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                await self.refreshSelectedApplicationProcessesIfNeeded()
            }
        }
    }

    private func refreshSelectedApplicationProcessesIfNeeded() async {
        do {
            try await filterUpdateGate.perform {
                guard self.isRecording,
                      let bundleIdentifier = self.selectedApplicationBundleIdentifier,
                      let stream = self.stream else {
                    return
                }

                let display = try await Self.displayCache.display()
                let selection: (
                    filter: SCContentFilter,
                    processIdentifiers: Set<pid_t>,
                    sourceDescription: String
                )
                do {
                    selection = try await self.contentFilter(
                        on: display,
                        applicationBundleIdentifier: bundleIdentifier
                    )
                } catch EmbeddedRecorderError.systemAudioApplicationUnavailable {
                    if let unavailable = self.markSelectedApplicationUnavailable(bundleIdentifier) {
                        self.emitSourceEvent(.applicationUnavailable(
                            bundleIdentifier: bundleIdentifier,
                            applicationName: unavailable.applicationName,
                            previousProcessIdentifiers: unavailable.processIdentifiers
                        ))
                    }
                    return
                }

                let previousProcessIdentifiers = self.selectedProcessIdentifiers
                guard SystemAudioProcessTracking.shouldRebind(
                    previousProcessIdentifiers: previousProcessIdentifiers,
                    currentProcessIdentifiers: selection.processIdentifiers
                ) else {
                    return
                }
                try await stream.updateContentFilter(selection.filter)
                self.setApplicationSelection(
                    bundleIdentifier: bundleIdentifier,
                    processIdentifiers: selection.processIdentifiers,
                    sourceDescription: selection.sourceDescription
                )
                self.emitSourceEvent(.processesRebound(
                    bundleIdentifier: bundleIdentifier,
                    applicationName: selection.sourceDescription,
                    previousProcessIdentifiers: previousProcessIdentifiers.sorted(),
                    currentProcessIdentifiers: selection.processIdentifiers.sorted()
                ))
            }
        } catch {
            NSLog("AnyBrief failed to refresh selected application audio processes: \(error.localizedDescription)")
        }
    }

    func setSourceEventHandler(_ handler: (@Sendable (SystemAudioSourceEvent) -> Void)?) {
        stateLock.lock()
        sourceEventHandler = handler
        stateLock.unlock()
    }

    private func emitSourceEvent(_ event: SystemAudioSourceEvent) {
        stateLock.lock()
        let handler = sourceEventHandler
        stateLock.unlock()
        handler?(event)
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
        guard outputType == .audio, isRecording, isCurrentStream(stream) else { return }
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
        let bufferDuration = Double(sampleBuffer.numSamples) / sourceFormat.sampleRate
        let timelineStart = captureTimeline.relativeStartTime(
            presentationTime: sampleBuffer.presentationTimeStamp,
            bufferDuration: bufferDuration
        )

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

        do {
            try padSilenceIfNeeded(before: timelineStart, in: file)
        } catch {
            NSLog("AnyBrief failed to align system audio timeline: \(error.localizedDescription)")
            return
        }

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

    private func padSilenceIfNeeded(before timelineStart: TimeInterval, in file: AVAudioFile) throws {
        var remainingFrames = AudioTimelineAlignment.silenceFrames(
            before: timelineStart,
            sampleRate: file.processingFormat.sampleRate,
            framesWritten: framesWritten
        )
        let maxChunkFrames = max(1, Int64(file.processingFormat.sampleRate))
        while remainingFrames > 0 {
            let chunkFrames = min(remainingFrames, maxChunkFrames)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(chunkFrames)
            ) else {
                throw EmbeddedRecorderError.systemAudioTimelineAlignmentFailed
            }
            buffer.frameLength = AVAudioFrameCount(chunkFrames)
            for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                if let data = audioBuffer.mData {
                    memset(data, 0, Int(audioBuffer.mDataByteSize))
                }
            }
            try file.write(from: buffer)
            addFramesWritten(Int64(buffer.frameLength))
            remainingFrames -= Int64(buffer.frameLength)
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

/// Shared monotonic clock for independently captured microphone and system-audio streams.
/// ScreenCaptureKit presentation times and AVAudioTime host times both use the host clock.
final class AudioCaptureTimeline {
    private let lock = NSLock()
    private var originSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())

    func reset() {
        lock.lock()
        originSeconds = AVAudioTime.seconds(forHostTime: mach_absolute_time())
        lock.unlock()
    }

    var elapsedTime: TimeInterval {
        lock.lock()
        let origin = originSeconds
        lock.unlock()
        return max(0, AVAudioTime.seconds(forHostTime: mach_absolute_time()) - origin)
    }

    func relativeStartTime(hostTime: UInt64?, bufferDuration: TimeInterval) -> TimeInterval {
        let candidate = hostTime.map { AVAudioTime.seconds(forHostTime: $0) - originSnapshot }
        return validated(candidate, bufferDuration: bufferDuration)
    }

    func relativeStartTime(presentationTime: CMTime, bufferDuration: TimeInterval) -> TimeInterval {
        let seconds = CMTimeGetSeconds(presentationTime)
        let candidate = seconds.isFinite ? seconds - originSnapshot : nil
        return validated(candidate, bufferDuration: bufferDuration)
    }

    private var originSnapshot: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return originSeconds
    }

    private func validated(_ candidate: TimeInterval?, bufferDuration: TimeInterval) -> TimeInterval {
        let fallback = max(0, elapsedTime - max(0, bufferDuration))
        guard let candidate,
              candidate.isFinite,
              candidate >= -0.25,
              abs(candidate - fallback) <= 5 else {
            return fallback
        }
        return max(0, candidate)
    }
}

enum AudioTimelineAlignment {
    static func silenceFrames(
        before timelineStart: TimeInterval,
        sampleRate: Double,
        framesWritten: Int64
    ) -> Int64 {
        guard timelineStart.isFinite, timelineStart > 0, sampleRate > 0 else {
            return 0
        }
        let targetFrame = Int64((timelineStart * sampleRate).rounded())
        return max(0, targetFrame - framesWritten)
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
