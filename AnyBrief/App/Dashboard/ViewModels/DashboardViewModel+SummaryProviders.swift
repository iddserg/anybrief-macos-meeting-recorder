
import Foundation

extension DashboardViewModel {
    func addSummaryProviderConfiguration(_ provider: SummaryProvider) {
        let allowsMultipleConfigurations = (try? summaryProviderRegistry.module(for: provider).allowsMultipleConfigurations)
            ?? true
        if !allowsMultipleConfigurations,
           let existing = summaryProviderEntries.first(where: { $0.provider == provider }) {
            selectSummaryProviderConfiguration(existing)
            return
        }
        let configuration = (try? summaryProviderRegistry.defaultConfiguration(for: provider))
            ?? SummaryProviderConfiguration(provider: provider)
        summaryProviderEntries.append(configuration)
        selectSummaryProviderConfiguration(configuration)
    }

    func canAddSummaryProviderConfiguration(_ provider: SummaryProvider) -> Bool {
        let allowsMultipleConfigurations = (try? summaryProviderRegistry.module(for: provider).allowsMultipleConfigurations)
            ?? true
        return allowsMultipleConfigurations || !summaryProviderEntries.contains { $0.provider == provider }
    }

    func removeSummaryProviderConfiguration(_ configuration: SummaryProviderConfiguration) {
        guard summaryProviderEntries.count > 1 else {
            return
        }
        summaryProviderEntries.removeAll { $0.id == configuration.id }
        summaryProviderAPIKeys[configuration.id] = nil
        if selectedSummaryProviderConfigurationID == configuration.id {
            selectedSummaryProviderConfigurationID = summaryProviderEntries.first?.id
        }
        // Drop the removed connection from task assignments so their pickers
        // fall back to Auto instead of keeping a dangling selection.
        summaryConnectionIDs.removeAll { $0 == configuration.id }
        transcriptCleanupConnectionIDs.removeAll { $0 == configuration.id }
        if liveConnectionID == configuration.id {
            liveConnectionID = nil
        }
    }

    func moveSummaryProviderConfiguration(_ configuration: SummaryProviderConfiguration, direction: Int) {
        guard let index = summaryProviderEntries.firstIndex(where: { $0.id == configuration.id }) else {
            return
        }
        let newIndex = index + direction
        guard summaryProviderEntries.indices.contains(newIndex) else {
            return
        }
        summaryProviderEntries.swapAt(index, newIndex)
    }

    func selectSummaryProviderConfiguration(_ configuration: SummaryProviderConfiguration) {
        selectedSummaryProviderConfigurationID = configuration.id
    }

    func isCheckingSummaryProvider(_ configuration: SummaryProviderConfiguration) -> Bool {
        checkingSummaryProviderIDs.contains(configuration.id)
    }

    func summaryProviderDiagnosticResult(for configuration: SummaryProviderConfiguration) -> SummaryProviderDiagnosticResult? {
        summaryProviderDiagnosticResults[configuration.id]
    }

    func checkSummaryProviderConfiguration(_ configuration: SummaryProviderConfiguration) {
        guard !checkingSummaryProviderIDs.contains(configuration.id) else {
            return
        }
        checkingSummaryProviderIDs.insert(configuration.id)
        summaryProviderDiagnosticResults[configuration.id] = SummaryProviderDiagnosticResult(
            status: .warning,
            message: String(localized: "Checking provider…")
        )

        Task {
            let settings = await currentSummarySettings(for: configuration)
            let result = await summaryProviderDiagnosticsService.diagnose(
                configuration: configuration,
                settings: settings,
                openAIAPIKey: summaryProviderAPIKeys[configuration.id] ?? ""
            )
            await loggingService.log(
                "Connection check for \(configuration.id): \(result.message)",
                level: result.status == .failure ? .error : .info,
                component: "Diagnostics"
            )
            await MainActor.run {
                checkingSummaryProviderIDs.remove(configuration.id)
                summaryProviderDiagnosticResults[configuration.id] = result
            }
        }
    }

    var selectedSummaryProviderConfiguration: SummaryProviderConfiguration? {
        if let id = selectedSummaryProviderConfigurationID,
           let configuration = summaryProviderEntries.first(where: { $0.id == id }) {
            return configuration
        }
        return summaryProviderEntries.first
    }

    func primarySummaryProvider() -> SummaryProvider {
        summaryProviderEntries.first(where: \.enabled)?.provider
            ?? summaryProviderEntries.first?.provider
            ?? .openAICompatible
    }

