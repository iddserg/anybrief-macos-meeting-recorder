import SwiftUI

/// Describes saved configuration, not whether a remote LLM is currently reachable.
enum SummarySetupState: Equatable {
    case noConnection, disabled, missingPrompt, configured

    init(settings: AppSettings) {
        if settings.summaryLLMChain.isEmpty { self = .noConnection }
        else if !settings.summary.enabled { self = .disabled }
        else if settings.prompts.summaryPrompt(forMeetingTitle: nil)?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            self = .missingPrompt
        } else { self = .configured }
    }

    var detail: String {
        switch self {
        case .noConnection:
            return String(localized: "Connect an LLM to get meeting summaries and action items. Recording and speech recognition do not require an LLM.")
        case .disabled:
            return String(localized: "An LLM connection is enabled, but automatic summary is off. Enable it in Processing to create summaries after recording.")
        case .missingPrompt:
            return String(localized: "Choose a summary prompt in Processing so AnyBrief knows how to prepare your meeting notes.")
        case .configured:
            return String(localized: "Automatic summary is enabled. Check the LLM connection in settings to verify access; adding a connection alone does not confirm it works.")
        }
    }

    var opensProcessing: Bool { self == .disabled || self == .missingPrompt }
}

struct SetupReadinessSnapshot {
    let microphoneGranted: Bool
    let screenRecordingGranted: Bool
    let transcription: TranscriptionDiagnosticResult
    let summary: SummarySetupState

    var recordingPermissionsGranted: Bool { microphoneGranted && screenRecordingGranted }
}

extension DashboardViewModel {
    func loadSetupReadiness() async -> SetupReadinessSnapshot {
        let settings = await appSettingsStore.load(using: loggingService)
        let permissions = await loadPermissions()
        let configuration = settings.transcription.activeProviderConfiguration
        let transcription: TranscriptionDiagnosticResult
        do {
            let module = try transcriptionProviderRegistry.module(for: configuration.provider)
            transcription = await module.makeDiagnostics(context: TranscriptionDiagnosticsContext(fileManager: fileManager))
                .diagnose(configuration: configuration, settings: settings)
        } catch {
            transcription = TranscriptionDiagnosticResult(status: .failure, message: error.localizedDescription)
        }
        return SetupReadinessSnapshot(
            microphoneGranted: permissions.first { $0.id == "microphone" }?.rawStatus == .granted,
            screenRecordingGranted: permissions.first { $0.id == "screenRecording" }?.rawStatus == .granted,
            transcription: transcription,
            summary: SummarySetupState(settings: settings))
    }
}

struct SetupReadinessSectionView: View {
    enum Destination { case permissions, transcription, llm, processing }
    @ObservedObject var viewModel: DashboardViewModel
    var open: (Destination) -> Void
    @State private var snapshot: SetupReadinessSnapshot?
    @State private var refreshID = UUID()
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                Text("See what is ready and what needs setup. You can return here at any time from Diagnostics.")
                    .font(ABTypography.body).foregroundStyle(ABDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { refreshID = UUID() } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(checking)
                .accessibilityIdentifier("setup.recheck")
            }
            if viewModel.hasUnsavedSettings {
                Text("These checks use saved settings. Save your changes in Settings or Templates, then return here.")
                    .font(ABTypography.caption).foregroundStyle(ABDesign.accent)
            }
            if checking {
                ProgressView("Checking…").font(ABTypography.caption)
            } else if let snapshot {
                SetupReadinessCards(snapshot: snapshot, open: open)
            }
        }
        .padding(.horizontal, WorkspaceDesign.inset)
        .padding(.vertical, 16)
        .frame(maxWidth: 800, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspaceDesign.surface)
        .task(id: "\(refreshID)|\(viewModel.savedSettingsSignature ?? "")") {
            checking = true
            let result = await viewModel.loadSetupReadiness()
            guard !Task.isCancelled else { return }
            snapshot = result
            checking = false
        }
    }
}

struct SetupReadinessCards: View {
    let snapshot: SetupReadinessSnapshot
    let open: (SetupReadinessSectionView.Destination) -> Void

    var body: some View {
        VStack(spacing: 12) {
            card(title: "Audio recording", icon: "mic", status: snapshot.recordingPermissionsGranted ? "Permissions granted" : "Permission needed",
                 ready: snapshot.recordingPermissionsGranted) {
                Text("Allow microphone access to record your voice and screen recording access to capture meeting audio.")
                HStack(spacing: 14) {
                    permission("Microphone", granted: snapshot.microphoneGranted)
                    permission("System audio", granted: snapshot.screenRecordingGranted)
                }
                action("Open permissions", destination: .permissions)
            }

            HStack(alignment: .top, spacing: 12) {
                card(title: "Transcription", icon: "waveform", status: snapshot.transcription.status == .success ? "Ready" : "Setup needed",
                     ready: snapshot.transcription.status == .success) {
                    if snapshot.transcription.status == .success {
                        Text(snapshot.transcription.message)
                    } else {
                        Text("Install the selected speech model and required components to get a transcript. Existing recordings can be processed after setup.")
                    }
                    action("Set up transcription", destination: .transcription)
                }

                card(title: "Summary", icon: "text.alignleft", status: "Optional", ready: false) {
                    Text(snapshot.summary.detail)
                    action(snapshot.summary.opensProcessing ? "Set up automatic summary" : "Set up LLM",
                           destination: snapshot.summary.opensProcessing ? .processing : .llm)
                }
            }
        }
    }

    private func card<Content: View>(title: LocalizedStringKey, icon: String, status: LocalizedStringKey,
                                     ready: Bool, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20).foregroundStyle(ABDesign.accent)
                Text(title).font(ABTypography.itemTitle).foregroundStyle(ABDesign.primaryText)
                Spacer(minLength: 8)
                Text(status).font(ABTypography.captionMedium)
                    .foregroundStyle(ready ? ABDesign.green : ABDesign.secondaryText)
            }
            content().font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceDesign.secondarySurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func permission(_ title: LocalizedStringKey, granted: Bool) -> some View {
        Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(granted ? ABDesign.green : ABDesign.secondaryText)
            .accessibilityValue(granted ? Text("Granted") : Text("Missing"))
    }

    private func action(_ title: LocalizedStringKey, destination: SetupReadinessSectionView.Destination) -> some View {
        Button { open(destination) } label: { Label(title, systemImage: "arrow.right") }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("setup.open.\(destination)")
    }
}
