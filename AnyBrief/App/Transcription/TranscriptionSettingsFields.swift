import SwiftUI

struct TranscriptionSettingsFields: View {
    @Binding var vocabulary: String
    @Binding var speakersMode: String
    @Binding var speakersCount: Int
    @Binding var threshold: Double
    let diarizationEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            WorkspaceFormField(title: String(localized: "Recognition dictionary")) {
                TextEditor(text: $vocabulary).font(ABTypography.field)
                    .scrollContentBackground(.hidden).padding(10).frame(height: 120)
                    .background(WorkspaceDesign.secondarySurface)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(ABDesign.hairline))
            }
            Text(String(localized: "Add one preferred word or phrase per line. To correct known variants, use “Preferred term: variant 1, variant 2”. The dictionary is passed to the selected STT engine."))
                .font(ABTypography.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                WorkspaceFormField(title: String(localized: "Speakers")) {
                    Picker("", selection: $speakersMode) {
                        Text(String(localized: "Auto-detect")).tag("auto")
                        Text(String(localized: "From calendar (maximum)")).tag("calendar")
                        Text(String(localized: "Exact count")).tag("fixed")
                        Text(String(localized: "Maximum count")).tag("max")
                    }.labelsHidden().pickerStyle(.menu).frame(maxWidth: 340, alignment: .leading)
                }
                if ["fixed", "max"].contains(speakersMode) {
                    WorkspaceIntegerStepper(title: String(localized: "Speakers"), valueText: "\(speakersCount)",
                                            value: $speakersCount, range: 1...10)
                }
                Text(String(localized: "Speaker Sensitivity") + " · " + String(format: "%.2f", threshold))
                Slider(value: $threshold, in: 0.1...1, step: 0.05)
                Text(String(localized: "Lower values split speech into more speakers. Higher values merge similar voices and produce fewer speakers."))
                    .font(ABTypography.caption).foregroundStyle(.secondary)
            }.disabled(!diarizationEnabled)
        }
    }
}
