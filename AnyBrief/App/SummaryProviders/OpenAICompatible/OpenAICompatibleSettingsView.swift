
import SwiftUI

struct OpenAICompatibleSettingsView: View {
    @Binding var configuration: SummaryProviderConfiguration
    let apiKey: Binding<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            apiURLField
            modelField
            apiKeyField
        }
    }

    // Keep each bound native field in its own view subtree when an editor is replaced.
    private var apiURLField: some View {
        WorkspaceFormField(title: String(localized: "API URL"),
            help: String(localized: "Chat completions endpoint for an OpenAI-compatible provider, usually ending in /v1/chat/completions.")) {
            TextField("https://summary.example/v1/chat/completions",
                text: SummaryProviderSettingsControls.optionalStringBinding($configuration.openAIAPIURL))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var modelField: some View {
        WorkspaceFormField(title: String(localized: "Model"),
            help: String(localized: "Provider model identifier used for summaries. Use the exact name expected by your API provider.")) {
            TextField("openai/gpt-4o",
                text: SummaryProviderSettingsControls.optionalStringBinding($configuration.openAIModel))
                .textFieldStyle(.roundedBorder)
        }
    }

    private var apiKeyField: some View {
        WorkspaceFormField(title: String(localized: "API Key"),
            help: String(localized: "Secret token sent to the provider. It is stored through the app secret store and is not exported in plain settings.")) {
            SecureField("sk-...", text: apiKey).textFieldStyle(.roundedBorder)
        }
    }
}
