import SwiftUI

extension DashboardView {
    var promptsSection: some View {
        sectionCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Prompts")
                    .font(ABTypography.sectionTitle)
                    .foregroundStyle(ABDesign.primaryText)
                Text(String(localized: "Reusable prompts and which LLM connection each task uses. Connections are configured in Settings → LLM."))
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)

                HStack(alignment: .top, spacing: 14) {
                    promptCollectionColumn
                        .frame(width: 250)
                    promptEditorColumn
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                settingsSaveFooter
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    // MARK: - Collection

    private var promptCollectionColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Prompt collection"))
                .font(ABTypography.bodySemibold)
                .foregroundStyle(ABDesign.primaryText)

            ScrollView(.vertical) {
                VStack(spacing: 4) {
                    ForEach(viewModel.promptItems) { item in
                        promptCollectionRow(item)
                    }
                }
                .padding(.trailing, 2)
            }
            .scrollIndicators(.automatic)
            .frame(minHeight: 180, maxHeight: 300)

            HStack(spacing: 8) {
                Button {
                    viewModel.addPromptItem()
                } label: {
                    Image(systemName: "plus")
                        .font(ABTypography.bodySemibold)
                        .frame(width: 42, height: 24)
                }
                .buttonStyle(.bordered)

                Button {
                    viewModel.removeSelectedPromptItem()
                } label: {
                    Image(systemName: "minus")
                        .font(ABTypography.bodySemibold)
                        .frame(width: 42, height: 24)
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canRemoveSelectedPromptItem)
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.62))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
        )
    }

    private func promptCollectionRow(_ item: PromptItem) -> some View {
        let isSelected = viewModel.selectedPromptItemID == item.id
        return Button {
            viewModel.selectedPromptItemID = item.id
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "text.alignleft")
                    .frame(width: 16)
                Text(item.name.isEmpty ? String(localized: "Untitled prompt") : item.name)
                    .font(ABTypography.captionMedium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if item.id == viewModel.summaryPromptID {
                    promptUsageBadge(String(localized: "Summary"))
                }
                if item.id == viewModel.livePromptID {
                    promptUsageBadge(String(localized: "Live"))
                }
                if item.id == viewModel.transcriptCleanupPromptID {
                    promptUsageBadge(String(localized: "Transcript"))
                }
            }
            .foregroundStyle(isSelected ? Color.white : ABDesign.primaryText)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(isSelected ? ABDesign.accent : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func promptUsageBadge(_ text: String) -> some View {
        Text(text)
            .font(ABTypography.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Color.black.opacity(0.12))
            .clipShape(Capsule())
    }

    // MARK: - Editor

    @ViewBuilder
    private var promptEditorColumn: some View {
        if let binding = selectedPromptItemBinding {
            VStack(alignment: .leading, spacing: 10) {
                labeledField(String(localized: "Name"), help: nil) {
                    TextField("", text: binding.name)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                }

                labeledField(
                    String(localized: "Prompt text"),
                    help: String(localized: "Use %lang% to insert the app language.")
                ) {
                    TextEditor(text: binding.text)
                        .font(ABTypography.field)
                        .scrollContentBackground(.hidden)
                        .padding(10)
                        .frame(minHeight: 200, maxHeight: .infinity)
                        .background(Color.white.opacity(0.86))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.black.opacity(0.16), lineWidth: 1)
                        )
                }

                labeledField(
                    String(localized: "Meeting title patterns"),
                    help: String(localized: "Optional, comma-separated. When a meeting title contains one of these patterns, this prompt is used for its summary instead of the assigned one.")
                ) {
                    TextField(String(localized: "e.g. standup, 1:1"), text: promptTitlePatternsBinding(binding))
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                }
            }
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
        return $viewModel.promptItems[index]
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