    func canRepeatSummary(_ meeting: RecentMeeting) -> Bool {
        repeatSummaryUnavailableReason(meeting) == nil
    }

    func canRepeatMeetingProcessing(_ meeting: RecentMeeting) -> Bool {
        repeatMeetingProcessingUnavailableReason(meeting) == nil
    }

    func repeatMeetingProcessingUnavailableReason(_ meeting: RecentMeeting) -> String? {
        if reprocessingMeetingIds.contains(meeting.id)
            || resummarizingMeetingIds.contains(meeting.id) {
            return String(localized: "Meeting processing is already running.")
        }
        if !meeting.canDelete {
            return String(localized: "Meeting is still being processed.")
        }
        guard meeting.jobId != nil || fileManager.fileExists(
            atPath: meeting.folderURL.appendingPathComponent(".anybrief-job-id").path
        ) else {
            return String(localized: "Meeting job information is missing.")
        }
        let rootHasAudio = hasMeetingAudio(in: meeting.folderURL)
        let bundleHasAudio = hasMeetingAudio(
            in: meeting.folderURL.appendingPathComponent("bundle", isDirectory: true)
        )
        let hasBundle = fileManager.fileExists(
            atPath: meeting.folderURL.appendingPathComponent("bundle.zip").path
        )
        if !rootHasAudio && !bundleHasAudio && !hasBundle {
            return String(localized: "Meeting audio files are missing.")
        }
        return nil
    }

    func repeatMeetingProcessing(_ meeting: RecentMeeting, mode: MeetingReprocessingMode) {
        if let reason = repeatMeetingProcessingUnavailableReason(meeting) {
            summaryActionMessage = reason
            summaryActionMessageIsError = true
            return
        }

        reprocessingMeetingIds.insert(meeting.id)
        let progressFormat = mode == .all
            ? String(localized: "Repeating all processing for %@...")
            : String(localized: "Repeating transcription for %@...")
        summaryActionMessage = String(format: progressFormat, meeting.title)
        summaryActionMessageIsError = false

        Task {
            do {
                try await repeatMeetingProcessingAction(
                    meeting.folderURL,
                    meeting.jobId,
                    meeting.title,
                    mode
                )
                reprocessingMeetingIds.remove(meeting.id)
                let completedFormat = mode == .all
                    ? String(localized: "All processing repeated for %@.")
                    : String(localized: "Transcription repeated for %@.")
                summaryActionMessage = String(format: completedFormat, meeting.title)
                summaryActionMessageIsError = false
                await refresh()
            } catch {
                await loggingService.log(
                    "Failed to repeat meeting processing for \(meeting.folderURL.lastPathComponent): \(error.localizedDescription)",
                    level: .error,
                    component: "Dashboard"
                )
                reprocessingMeetingIds.remove(meeting.id)
                summaryActionMessage = error.localizedDescription
                summaryActionMessageIsError = true
                await refresh()
            }
        }
    }

    private func hasMeetingAudio(in directory: URL) -> Bool {
        fileManager.fileExists(
            atPath: directory.appendingPathComponent("system_audio.mp3").path
        ) && fileManager.fileExists(
            atPath: directory.appendingPathComponent("microphone_audio.mp3").path
        )
    }

    func repeatSummaryUnavailableReason(_ meeting: RecentMeeting) -> String? {
        if resummarizingMeetingIds.contains(meeting.id)
            || reprocessingMeetingIds.contains(meeting.id) {
            return String(localized: "Summarization is already running.")
        }
        if !meeting.canDelete {
            return String(localized: "Meeting is still being processed.")
        }
        let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
        if !fileManager.fileExists(atPath: transcriptURL.path) {
            return String(localized: "Transcript file is missing.")
        }
        return nil
    }

