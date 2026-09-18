import SwiftUI

extension DashboardView {
    var promptsSection: some View {
        HStack(spacing: 0) {
            promptCollectionColumn.frame(width: WorkspaceDesign.listWidth)
                .background(WorkspaceDesign.secondarySurface)
            Divider()
            promptEditorColumn
                .padding(WorkspaceDesign.inset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Collection

    private var promptCollectionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                VStack(spacing: WorkspaceDesign.listRowSpacing) {
                    ForEach(viewModel.promptItems) { item in
                        promptCollectionRow(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)

            WorkspaceCollectionActions {
                Button {
                    viewModel.addPromptItem()
                } label: {
                    WorkspaceCollectionActionIcon(systemImage: "plus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "New prompt"))
                .help(Text("New prompt"))

                Button {
                    viewModel.removeSelectedPromptItem()
                } label: {
                    WorkspaceCollectionActionIcon(systemImage: "minus")
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "Delete prompt"))
                .help(Text("Delete prompt"))
                .disabled(!viewModel.canRemoveSelectedPromptItem)
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func promptCollectionRow(_ item: PromptItem) -> some View {
        let isSelected = viewModel.selectedPromptItemID == item.id
        return Button {
            viewModel.selectedPromptItemID = item.id
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.alignleft")
                    .frame(width: 16).padding(.top, 2)
                VStack(alignment: .leading, spacing: WorkspaceDesign.listDetailSpacing) {
                    Text(item.name.isEmpty ? String(localized: "Untitled prompt") : item.name)
                        .font(ABTypography.bodyMedium)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    if item.id == viewModel.summaryPromptID {
                        promptUsageBadge(String(localized: "Summary"))
                    }
                    if item.id == viewModel.transcriptCleanupPromptID {
                        promptUsageBadge(String(localized: "Transcript"))
                    }
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(ABDesign.primaryText)
            .padding(.horizontal, 10).padding(.vertical, WorkspaceDesign.listRowVerticalInset)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background(isSelected ? WorkspaceDesign.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func promptUsageBadge(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .font(ABTypography.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(ABDesign.badgeBackground)
            .clipShape(Capsule())
    }

    // MARK: - Editor

    @ViewBuilder
    private var promptEditorColumn: some View {
        if let binding = selectedPromptItemBinding {
            VStack(alignment: .leading, spacing: 20) {
                labeledField(String(localized: "Name"), help: nil) {
                    TextField("", text: binding.name)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                }
                .fixedSize(horizontal: false, vertical: true)

                labeledField(
                    String(localized: "Prompt text"),
                    help: String(localized: "Use %lang% to insert the app language.")
                ) {
                    TextEditor(text: binding.text)
                        .font(ABTypography.field)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 0, maxHeight: .infinity)
                        .background(ABDesign.controlBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(ABDesign.border, lineWidth: 1)
                        )
                }
                .frame(minHeight: 0, maxHeight: .infinity)

                labeledField(
                    String(localized: "Meeting title patterns"),
                    help: String(localized: "Optional, comma-separated. When a meeting title contains one of these patterns, this prompt is used for its summary instead of the assigned one.")
                ) {
                    TextField(String(localized: "e.g. standup, 1:1"), text: promptTitlePatternsBinding(binding))
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(String(localized: "Select or create a prompt."))
                    .font(ABTypography.body)
                    .foregroundStyle(ABDesign.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var selectedPromptItemBinding: Binding<PromptItem>? {
        let selectedIndex = viewModel.promptItems.firstIndex {
            $0.id == viewModel.selectedPromptItemID
        }
        guard let index = selectedIndex ?? viewModel.promptItems.indices.first else {
            return nil
        }
        return WorkspaceCollectionBinding.item(viewModel.promptItems[index], in: $viewModel.promptItems)
    }

    private func promptTitlePatternsBinding(_ item: Binding<PromptItem>) -> Binding<String> {
        Binding(
            get: { item.wrappedValue.titlePatterns.joined(separator: ", ") },
            set: { newValue in
                item.wrappedValue.titlePatterns = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    // MARK: - Assignments

    /// Picker over enabled LLM connections; the nil tag is Auto (fallback
    /// chain over all enabled connections in pool order).
    func connectionPicker(selection: Binding<String?>) -> some View {
        Picker("", selection: selection) {
            Text(String(localized: "Auto")).tag(String?.none)
            ForEach(viewModel.summaryProviderEntries.filter(\.enabled)) { connection in
                Text(viewModel.connectionDisplayName(connection)).tag(String?.some(connection.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)
    }

    /// Adapts an ordered connection-ID chain to the single-choice picker:
    /// exactly one id reads as that id, anything else reads as Auto (empty).
    func singleConnectionSelection(_ ids: Binding<[String]>) -> Binding<String?> {
        Binding(
            get: { ids.wrappedValue.count == 1 ? ids.wrappedValue.first : nil },
            set: { newValue in
                ids.wrappedValue = newValue.map { [$0] } ?? []
            }
        )
    }

    func promptPicker(selection: Binding<String?>, allowsNone: Bool) -> some View {
        Picker("", selection: selection) {
            if allowsNone {
                Text(String(localized: "Not selected")).tag(String?.none)
            }
            ForEach(viewModel.promptItems) { item in
                Text(item.name.isEmpty ? String(localized: "Untitled prompt") : item.name)
                    .tag(String?.some(item.id))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(maxWidth: 320, alignment: .leading)
    }
}
