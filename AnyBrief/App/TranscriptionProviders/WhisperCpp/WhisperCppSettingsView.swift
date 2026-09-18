import SwiftUI

struct WhisperCppSettingsView: View {
    @Binding var config: WhisperCppConfig
    let diarizationEnabled: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkspaceFormField(title: String(localized: "Whisper model")) {
                Picker("", selection: $config.model) {
                    ForEach(WhisperCppModelService.models) { model in Text(model.displayName).tag(model.id) }
                    if !WhisperCppModelService.models.contains(where: { $0.id == config.model }) { Text(config.model).tag(config.model) }
                }.labelsHidden().pickerStyle(.menu)
            }
            WorkspaceFormField(title: String(localized: "Language")) {
                Picker("", selection: $config.language) {
                    ForEach(WhisperCppModelService.supportedLanguageCodes, id: \.self) { code in
                        Text(code == "auto" ? String(localized: "Auto-detect") : Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                    if !WhisperCppModelService.supportedLanguageCodes.contains(config.language) { Text(config.language).tag(config.language) }
                }.labelsHidden().pickerStyle(.menu)
            }
            Toggle(String(localized: "Use Metal acceleration"), isOn: $config.useGPU)
            TranscriptionSettingsFields(vocabulary: $config.customVocabulary, speakersMode: $config.speakersMode,
                speakersCount: $config.speakersCount, threshold: $config.threshold, diarizationEnabled: diarizationEnabled)
        }
    }
}