    func repeatSummary(_ meeting: RecentMeeting) {
        if let reason = repeatSummaryUnavailableReason(meeting) {
            summaryActionMessage = reason
            summaryActionMessageIsError = true
            Task {
                await loggingService.log(
                    "Repeat summary unavailable for \(meeting.folderURL.lastPathComponent): \(reason)",
                    level: .warn,
                    component: "Dashboard"
                )
            }
            return
        }

        resummarizingMeetingIds.insert(meeting.id)
        summaryActionMessage = String(format: String(localized: "Repeating summarization for %@..."), meeting.title)
        summaryActionMessageIsError = false

        Task {
            do {
                let settings = await currentSummarySettings()
                let transcriptURL = meeting.folderURL.appendingPathComponent("transcript.txt", isDirectory: false)
                let transcript = try String(contentsOf: transcriptURL, encoding: .utf8)
                let existingFrontmatter = frontmatterFromSummary(in: meeting.folderURL)
                let summaryInput = Self.summaryInput(transcript: transcript, frontmatter: existingFrontmatter)
                let segments = loadMergedSegments(from: meeting.folderURL)
                let startedAt = Date()
                let providerList = settings.summaryLLMChain
                    .map { configuration in
                        let model = (try? summaryProviderRegistry.module(for: configuration.provider)
                            .metadata(from: configuration, settings: settings).model) ?? ""
                        return "\(configuration.provider.rawValue):\(model)"
                    }
                    .joined(separator: ",")
                await loggingService.log(
                    "Repeating summary for \(meeting.folderURL.lastPathComponent): providers=\(providerList), transcript_chars=\(transcript.count), metadata_frontmatter=\(existingFrontmatter == nil ? "missing" : "present")",
                    level: .info,
                    component: "Dashboard"
                )
                let summaryResult = try await summarizationService.summarizeWithMetadata(
                    transcript: summaryInput,
                    settings: settings,
                    meetingTitle: meeting.title,
                    workingDirectory: meeting.folderURL,
                    transcriptURL: transcriptURL
                )
                let elapsed = Date().timeIntervalSince(startedAt)
                try await summarizationService.writeSummary(
                    summaryResult.summary,
                    to: meeting.folderURL,
                    date: Date(),
                    durationMinutes: segments.isEmpty
                        ? Self.frontmatterInteger("duration", in: existingFrontmatter) ?? 0
                        : Self.durationMinutes(from: segments),
                    speakers: segments.isEmpty
                        ? Self.frontmatterInteger("speakers", in: existingFrontmatter) ?? 0
                        : Self.speakerCount(from: segments),
                    model: summaryResult.provider.model,
                    provider: summaryResult.provider,
                    preservedFrontmatter: existingFrontmatter,
                    includeFooter: !settings.application.disableSummaryFooter
                )
                await loggingService.log(
                    "Repeated summary for \(meeting.folderURL.lastPathComponent): provider=\(summaryResult.provider.type.rawValue), model=\(summaryResult.provider.model), transcript_chars=\(transcript.count), summary_chars=\(summaryResult.summary.count), elapsed_sec=\(String(format: "%.1f", elapsed))",
                    level: .info,
                    component: "Dashboard"
                )
                await markJobCompletedAfterRepeatSummary(meeting)
                resummarizingMeetingIds.remove(meeting.id)
                summaryActionMessage = String(format: String(localized: "Summary regenerated for %@."), meeting.title)
                summaryActionMessageIsError = false
                await refresh()
            } catch {
                await loggingService.log(
                    "Failed to repeat summary for \(meeting.folderURL.lastPathComponent): \(error.localizedDescription)",
                    level: .error,
                    component: "Dashboard"
                )
                resummarizingMeetingIds.remove(meeting.id)
                summaryActionMessage = error.localizedDescription
                summaryActionMessageIsError = true
            }
        }
    }
    /// A manual "repeat summarization" only rewrites summary.md — it doesn't run the
    /// finalization pipeline. Without this, a job left in a failed/partial state by the
    /// original run keeps that stale status forever, so the dashboard row never shows
    /// as completed even though a valid summary now exists.
    private func markJobCompletedAfterRepeatSummary(_ meeting: RecentMeeting) async {
        guard let jobId = meeting.jobId, let job = await jobRepository.get(id: jobId) else {
            return
        }
        let now = Date()
        await jobRepository.upsert(Job(
            id: job.id,
            meetingId: job.meetingId,
            status: "completed",
            stage: .completed,
            progressPercent: 100,
            source: job.source,
            createdAt: job.createdAt,
            updatedAt: now,
            completedAt: job.completedAt ?? now,
            retryCount: job.retryCount,
            error: nil,
            warnings: job.warnings
        ))
    }

    func currentSummarySettings() async -> AppSettings {
        var settings = await appSettingsStore.load(using: loggingService)
        settings.summary.enabled = summaryEnabled
        settings.prompts.summary.speakerContextPromptID = speakerContextPromptID
        settings.llm.connections = normalizedSummaryProviderConfigurations()
        settings.prompts.items = promptItems
        settings.prompts.summary.promptID = summaryPromptID
        settings.prompts.summary.connectionIDs = summaryConnectionIDs
        settings.prompts.live.promptID = livePromptID
        settings.prompts.live.connectionID = liveConnectionID
        settings.prompts.transcriptCleanup.enabled = transcriptCleanupEnabled
        settings.prompts.transcriptCleanup.promptID = transcriptCleanupPromptID
        settings.prompts.transcriptCleanup.connectionIDs = transcriptCleanupConnectionIDs
        return settings
    }

