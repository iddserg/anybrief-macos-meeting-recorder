import SwiftUI

extension DashboardView {
    var postProcessingSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            postProcessingTabsBar

            Group {
                switch selectedPostProcessingTab {
                case .summary:
                    automaticSummaryGroup
                case .transcript:
                    transcriptCleanupGroup
                case .export:
                    exportGroup
                }
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: selectedPostProcessingTab != .export ? .infinity : nil,
                alignment: .topLeading
            )

            settingsSaveFooter
        }
        .frame(
            maxWidth: 920,
            maxHeight: selectedPostProcessingTab != .export ? .infinity : nil,
            alignment: .leading
        )
    }

    var postProcessingTabsBar: some View {
        HStack(spacing: 0) {
            ForEach(PostProcessingTab.allCases) { tab in
                Button {
                    selectedPostProcessingTab = tab
                } label: {
                    Text(tab.title)
                        .font(ABTypography.bodyMedium)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 42)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(selectedPostProcessingTab == tab ? Color.white : ABDesign.primaryText)
                .background(
                    Rectangle()
                        .fill(selectedPostProcessingTab == tab ? ABDesign.accent : Color.clear)
                )
                .accessibilityIdentifier("postprocessing.tab.\(tab.rawValue)")

                if tab.id != PostProcessingTab.allCases.last?.id {
                    Rectangle()
                        .fill(ABDesign.hairline)
                        .frame(width: 1, height: 42)
                }
            }
        }
        .frame(height: 42)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(ABDesign.border, lineWidth: 1)
        )
    }

    var automaticSummaryGroup: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceSettingsSectionHeader(title: String(localized: "Automatic summary"),
                isOn: $viewModel.summaryEnabled, showsStatus: false)
            processingAssignmentFields(promptTitle: String(localized: "Summary prompt"),
                promptHelp: String(localized: "Used when no meeting title pattern matches. Patterns are configured per prompt in the Prompts tab."),
                prompt: $viewModel.summaryPromptID, connections: $viewModel.summaryConnectionIDs)
            processingSpeakerContext
        }.controlSize(.regular)
    }

    var transcriptCleanupGroup: some View {
        VStack(alignment: .leading, spacing: 16) {
            WorkspaceSettingsSectionHeader(title: String(localized: "Transcript cleanup"),
                isOn: $viewModel.transcriptCleanupEnabled, showsStatus: false)
            processingAssignmentFields(promptTitle: String(localized: "Cleanup prompt"),
                promptHelp: String(localized: "Runs after transcription and before summarization: fixes recognition errors and fills in speaker names using calendar context. Overwrites the transcript with the cleaned version, so the summary and any exports use it too."),
                prompt: $viewModel.transcriptCleanupPromptID, connections: $viewModel.transcriptCleanupConnectionIDs)
            processingSpeakerContext
        }.controlSize(.regular)
    }

    private func processingAssignmentFields(promptTitle: String, promptHelp: String,
        prompt: Binding<String?>, connections: Binding<[String]>) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                processingPromptField(title: promptTitle, help: promptHelp, selection: prompt).frame(width: 300)
                processingConnectionField(connections).frame(width: 260)
            }
            VStack(alignment: .leading, spacing: 16) {
                processingPromptField(title: promptTitle, help: promptHelp, selection: prompt)
                processingConnectionField(connections)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func processingPromptField(title: String, help: String, selection: Binding<String?>) -> some View {
        labeledField(title, help: help) { promptPicker(selection: selection, allowsNone: false) }
    }

    private func processingConnectionField(_ connections: Binding<[String]>) -> some View {
        labeledField("LLM", help: String(localized: "Auto tries enabled connections top to bottom in their LLM tab order. Pick a specific connection to always use only that one.")) {
            connectionPicker(selection: singleConnectionSelection(connections))
        }
    }

    private var processingSpeakerContext: some View {
        labeledField(String(localized: "Speaker context"),
            help: String(localized: "Optional hints for the summary model about who is speaking. Shared with transcript cleanup. Manage the text in the Prompts tab.")) {
            promptPicker(selection: $viewModel.speakerContextPromptID, allowsNone: true)
        }
    }

    var exportGroup: some View {
        VStack(alignment: .leading, spacing: 14) {
            postProcessingHeader

            HStack(alignment: .top, spacing: 14) {
                postProcessingRuleList
                    .frame(width: 260)

                if let binding = selectedPostProcessingRuleBinding {
                    postProcessingRuleDetails(binding)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                } else {
                    Text(String(localized: "No post-processing rules configured."))
                        .font(ABTypography.body)
                        .foregroundStyle(ABDesign.secondaryText)
                }
            }

            Divider()

            postProcessingManualExport
        }
    }

    var postProcessingHeader: some View {
        WorkspaceSettingsSectionHeader(
            title: String(localized: "Export"),
            isOn: $viewModel.postProcessingEnabled
        )
    }

    var postProcessingRuleList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Rules"))
                .font(ABTypography.bodySemibold)
                .foregroundStyle(ABDesign.primaryText)

            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    ForEach($viewModel.postProcessingRules) { $rule in
                        postProcessingRuleRow($rule)
                    }
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: 300)

            HStack(spacing: 8) {
                Button {
                    viewModel.addPostProcessingRule()
                } label: {
                    WorkspaceCollectionActionIcon(systemImage: "plus")
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.removeSelectedPostProcessingRule()
                } label: {
                    WorkspaceCollectionActionIcon(systemImage: "minus")
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canRemoveSelectedPostProcessingRule)
            }
        }
        .padding(10)
        .background(ABDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ABDesign.badgeBackground, lineWidth: 1)
        )
    }

    func postProcessingRuleRow(_ rule: Binding<PostProcessingRuleConfiguration>) -> some View {
        let value = rule.wrappedValue
        let isSelected = viewModel.selectedPostProcessingRuleID == value.id
        let destinationExists = viewModel.destinationExists(for: value)

        return HStack(spacing: 7) {
            Button {
                viewModel.selectPostProcessingRule(value)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: destinationExists ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(destinationExists ? ABDesign.green : ABDesign.yellow)
                        .frame(width: 16)
                    Text(value.title)
                        .font(ABTypography.captionMedium)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? Color.white : ABDesign.primaryText)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(isSelected ? ABDesign.accent : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)

            Toggle("", isOn: rule.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
    }

    var selectedPostProcessingRuleBinding: Binding<PostProcessingRuleConfiguration>? {
        let selectedIndex = viewModel.postProcessingRules.firstIndex {
            $0.id == viewModel.selectedPostProcessingRuleID
        }
        guard let index = selectedIndex ?? viewModel.postProcessingRules.indices.first else {
            return nil
        }
        return WorkspaceCollectionBinding.item(viewModel.postProcessingRules[index], in: $viewModel.postProcessingRules)
    }

    func postProcessingRuleDetails(_ rule: Binding<PostProcessingRuleConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField(String(localized: "Name")) {
                TextField("", text: rule.title)
                    .textFieldStyle(.roundedBorder)
                    .font(ABTypography.field)
            }

            labeledField(
                String(localized: "Calendar title"),
                help: String(localized: "The rule runs when the calendar event title matches this pattern.")
            ) {
                TextField("", text: rule.calendarTitlePattern)
                    .textFieldStyle(.roundedBorder)
                    .font(ABTypography.field)
            }

            labeledField(String(localized: "Match")) {
                Picker("", selection: rule.matchMode) {
                    Text(String(localized: "Contains")).tag(PostProcessingRuleConfiguration.MatchMode.contains)
                    Text(String(localized: "Exact")).tag(PostProcessingRuleConfiguration.MatchMode.exact)
                    Text(String(localized: "Regex")).tag(PostProcessingRuleConfiguration.MatchMode.regex)
                }
                .pickerStyle(.segmented)
                .frame(width: 260)
            }

            labeledField(String(localized: "Export content")) {
                Picker("", selection: rule.exportContent) {
                    Text(String(localized: "Summary")).tag(PostProcessingRuleConfiguration.ExportContent.summary)
                    Text(String(localized: "Transcript")).tag(PostProcessingRuleConfiguration.ExportContent.transcript)
                    Text(String(localized: "Both")).tag(PostProcessingRuleConfiguration.ExportContent.both)
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
            }

            labeledField(
                String(localized: "Folder"),
                help: String(localized: "Only existing folders are used. AnyBrief copies selected files and never moves the local meeting.")
            ) {
                HStack(spacing: 8) {
                    settingsReadOnlyField(rule.wrappedValue.destinationFolderPath.isEmpty ? "—" : rule.wrappedValue.destinationFolderPath) {
                        viewModel.copyToPasteboard(rule.wrappedValue.destinationFolderPath)
                    }
                    settingsActionButton(String(localized: "Choose")) {
                        viewModel.choosePostProcessingDestination(for: rule.wrappedValue.id)
                    }
                    settingsActionButton(String(localized: "Open")) {
                        viewModel.openPostProcessingDestination(for: rule.wrappedValue.id)
                    }
                    .disabled(!viewModel.destinationExists(for: rule.wrappedValue))
                }
            }

            labeledField(
                String(localized: "Filename"),
                help: String(localized: "Available tokens: {date}, {calendarTitle}, {topic}, {type}.")
            ) {
                TextField("", text: rule.filenameTemplate)
                    .textFieldStyle(.roundedBorder)
                    .font(ABTypography.field)
            }

            labeledField(String(localized: "If file exists")) {
                Picker("", selection: rule.conflictBehavior) {
                    Text(String(localized: "Skip")).tag(PostProcessingRuleConfiguration.ConflictBehavior.skip)
                    Text(String(localized: "Overwrite")).tag(PostProcessingRuleConfiguration.ConflictBehavior.overwrite)
                    Text(String(localized: "Add suffix")).tag(PostProcessingRuleConfiguration.ConflictBehavior.addSuffix)
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
            }
        }
        .disabled(!viewModel.postProcessingEnabled)
        .opacity(viewModel.postProcessingEnabled ? 1 : 0.45)
    }

    var postProcessingManualExport: some View {
        DisclosureGroup(isExpanded: $recentExportsExpanded) {
            postProcessingManualExportList
                .padding(.top, 10)
        } label: {
            HStack {
                Text(String(localized: "Recent meetings"))
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                Spacer()
                if let message = viewModel.postProcessingMessage {
                    Text(message)
                        .font(ABTypography.caption)
                        .foregroundStyle(viewModel.postProcessingMessageIsError ? ABDesign.red : ABDesign.secondaryText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
        }
    }

    var postProcessingManualExportList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.recentMeetings.prefix(12)) { meeting in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                            .font(ABTypography.bodyMedium)
                            .lineLimit(1)
                        Text(meeting.folderURL.path)
                            .font(ABTypography.caption)
                            .foregroundStyle(ABDesign.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button {
                        viewModel.exportMeeting(meeting)
                    } label: {
                        Label(String(localized: "Export"), systemImage: "tray.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .frame(width: 28, height: 24)
                    }
                    .buttonStyle(.bordered)
                    .help(Text(String(localized: "Export using matching rule")))
                    .disabled(!viewModel.hasExportableArtifacts(meeting) || viewModel.exportingMeetingIds.contains(meeting.id))
                }
                .padding(.vertical, 7)

                if meeting.id != viewModel.recentMeetings.prefix(12).last?.id {
                    Divider()
                }
            }
        }
        .padding(.horizontal, 10)
        .background(ABDesign.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(ABDesign.badgeBackground, lineWidth: 1)
        )
    }
}
