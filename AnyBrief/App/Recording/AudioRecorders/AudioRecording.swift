import CoreAudio
import Foundation

protocol AudioRecording: AnyObject {
    func start() async throws
    func stop() async throws
    func setMicrophonePaused(_ paused: Bool) throws
    func setMicrophoneVoiceProcessingEnabled(_ enabled: Bool) throws
    func setMicrophoneDeviceUID(_ uid: String?) throws
    func restartMicrophoneCapture() throws
    func restartSystemAudioCapture() async throws
    func setSystemAudioInterruptionHandler(_ handler: (@Sendable (String) -> Void)?)
    func padMicrophoneSilence(toDuration duration: TimeInterval) throws
    func microphoneDiagnosticDescription() -> String
    func systemOutputDiagnosticDescription() -> String
    func audioLevels() -> AudioLevelSnapshot
    func outputActivity() -> AudioOutputActivity?
}

struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    let uid: String
    let name: String
    let isSystemDefault: Bool

    var id: String { uid }
}

enum MicrophoneDeviceCatalog {
    static func availableDevices() -> [MicrophoneDevice] {
        let defaultDeviceID = defaultInputDeviceID()
        return inputDeviceIDs()
            .compactMap { deviceID -> MicrophoneDevice? in
                guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
                      let name = stringProperty(kAudioObjectPropertyName, for: deviceID) else {
                    return nil
                }
                return MicrophoneDevice(
                    uid: uid,
                    name: name,
                    isSystemDefault: deviceID == defaultDeviceID
                )
            }
            .sorted {
                if $0.isSystemDefault != $1.isSystemDefault {
                    return $0.isSystemDefault
                }
                return $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDeviceIDs().first { stringProperty(kAudioDevicePropertyDeviceUID, for: $0) == uid }
    }

    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            return nil
        }
        return deviceID
    }

    static func description(for deviceID: AudioDeviceID) -> String? {
        guard let name = stringProperty(kAudioObjectPropertyName, for: deviceID),
              let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) else {
            return nil
        }
        return "\(name) [\(uid)]"
    }

    private static func inputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size
        ) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &devices
        ) == noErr else {
            return []
        }
        return devices.filter(hasInputStreams)
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= UInt32(MemoryLayout<AudioStreamID>.size)
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, pointer)
        }
        return status == noErr ? value as String? : nil
    }
}

struct AudioLevelSnapshot: Sendable {
    var system: Double = 0
    var microphone: Double = 0
    var systemSource: String = "macOS system audio"
    var microphoneSource: String = "unavailable"
    var microphoneEchoCancellation: EchoCancellationStatus = .unknown
}

enum EchoCancellationStatus: String, Sendable {
    case enabled
    case disabled
    case unknown
}

struct AudioOutputActivity: Sendable {
    var systemFramesWritten: Int64 = 0
    var microphoneFramesWritten: Int64 = 0

    var framesWritten: Int64 {
        systemFramesWritten + microphoneFramesWritten
    }
}

extension AudioRecording {
    func restartMicrophoneCapture() throws {
        throw EmbeddedRecorderError.microphoneRestartUnsupported
    }

    func restartSystemAudioCapture() async throws {}

    func setSystemAudioInterruptionHandler(_ handler: (@Sendable (String) -> Void)?) {}

    func padMicrophoneSilence(toDuration duration: TimeInterval) throws {}

    func setMicrophoneVoiceProcessingEnabled(_ enabled: Bool) throws {}

    func setMicrophoneDeviceUID(_ uid: String?) throws {}

    func microphoneDiagnosticDescription() -> String {
        "unavailable"
    }

    func systemOutputDiagnosticDescription() -> String {
        "unavailable"
    }

    func outputActivity() -> AudioOutputActivity? {
        nil
    }
}

enum EmbeddedRecorderError: LocalizedError {
    case microphoneAccessDenied
    case microphoneFormatConversionFailed
    case microphoneRestartUnsupported
    case microphoneSilencePaddingFailed
    case noDisplayFound
    case systemAudioRestartUnsupported

    var errorDescription: String? {
        switch self {
        case .microphoneAccessDenied:
            return "Microphone access denied. Grant access in System Settings > Privacy & Security > Microphone."
        case .microphoneFormatConversionFailed:
            return "Unable to convert microphone audio to the recording format."
        case .microphoneRestartUnsupported:
            return "Microphone capture restart is not supported by this recorder."
        case .microphoneSilencePaddingFailed:
            return "Unable to pad microphone capture with silence."
        case .noDisplayFound:
            return "No display found for system audio capture."
        case .systemAudioRestartUnsupported:
            return "System audio capture restart is not supported by this recorder."
        }
    }
}