    func currentSummarySettings(for configuration: SummaryProviderConfiguration) async -> AppSettings {
        let settings = await currentSummarySettings()
        return settings
    }

    func normalizedSummaryProviderConfigurations() -> [SummaryProviderConfiguration] {
        summaryProviderEntries.map(summaryProviderRegistry.normalize)
    }

    func persistedSummaryProviderConfigurations() throws -> [SummaryProviderConfiguration] {
        var configurations = normalizedSummaryProviderConfigurations()
        for index in configurations.indices where configurations[index].provider == .openAICompatible {
            let id = configurations[index].id
            let trimmedKey = (summaryProviderAPIKeys[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedKey.isEmpty else {
                continue
            }
            let keyReference = configurations[index].openAIAPIKeyKeychainRef?.isEmpty == false
                ? configurations[index].openAIAPIKeyKeychainRef!
                : "summary-provider-\(id)-api-key"
            try keychainStore.save(key: keyReference, value: trimmedKey)
            configurations[index].openAIAPIKeyKeychainRef = keyReference
        }
        summaryProviderEntries = configurations
        return configurations
    }

    func connectionDisplayName(_ connection: LLMConnectionConfiguration) -> String {
        if let name = connection.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        let title = (try? summaryProviderRegistry.module(for: connection.provider).title) ?? connection.provider.rawValue
        let model: String
        switch connection.provider {
        case .openAICompatible:
            model = connection.openAIEffectiveModel
        case .localOllama:
            model = connection.ollamaEffectiveModel
        case .commandLine:
            model = connection.cliCommandPreset
        }
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedModel.isEmpty ? title : "\(title) · \(trimmedModel)"
    }

    func addPromptItem() {
        let item = PromptItem(name: String(localized: "New prompt"))
        promptItems.append(item)
        selectedPromptItemID = item.id
    }

    /// Prompts assigned to pickers without a "Not selected" option (summary,
    /// transcript cleanup) cannot be removed; the Live assignment is optional
    /// and gets cleared instead.
    var canRemoveSelectedPromptItem: Bool {
        guard promptItems.count > 1,
              let id = selectedPromptItemID ?? promptItems.first?.id else {
            return false
        }
        return id != summaryPromptID && id != transcriptCleanupPromptID
    }

    func removeSelectedPromptItem() {
        guard canRemoveSelectedPromptItem,
              let id = selectedPromptItemID ?? promptItems.first?.id else {
            return
        }
        promptItems.removeAll { $0.id == id }
        if livePromptID == id {
            livePromptID = nil
        }
        selectedPromptItemID = promptItems.first?.id
    }

    func loadMergedSegments(from folderURL: URL) -> [TranscriptSegment] {
        let url = folderURL.appendingPathComponent("transcript_merged.json", isDirectory: false)
        guard let data = try? Data(contentsOf: url),
              let segments = try? JSONDecoder().decode([TranscriptSegment].self, from: data) else {
            return []
        }
        return segments
    }

    static func durationMinutes(from segments: [TranscriptSegment]) -> Int {
        guard let duration = segments.map(\.endTime).max(), duration > 0 else {
            return 0
        }
        return Int((duration / 60).rounded(.up))
    }

    static func speakerCount(from segments: [TranscriptSegment]) -> Int {
        Set(segments.map(\.speaker)).count
    }

    static func frontmatterInteger(_ key: String, in frontmatter: String?) -> Int? {
        guard let frontmatter else { return nil }
        return frontmatter
            .components(separatedBy: .newlines)
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key):") }
            .flatMap {
                $0.split(separator: ":", maxSplits: 1)
                    .dropFirst()
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .flatMap(Int.init)
    }

    func frontmatterFromSummary(in folderURL: URL) -> String? {
        let summaryURL = folderURL.appendingPathComponent("summary.md", isDirectory: false)
        guard let content = try? String(contentsOf: summaryURL, encoding: .utf8) else {
            return nil
        }
        return frontmatter(in: content)
    }

    static func summaryInput(transcript: String, frontmatter: String?) -> String {
        guard let frontmatter, !frontmatter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return transcript
        }
        return """
        Meeting metadata frontmatter:
        ```yaml
        \(frontmatter)
        ```

        Transcript:
        \(transcript)
        """
    }
}
