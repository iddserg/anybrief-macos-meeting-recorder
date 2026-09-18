import SwiftUI

extension DashboardView {
    var templatesWorkspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 26) {
                WorkspaceTab(title: String(localized: "Prompts"), selected: templateTab == "prompts") { templateTab = "prompts" }
                WorkspaceTab(title: String(localized: "Export"), selected: templateTab == "export") { templateTab = "export" }
                WorkspaceTab(title: String(localized: "Processing"), selected: templateTab == "processing") { templateTab = "processing" }
                Spacer()
            }.padding(.horizontal, WorkspaceDesign.inset)
            Divider()
            Group {
                if templateTab == "export" { exportWorkspace }
                else if templateTab == "prompts" { promptsSection }
                else {
                    VStack(spacing: 0) {
                        VStack(spacing: 0) {
                            HStack(spacing: 26) {
                                WorkspaceTab(title: String(localized: "Summary"), selected: selectedPostProcessingTab == .summary) {
                                    selectedPostProcessingTab = .summary
                                }.accessibilityIdentifier("postprocessing.tab.summary")
                                WorkspaceTab(title: String(localized: "Transcript cleanup"), selected: selectedPostProcessingTab == .transcript) {
                                    selectedPostProcessingTab = .transcript
                                }.accessibilityIdentifier("postprocessing.tab.transcript")
                                Spacer()
                            }
                            Divider()
                        }.padding(.horizontal, WorkspaceDesign.inset)
                        ScrollView {
                            Group {
                                if selectedPostProcessingTab == .summary { automaticSummaryGroup }
                                else { transcriptCleanupGroup }
                            }.padding(.horizontal, WorkspaceDesign.inset).padding(.vertical, 16)
                                .frame(maxWidth: 760, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            settingsSaveFooter
                .padding(.horizontal, WorkspaceDesign.inset).padding(.vertical, 12)
        }.background(WorkspaceDesign.surface)
    }

    var exportWorkspace: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Export", isOn: $viewModel.postProcessingEnabled).toggleStyle(.switch).controlSize(.small)
                    .font(ABTypography.bodyMedium).padding(.horizontal, 14).padding(.top, 18)
                Divider()
                ScrollView {
                    LazyVStack(spacing: WorkspaceDesign.listRowSpacing) {
                        ForEach(viewModel.postProcessingRules) { rule in
                            Button { viewModel.selectPostProcessingRule(rule) } label: {
                                VStack(alignment: .leading, spacing: WorkspaceDesign.listDetailSpacing) {
                                    HStack {
                                        Text(rule.title.isEmpty ? String(localized: "New rule") : rule.title).font(ABTypography.bodyMedium).lineLimit(2)
                                        Spacer(minLength: 0)
                                        if !rule.enabled { Image(systemName: "pause.circle").foregroundStyle(ABDesign.secondaryText) }
                                    }
                                    Text(rule.calendarTitlePattern.isEmpty ? String(localized: "No pattern") : rule.calendarTitlePattern)
                                        .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText).lineLimit(2)
                                }.padding(.horizontal, 12).padding(.vertical, WorkspaceDesign.listRowVerticalInset).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(viewModel.selectedPostProcessingRule?.id == rule.id ? WorkspaceDesign.surface : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 10)
                }
                WorkspaceCollectionActions {
                    Button(action: viewModel.addPostProcessingRule) {
                        WorkspaceCollectionActionIcon(systemImage: "plus")
                    }
                    .accessibilityLabel(String(localized: "New rule"))
                    .help(Text("New rule"))
                    Button(action: viewModel.removeSelectedPostProcessingRule) {
                        WorkspaceCollectionActionIcon(systemImage: "minus")
                    }
                    .disabled(!viewModel.canRemoveSelectedPostProcessingRule)
                    .accessibilityLabel(String(localized: "Delete rule"))
                    .help(Text("Delete rule"))
                }
            }.frame(width: WorkspaceDesign.listWidth).background(WorkspaceDesign.secondarySurface)
            Divider()
            if let binding = selectedPostProcessingRuleBinding {
                ScrollView { exportRuleEditor(binding).padding(WorkspaceDesign.inset) }
            } else {
                WorkspaceEmptyState(icon: "folder.badge.gearshape", title: String(localized: "No export rules"), detail: String(localized: "Create a rule to save meeting materials into an existing folder."))
            }
        }
    }

    func exportRuleEditor(_ rule: Binding<PostProcessingRuleConfiguration>) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(alignment: .top) {
                TextField("Name", text: rule.title).textFieldStyle(.plain).font(ABTypography.pageTitle)
                Toggle("Enabled", isOn: rule.enabled).toggleStyle(.switch).controlSize(.small).fixedSize()
            }
            if !viewModel.postProcessingEnabled {
                Label("Automatic export is disabled. You can still edit rules.", systemImage: "pause.circle")
                    .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
            }
            VStack(alignment: .leading, spacing: 16) {
                Text("When to apply").font(ABTypography.itemTitle)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Calendar title").font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                    HStack(spacing: 10) {
                        Picker("Match", selection: rule.matchMode) {
                            Text("Contains").tag(PostProcessingRuleConfiguration.MatchMode.contains)
                            Text("Exact").tag(PostProcessingRuleConfiguration.MatchMode.exact)
                            Text("Regex").tag(PostProcessingRuleConfiguration.MatchMode.regex)
                        }.labelsHidden().frame(width: 130)
                        TextField("Pattern", text: rule.calendarTitlePattern).textFieldStyle(.roundedBorder)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                Text("What and where to save").font(ABTypography.itemTitle)
                exportField("Materials") {
                    Picker("Materials", selection: rule.exportContent) {
                        Text("Summary").tag(PostProcessingRuleConfiguration.ExportContent.summary)
                        Text("Transcript").tag(PostProcessingRuleConfiguration.ExportContent.transcript)
                        Text("Both").tag(PostProcessingRuleConfiguration.ExportContent.both)
                    }.labelsHidden().pickerStyle(.segmented)
                }
                exportField("Folder") {
                    HStack {
                        Image(systemName: "folder").foregroundStyle(ABDesign.secondaryText)
                        Text(rule.wrappedValue.destinationFolderPath.isEmpty ? String(localized: "Not selected") : rule.wrappedValue.destinationFolderPath)
                            .font(ABTypography.body).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                        Spacer(minLength: 4)
                        Button("Choose") { viewModel.choosePostProcessingDestination(for: rule.wrappedValue.id) }.buttonStyle(WorkspaceButtonStyle())
                    }
                }
                exportField("Filename") {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Filename", text: rule.filenameTemplate).textFieldStyle(.roundedBorder)
                        Text("{date} · {calendarTitle} · {topic} · {type}").font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                    }
                }
                exportField("If file exists") {
                    Picker("If file exists", selection: rule.conflictBehavior) {
                        Text("Add suffix").tag(PostProcessingRuleConfiguration.ConflictBehavior.addSuffix)
                        Text("Skip").tag(PostProcessingRuleConfiguration.ConflictBehavior.skip)
                        Text("Overwrite").tag(PostProcessingRuleConfiguration.ConflictBehavior.overwrite)
                    }.labelsHidden()
                }
            }
            Divider()
            exportPreview(rule.wrappedValue)
        }.font(ABTypography.body).controlSize(.regular).frame(maxWidth: .infinity, alignment: .leading)
    }

    func exportField<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(title).font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
                .frame(width: 104, alignment: .leading).padding(.top, 7)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func exportPreview(_ rule: PostProcessingRuleConfiguration) -> some View {
        let title = exportPreviewTitle.isEmpty ? String(localized: "Product meeting") : exportPreviewTitle
        let matches = PostProcessingService.matches(title: title, rule: rule)
        let validType = rule.exportContent != .both || rule.filenameTemplate.contains("{type}")
        let date = Date()
        let event = CalendarEvent(uid: "preview", originalUID: "preview", calendarName: "", title: title,
                                  startAt: date, endAt: date, timeZone: TimeZone.current.identifier,
                                  location: nil, notes: nil, organizer: nil, attendees: [], meetingURLs: [],
                                  participantCount: 0, hasMeetingURL: false, recurrenceRule: nil, recurrenceID: nil)
        let types = rule.exportContent == .both ? ["summary", "transcript"] : [rule.exportContent.rawValue]
        return VStack(alignment: .leading, spacing: 14) {
            Text("Preview").font(ABTypography.itemTitle)
            TextField("Product meeting", text: $exportPreviewTitle).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("export.preview.title")
            Label(matches ? String(localized: "Matches") : String(localized: "Does not match"), systemImage: matches ? "checkmark" : "minus.circle")
                .font(ABTypography.captionMedium).foregroundStyle(matches ? ABDesign.green : ABDesign.secondaryText)
            if !validType {
                Label("Include {type} to export both materials.", systemImage: "exclamationmark.triangle").foregroundStyle(ABDesign.red)
            }
            if !viewModel.destinationExists(for: rule) {
                Label("Choose an existing destination folder.", systemImage: "folder.badge.questionmark").foregroundStyle(ABDesign.red)
            }
            if matches && validType {
                ForEach(types, id: \.self) { type in
                    Label(PostProcessingService.renderFilename(template: rule.filenameTemplate, meetingFolderURL: URL(fileURLWithPath: "/preview"), calendarEvent: event, summaryContent: "", type: type), systemImage: "doc.text")
                        .font(ABTypography.caption).textSelection(.enabled)
                }
            }
            Text("Example filenames before resolving existing files. {topic} comes from the meeting summary.")
                .font(ABTypography.caption).foregroundStyle(ABDesign.secondaryText)
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceDesign.secondarySurface).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
