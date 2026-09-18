import SwiftUI

struct FluidAudioSTTSettingsView: View {
    @Binding var config: FluidAudioSTTConfig
    let diarizationEnabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            TranscriptionSettingsFields(vocabulary: $config.customVocabulary, speakersMode: $config.speakersMode,
                speakersCount: $config.speakersCount, threshold: $config.threshold, diarizationEnabled: diarizationEnabled)
        }
    }
}
