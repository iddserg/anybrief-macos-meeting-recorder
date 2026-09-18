import SwiftUI
import UniformTypeIdentifiers

struct MeetingImportSheet: View {
    @ObservedObject var viewModel: DashboardViewModel
    let completed: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var file: URL?
    @State private var title = ""
    @State private var date = Date()
    @State private var importTask: Task<Void, Never>?
    @State private var error: String?
    @State private var settings: AppSettings?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import a meeting").font(ABTypography.sectionTitle)
            Text("Choose a recording from a voice recorder or a video. AnyBrief will extract the audio and process it using your saved settings. The original file stays unchanged.")
                .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Image(systemName: "doc.badge.plus")
                Text(file?.lastPathComponent ?? String(localized: "No file selected"))
                    .lineLimit(1).truncationMode(.middle).help(file?.path ?? "")
                Spacer()
                Button("Choose file…", action: chooseFile).buttonStyle(WorkspaceButtonStyle())
            }
            .disabled(importTask != nil)
            VStack(alignment: .leading, spacing: 8) {
                Text("Meeting title").font(ABTypography.bodySemibold)
                TextField("Meeting title", text: $title).textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("import.title")
                DatePicker("Meeting date", selection: $date)
            }.disabled(importTask != nil)
            Text(summaryHint).font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error {
                Text(error).font(ABTypography.caption).foregroundStyle(ABDesign.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if importTask != nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Preparing audio…").font(ABTypography.caption)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") {
                    if let importTask { importTask.cancel() } else { dismiss() }
                }.buttonStyle(WorkspaceButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Import and process", action: startImport)
                    .buttonStyle(WorkspaceButtonStyle(prominent: true))
                    .disabled(file == nil || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importTask != nil)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("import.start")
            }
        }
        .padding(24).frame(width: 520)
        .interactiveDismissDisabled(importTask != nil)
        .task { settings = await viewModel.appSettingsStore.load(using: viewModel.loggingService) }
    }

    private var summaryHint: String {
        guard let settings else { return String(localized: "Loading processing settings…") }
        if settings.summary.enabled == false {
            return String(localized: "Automatic summary is off. Audio and transcript will be saved; you can create a summary later in the meeting menu.")
        }
        if ManualSummaryAvailability(settings: settings, meetingTitle: title) != .ready {
            return String(localized: "To create a summary, configure an LLM connection and a prompt. You can do this later; your audio will be saved.")
        }
        return String(localized: "Transcription, transcript cleanup, summary and export follow your saved settings.")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie, .audiovisualContent]
        panel.allowsOtherFileTypes = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "Choose file…")
        guard let window = NSApp.keyWindow else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            file = url
            title = url.deletingPathExtension().lastPathComponent
            error = nil
        }
    }

    private func startImport() {
        guard let file, importTask == nil else { return }
        error = nil
        let meetingTitle = title
        let meetingDate = date
        importTask = Task { @MainActor in
            do {
                let jobID = try await viewModel.importMeetingAction(file, meetingTitle, meetingDate)
                await viewModel.refresh()
                importTask = nil
                completed(jobID)
                dismiss()
            } catch is CancellationError {
                importTask = nil
                dismiss()
            } catch {
                self.error = error.localizedDescription
                importTask = nil
            }
        }
    }
}
