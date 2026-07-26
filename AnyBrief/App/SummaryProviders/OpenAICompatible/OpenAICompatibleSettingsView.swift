
import SwiftUI

struct OpenAICompatibleSettingsView: View {
    @Binding var configuration: SummaryProviderConfiguration
    let apiKey: Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "API URL"),
                    help: String(localized: "Chat completions endpoint for an OpenAI-compatible provider, usually ending in /v1/chat/completions."),
                    fillWidth: true
                ) {
                    TextField(
                        "https://summary.example/v1/chat/completions",
                        text: SummaryProviderSettingsControls.optionalStringBinding($configuration.openAIAPIURL)
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Model"),
                    help: String(localized: "Provider model identifier used for summaries. Use the exact name expected by your API provider.")
                ) {
                    TextField(
                        "openai/gpt-4o",
                        text: SummaryProviderSettingsControls.optionalStringBinding($configuration.openAIModel)
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                }
            }
            SummaryProviderSettingsControls.labeledField(
                String(localized: "API Key"),
                help: String(localized: "Secret token sent to the provider. It is stored through the app secret store and is not exported in plain settings."),
                fillWidth: true
            ) {
                SecureField("sk-...", text: apiKey)
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }
}
