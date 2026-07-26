
import SwiftUI

@MainActor
final class OllamaSettingsViewModel: ObservableObject {
    @Published var models: [OllamaModel] = []
    @Published var isLoadingModels = false
    @Published var statusMessage: String?
    @Published var contextMessage: String?
    @Published var isLoadingContext = false

    private let modelDiscoveryService: OllamaModelDiscoveryService

    init(modelDiscoveryService: OllamaModelDiscoveryService = OllamaModelDiscoveryService()) {
        self.modelDiscoveryService = modelDiscoveryService
    }

    func refreshModels(selectedModel: String, applyFallbackModel: @escaping (String) -> Void) {
        statusMessage = nil
        isLoadingModels = true

        Task {
            do {
                let names = try await modelDiscoveryService.fetchModels()
                models = names.map { OllamaModel(id: $0, name: $0) }
                let trimmedSelectedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmedSelectedModel.isEmpty || !names.contains(trimmedSelectedModel) {
                    applyFallbackModel(names.first ?? "")
                }
                isLoadingModels = false
                statusMessage = names.isEmpty ? String(localized: "No local Ollama models found.") : nil
            } catch {
                models = []
                isLoadingModels = false
                statusMessage = error.localizedDescription
                contextMessage = nil
            }
        }
    }

    func refreshContextInfo(for configuration: SummaryProviderConfiguration) {
        let model = configuration.ollamaEffectiveModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else {
            contextMessage = nil
            return
        }
        let requestedContextLength = configuration.ollamaContextLength ?? OllamaDefaults.contextLength

        isLoadingContext = true
        contextMessage = String(localized: "Detecting Ollama context...")

        Task {
            do {
                let info = try await modelDiscoveryService.fetchContextInfo(for: model)
                isLoadingContext = false
                contextMessage = Self.contextSummary(for: info, requestedContextLength: requestedContextLength)
            } catch {
                isLoadingContext = false
                contextMessage = String(format: String(localized: "Could not detect Ollama context: %@"), error.localizedDescription)
            }
        }
    }

    static func contextSummary(
        for info: OllamaModelDiscoveryService.ContextInfo,
        requestedContextLength: Int
    ) -> String {
        let requested = formatContextLength(requestedContextLength)
        let running = info.runningContextLength.map(formatContextLength) ?? String(localized: "not loaded")
        let maximum = info.modelMaxContextLength.map(formatContextLength) ?? String(localized: "unknown")
        let modelfile = info.modelfileContextLength.map(formatContextLength) ?? String(localized: "not set")
        return String(
            format: String(localized: "Requested: %@. Current Ollama: %@. Model max: %@. Modelfile num_ctx: %@."),
            requested,
            running,
            maximum,
            modelfile
        )
    }

    static func formatContextLength(_ value: Int) -> String {
        if value % 1_024 == 0 {
            return "\(value / 1_024)k"
        }
        return "\(value)"
    }
}

struct OllamaSettingsView: View {
    @Binding var configuration: SummaryProviderConfiguration
    @StateObject private var viewModel: OllamaSettingsViewModel

    init(
        configuration: Binding<SummaryProviderConfiguration>,
        modelDiscoveryService: OllamaModelDiscoveryService = OllamaModelDiscoveryService()
    ) {
        _configuration = configuration
        _viewModel = StateObject(wrappedValue: OllamaSettingsViewModel(modelDiscoveryService: modelDiscoveryService))
    }

    var body: some View {
        let contextLength = SummaryProviderSettingsControls.optionalIntBinding(
            $configuration.ollamaContextLength,
            default: OllamaDefaults.contextLength
        )
        let chunkThreshold = SummaryProviderSettingsControls.optionalIntBinding(
            $configuration.ollamaChunkThreshold,
            default: OllamaDefaults.chunkThreshold
        )
        let chunkSize = SummaryProviderSettingsControls.optionalIntBinding(
            $configuration.ollamaChunkSize,
            default: OllamaDefaults.chunkSize
        )

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Local Endpoint"),
                    help: String(localized: "Fixed Ollama chat endpoint on this Mac. Start Ollama before checking or generating summaries."),
                    fillWidth: true
                ) {
                    TextField("", text: .constant(OllamaDefaults.chatURLString))
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                        .disabled(true)
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Model"),
                    help: String(localized: "Ollama model used for summaries. Click Refresh after pulling a new model.")
                ) {
                    HStack(spacing: 8) {
                        Picker("", selection: SummaryProviderSettingsControls.optionalStringBinding($configuration.ollamaModel)) {
                            if (configuration.ollamaModel ?? "").isEmpty {
                                Text(String(localized: "Choose a model")).tag("")
                            }
                            ForEach(viewModel.models) { model in
                                Text(model.name).tag(model.name)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 220)
                        .onChange(of: configuration.ollamaModel) { _ in
                            viewModel.refreshContextInfo(for: configuration)
                        }

                        Button(viewModel.isLoadingModels ? String(localized: "Refreshing…") : String(localized: "Refresh")) {
                            refreshModels()
                        }
                        .disabled(viewModel.isLoadingModels)
                    }
                }
            }
            SummaryProviderSettingsControls.wrappingFieldRow {
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Context"),
                    help: String(localized: "Recommended: 32k context, split after 16k, chunk 12k. Increase only if the model and memory allow it.")
                ) {
                    Picker("", selection: contextLength) {
                        Text("16k").tag(16_384)
                        Text("32k").tag(32_768)
                        Text("64k").tag(65_536)
                        Text("128k").tag(131_072)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                    .onChange(of: configuration.ollamaContextLength) { _ in
                        viewModel.refreshContextInfo(for: configuration)
                    }
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Split after"),
                    help: String(localized: "Split long transcripts before sending them to the model.")
                ) {
                    Picker("", selection: chunkThreshold) {
                        Text("12k").tag(12_000)
                        Text("16k").tag(16_000)
                        Text("24k").tag(24_000)
                        Text("32k").tag(32_000)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Chunk"),
                    help: String(localized: "Chunk size used when summarizing long transcripts.")
                ) {
                    Picker("", selection: chunkSize) {
                        Text("8k").tag(8_000)
                        Text("12k").tag(12_000)
                        Text("16k").tag(16_000)
                        Text("24k").tag(24_000)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 90)
                }
            }
            if let statusMessage = viewModel.statusMessage {
                SummaryProviderSettingsControls.compactHelpText(statusMessage)
            } else if let contextMessage = viewModel.contextMessage {
                SummaryProviderSettingsControls.compactHelpText(contextMessage)
            }
        }
        .onAppear {
            if viewModel.models.isEmpty && !viewModel.isLoadingModels {
                refreshModels()
            }
        }
    }

    private func refreshModels() {
        viewModel.refreshModels(selectedModel: configuration.ollamaEffectiveModel) { model in
            configuration.ollamaModel = model
            viewModel.refreshContextInfo(for: configuration)
        }
    }
}
