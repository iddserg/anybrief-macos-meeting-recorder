
import SwiftUI

final class AudioLevelStore: ObservableObject {
    @Published private(set) var levels = AudioLevelSnapshot()

    func update(_ snapshot: AudioLevelSnapshot) {
        let normalized = Self.normalized(snapshot)
        guard Self.shouldPublish(normalized, replacing: levels) else {
            return
        }
        levels = normalized
    }

    func reset() {
        levels = AudioLevelSnapshot()
    }

    private static func normalized(_ snapshot: AudioLevelSnapshot) -> AudioLevelSnapshot {
        AudioLevelSnapshot(
            system: quantizedLevel(snapshot.system),
            microphone: quantizedLevel(snapshot.microphone),
            systemSource: snapshot.systemSource,
            microphoneSource: snapshot.microphoneSource,
            microphoneEchoCancellation: snapshot.microphoneEchoCancellation
        )
    }

    private static func quantizedLevel(_ value: Double) -> Double {
        let clamped = min(1, max(0, value))
        return (clamped * 20).rounded() / 20
    }

    private static func shouldPublish(_ newValue: AudioLevelSnapshot, replacing oldValue: AudioLevelSnapshot) -> Bool {
        newValue.system != oldValue.system
            || newValue.microphone != oldValue.microphone
            || newValue.systemSource != oldValue.systemSource
            || newValue.microphoneSource != oldValue.microphoneSource
            || newValue.microphoneEchoCancellation != oldValue.microphoneEchoCancellation
    }
}
