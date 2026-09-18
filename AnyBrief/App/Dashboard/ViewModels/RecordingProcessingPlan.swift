import Foundation

/// Read-only preview using saved settings and the same selection rules as processing.
struct RecordingProcessingPlan: Equatable {
    let jobID: String
    let transcriptDetail: String
    let summaryDetail: String
    let exportDetail: String
    let summaryEnabled: Bool
    let exportEnabled: Bool

    init(jobID: String, settings: AppSettings, meetingTitle: String, exportTitle: String,
         transcriptionRegistry: TranscriptionProviderRegistry, summaryRegistry: SummaryProviderRegistry,
         fileManager: FileManager = .default) {
        self.jobID = jobID
        func field(_ label: String, _ value: String) -> String { "\(label): \(value)" }
        func promptName(_ prompt: PromptItem?) -> String {
            guard let prompt else { return String(localized: "Not configured") }
            return prompt.name.isEmpty ? String(localized: "Untitled prompt") : prompt.name
        }
        func connections(_ chain: [LLMConnectionConfiguration]) -> String {
            let names = chain.map { connection in
                if let name = connection.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return name }
                let title = (try? summaryRegistry.module(for: connection.provider).title) ?? connection.provider.rawValue
                return String(localized: String.LocalizationValue(title))
            }
            return names.isEmpty ? String(localized: "No enabled LLM connections") : names.joined(separator: " → ")
        }

        let configuration = settings.transcription.activeProviderConfiguration
        var transcriptLines: [String] = []
        if let module = try? transcriptionRegistry.module(for: configuration.provider) {
            let title = String(localized: String.LocalizationValue(module.title))
            if let metadata = try? module.metadata(configuration: configuration, diarizationEnabled: settings.transcription.diarizationEnabled) {
                transcriptLines.append("\(title) · \(metadata.model)")
                transcriptLines.append(field(String(localized: "Speaker separation"), metadata.diarizationEnabled ? String(localized: "Enabled") : String(localized: "Disabled")))
            } else { transcriptLines.append(title) }
        } else { transcriptLines.append(configuration.provider.rawValue) }
        if settings.prompts.transcriptCleanup.enabled {
            transcriptLines.append(field(String(localized: "Transcript cleanup prompt"), promptName(settings.prompts.transcriptCleanupPrompt)))
            transcriptLines.append(field("LLM", connections(settings.transcriptCleanupLLMChain)))
        }
        transcriptDetail = transcriptLines.joined(separator: "\n")

        summaryEnabled = settings.summary.enabled
        if summaryEnabled {
            let prompt = settings.prompts.summaryPrompt(forMeetingTitle: meetingTitle)
            var lines = [field(String(localized: "Prompt"), promptName(prompt)),
                         field("LLM", connections(settings.summaryLLMChain))]
            if let context = settings.prompts.prompt(withID: settings.prompts.summary.speakerContextPromptID),
               !context.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                lines.append(field(String(localized: "Speaker context"), promptName(context)))
            }
            summaryDetail = lines.joined(separator: "\n")
        } else { summaryDetail = String(localized: "Disabled") }

        if !settings.postProcessing.enabled {
            exportEnabled = false
            exportDetail = String(localized: "Disabled")
        } else if let rule = settings.postProcessing.rules.first(where: { $0.enabled && PostProcessingService.matches(title: exportTitle, rule: $0) }) {
            exportEnabled = true
            let content: String
            switch rule.exportContent {
            case .summary: content = String(localized: "Summary")
            case .transcript: content = String(localized: "Transcript")
            case .both: content = "\(String(localized: "Summary")) + \(String(localized: "Transcript"))"
            }
            var lines = [field(String(localized: "Rule"), rule.title.isEmpty ? String(localized: "Untitled rule") : rule.title),
                         field(String(localized: "Materials"), content),
                         field(String(localized: "Destination folder"), rule.destinationFolderPath.isEmpty ? String(localized: "Not configured") : rule.destinationFolderPath)]
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: rule.destinationFolderPath, isDirectory: &isDirectory) || !isDirectory.boolValue {
                lines.append(String(localized: "Choose an existing destination folder."))
            }
            if rule.exportContent == .both, !rule.filenameTemplate.contains("{type}") {
                lines.append(String(localized: "Include {type} to export both materials."))
            }
            if !settings.summary.enabled, rule.exportContent != .transcript {
                lines.append(String(localized: "Summary export is unavailable while automatic summary is disabled."))
            }
            exportDetail = lines.joined(separator: "\n")
        } else {
            exportEnabled = false
            exportDetail = String(localized: "No enabled export rule matches this meeting.")
        }
    }
}

extension DashboardViewModel {
    func loadRecordingProcessingPlan(activities: [CurrentActivity], meetings: [RecentMeeting]) async -> RecordingProcessingPlan? {
        guard let activity = activities.first(where: { $0.isRecording || $0.jobId != "runtime" }),
              let meeting = meetings.first(where: { $0.jobId == activity.jobId }) else { return nil }
        var settings = await appSettingsStore.load(using: loggingService)
        let metadata = MeetingMetadataStore.load(from: meeting.folderURL)
        if let count = metadata?.systemSpeakersOverride {
            let configuration = settings.transcription.activeProviderConfiguration
            if let module = try? transcriptionProviderRegistry.module(for: configuration.provider) {
                let overridden = module.applyingSpeakerLimit(count, to: configuration)
                if let index = settings.transcription.providers.firstIndex(where: { $0.id == configuration.id }) {
                    settings.transcription.providers[index] = overridden
                } else { settings.transcription.providers.append(overridden) }
            }
        }
        return RecordingProcessingPlan(
            jobID: activity.jobId, settings: settings,
            meetingTitle: MeetingMetadataStore.storedTitle(in: meeting.folderURL) ?? meeting.title,
            exportTitle: metadata?.calendarEvent?.title ?? MeetingMetadataStore.fallbackTitle(in: meeting.folderURL),
            transcriptionRegistry: transcriptionProviderRegistry, summaryRegistry: summaryProviderRegistry
        )
    }
}
