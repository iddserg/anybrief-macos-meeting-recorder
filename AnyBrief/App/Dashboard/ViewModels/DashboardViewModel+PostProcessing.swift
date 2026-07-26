import AppKit
import Foundation

extension DashboardViewModel {
    var selectedPostProcessingRule: PostProcessingRuleConfiguration? {
        guard let selectedPostProcessingRuleID else {
            return postProcessingRules.first
        }
        return postProcessingRules.first { $0.id == selectedPostProcessingRuleID } ?? postProcessingRules.first
    }

    func selectPostProcessingRule(_ rule: PostProcessingRuleConfiguration) {
        selectedPostProcessingRuleID = rule.id
    }

    func addPostProcessingRule() {
        let rule = PostProcessingRuleConfiguration(
            title: String(localized: "New rule"),
            calendarTitlePattern: "",
            destinationFolderPath: ""
        )
        postProcessingRules.append(rule)
        selectedPostProcessingRuleID = rule.id
    }

    var canRemoveSelectedPostProcessingRule: Bool {
        selectedPostProcessingRule != nil
    }

    func removeSelectedPostProcessingRule() {
        guard let rule = selectedPostProcessingRule,
              let index = postProcessingRules.firstIndex(where: { $0.id == rule.id }) else {
            return
        }
        postProcessingRules.remove(at: index)
        selectedPostProcessingRuleID = postProcessingRules.indices.contains(index)
            ? postProcessingRules[index].id
            : postProcessingRules.last?.id
    }

    func choosePostProcessingDestination(for ruleID: String) {
        guard let index = postProcessingRules.firstIndex(where: { $0.id == ruleID }) else {
            return
        }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Export Folder")
        panel.prompt = String(localized: "Choose")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        let currentPath = postProcessingRules[index].destinationFolderPath
        if !currentPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            panel.directoryURL = URL(fileURLWithPath: currentPath, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        postProcessingRules[index].destinationFolderPath = url.path
    }

    func openPostProcessingDestination(for ruleID: String) {
        guard let rule = postProcessingRules.first(where: { $0.id == ruleID }),
              destinationExists(for: rule) else {
            return
        }
        workspace.open(URL(fileURLWithPath: rule.destinationFolderPath, isDirectory: true))
    }

    func exportMeetingSummary(_ meeting: RecentMeeting) {
        guard !exportingMeetingIds.contains(meeting.id) else {
            return
        }
        exportingMeetingIds.insert(meeting.id)
        postProcessingMessage = nil
        postProcessingMessageIsError = false

        Task {
            let settings = PostProcessingSettings(
                enabled: postProcessingEnabled,
                rules: PostProcessingSettings.normalizedRules(postProcessingRules)
            )
            let result = await postProcessingService.exportSummaryIfNeeded(
                from: meeting.folderURL,
                settings: settings,
                calendarEvent: nil
            )
            await MainActor.run {
                exportingMeetingIds.remove(meeting.id)
                postProcessingMessage = dashboardMessage(for: result)
                postProcessingMessageIsError = result.status == .failed
            }
        }
    }

    func destinationExists(for rule: PostProcessingRuleConfiguration) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: rule.destinationFolderPath, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    private func dashboardMessage(for result: PostProcessingExportResult) -> String {
        switch result.status {
        case .exported:
            if let destinationURL = result.destinationURL {
                return String(format: String(localized: "Exported to %@"), destinationURL.path)
            }
            return String(localized: "Exported.")
        case .skipped:
            return result.message
        case .failed:
            return result.message
        }
    }
}
