
import SwiftUI

extension DashboardView {
    var settingsCategoryTabs: some View {
        HStack(spacing: 24) {
            ForEach(SettingsCategory.allCases) { category in
                WorkspaceTab(title: category.title, selected: selectedSettingsCategory == category) {
                    selectedSettingsCategory = category
                }
                .accessibilityIdentifier("settings.category.\(category.rawValue)")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WorkspaceDesign.inset)
    }

    var summarySettingsGroup: some View {
        HStack(spacing: 0) {
            summaryProviderSidebar
                .frame(width: WorkspaceDesign.listWidth)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let configuration = selectedSummaryProviderConfigurationBinding {
                        summaryProviderDetails(configuration)
                            .id(configuration.wrappedValue.id)
                    } else {
                        Text(String(localized: "No LLM connections configured."))
                            .foregroundStyle(ABDesign.secondaryText)
                        summaryProviderAddMenu
                    }
                }
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(WorkspaceDesign.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    var selectedSummaryProviderConfigurationBinding: Binding<SummaryProviderConfiguration>? {
        let selectedIndex = viewModel.summaryProviderEntries.firstIndex {
            $0.id == viewModel.selectedSummaryProviderConfigurationID
        }
        guard let index = selectedIndex ?? viewModel.summaryProviderEntries.indices.first else {
            return nil
        }
        return WorkspaceCollectionBinding.item(viewModel.summaryProviderEntries[index], in: $viewModel.summaryProviderEntries)
    }

    func summaryProviderAPIKeyBinding(for id: String) -> Binding<String> {
        Binding(
            get: { viewModel.summaryProviderAPIKeys[id] ?? "" },
            set: { value in
                guard viewModel.summaryProviderEntries.contains(where: { $0.id == id }) else { return }
                viewModel.summaryProviderAPIKeys[id] = value
            }
        )
    }

    func summaryProviderModule(for provider: SummaryProvider) -> (any SummaryProviderModule)? {
        try? viewModel.summaryProviderRegistry.module(for: provider)
    }

    func localizedSummaryProviderTitle(_ module: any SummaryProviderModule) -> LocalizedStringKey {
        LocalizedStringKey(module.title)
    }

    var summaryProviderSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical) {
                VStack(spacing: WorkspaceDesign.listRowSpacing) {
                    ForEach(viewModel.summaryProviderEntries) { configuration in
                        summaryProviderSidebarRow(WorkspaceCollectionBinding.item(configuration, in: $viewModel.summaryProviderEntries))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)

            WorkspaceCollectionActions {
                summaryProviderAddMenu
                summaryProviderRemoveButton
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(WorkspaceDesign.secondarySurface)
    }

    func summaryProviderSidebarRow(_ configuration: Binding<SummaryProviderConfiguration>) -> some View {
        let value = configuration.wrappedValue
        let isSelected = viewModel.selectedSummaryProviderConfigurationID == value.id
        let module = summaryProviderModule(for: value.provider)

        return HStack(spacing: 7) {
            Button {
                viewModel.selectSummaryProviderConfiguration(value)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: module?.systemImage ?? "questionmark.square")
                        .frame(width: 16)
                    Text(summaryProviderSidebarLabel(value, module: module))
                        .font(ABTypography.bodyMedium)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(isSelected ? ABDesign.accent : ABDesign.primaryText)
                .padding(.horizontal, 8).padding(.vertical, WorkspaceDesign.listRowVerticalInset)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .background(isSelected ? ABDesign.selectedSidebarBackground : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("llm.connection.\(value.id)")

            Toggle("", isOn: configuration.enabled)
                .labelsHidden()
                .toggleStyle(.checkbox)

            VStack(spacing: 0) {
                Button {
                    viewModel.moveSummaryProviderConfiguration(value, direction: -1)
                } label: {
                    Image(systemName: "chevron.up")
                        .font(ABTypography.iconTiny)
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.moveSummaryProviderConfiguration(value, direction: 1)
                } label: {
                    Image(systemName: "chevron.down")
                        .font(ABTypography.iconTiny)
                }
                .buttonStyle(.plain)
            }
            .frame(width: 14)
        }
        .frame(maxWidth: .infinity, minHeight: 34)
    }

    var summaryProviderAddMenu: some View {
        Menu {
            ForEach(viewModel.summaryProviderRegistry.modules, id: \.id) { module in
                Button {
                    viewModel.addSummaryProviderConfiguration(module.id)
                } label: {
                    Label {
                        Text(localizedSummaryProviderTitle(module))
                    } icon: {
                        Image(systemName: module.systemImage)
                    }
                }
                .disabled(!viewModel.canAddSummaryProviderConfiguration(module.id))
            }
        } label: {
            WorkspaceCollectionActionIcon(systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(localized: "Add connection"))
        .help(Text("Add connection"))
    }

    var summaryProviderRemoveButton: some View {
        Button {
            guard let configuration = selectedSummaryProviderConfigurationBinding?.wrappedValue else {
                return
            }
            viewModel.removeSummaryProviderConfiguration(configuration)
        } label: {
            WorkspaceCollectionActionIcon(systemImage: "minus")
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "Remove connection"))
        .help(Text("Remove connection"))
        .disabled(viewModel.summaryProviderEntries.count <= 1)
    }

    @ViewBuilder
    func summaryProviderDetails(_ configuration: Binding<SummaryProviderConfiguration>) -> some View {
        let module = summaryProviderModule(for: configuration.wrappedValue.provider)
        VStack(alignment: .leading, spacing: 20) {
            SummaryProviderSettingsControls.labeledField(
                String(localized: "Name"),
                help: String(localized: "Optional label shown instead of the provider/model name in connection pickers.")
            ) {
                TextField(
                    module.map(localizedSummaryProviderTitleString) ?? configuration.wrappedValue.provider.rawValue,
                    text: SummaryProviderSettingsControls.optionalStringBinding(configuration.name)
                )
                .font(ABTypography.field)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
            }

            SummaryProviderSettingsControls.wrappingFieldRow {
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Timeout (sec)"),
                    help: String(localized: "How long to wait for this connection before treating the request as failed.")
                ) {
                    TextField(
                        "",
                        value: SummaryProviderSettingsControls.optionalIntBinding(
                            configuration.timeoutSec,
                            default: SummaryProviderConfiguration.defaultTimeoutSec
                        ),
                        format: .number
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: WorkspaceDesign.numericFieldWidth)
                }
                SummaryProviderSettingsControls.labeledField(
                    String(localized: "Retries"),
                    help: String(localized: "Number of attempts for this connection before falling back to the next one in the chain.")
                ) {
                    TextField(
                        "",
                        value: SummaryProviderSettingsControls.optionalIntBinding(
                            configuration.retryCount,
                            default: SummaryProviderConfiguration.defaultRetryCount
                        ),
                        format: .number
                    )
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: WorkspaceDesign.numericFieldWidth)
                }
            }

            if let module {
                module.makeSettingsView(context: SummaryProviderSettingsViewContext(
                    configuration: configuration,
                    apiKey: summaryProviderAPIKeyBinding(for: configuration.wrappedValue.id)
                ))
            } else {
                Text(String(localized: "Unsupported summary provider."))
                    .font(ABTypography.body)
                    .foregroundStyle(ABDesign.secondaryText)
            }

            summaryProviderDiagnosticRow(configuration.wrappedValue)
        }
    }

    func localizedSummaryProviderTitleString(_ module: any SummaryProviderModule) -> String {
        String(localized: String.LocalizationValue(module.title))
    }

    func summaryProviderSidebarLabel(_ configuration: SummaryProviderConfiguration, module: (any SummaryProviderModule)?) -> String {
        if let name = configuration.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return module.map(localizedSummaryProviderTitleString) ?? configuration.provider.rawValue
    }

    func summaryProviderDiagnosticRow(_ configuration: SummaryProviderConfiguration) -> some View {
        HStack(spacing: 10) {
            Button {
                viewModel.checkSummaryProviderConfiguration(configuration)
            } label: {
                Label(
                    viewModel.isCheckingSummaryProvider(configuration)
                        ? String(localized: "Checking…")
                        : String(localized: "Check"),
                    systemImage: "checkmark.circle"
                )
            }
            .buttonStyle(WorkspaceButtonStyle())
            .disabled(viewModel.isCheckingSummaryProvider(configuration))

            if let result = viewModel.summaryProviderDiagnosticResult(for: configuration) {
                summaryProviderDiagnosticBanner(result)
            }

            Spacer(minLength: 0)
        }
    }

    func summaryProviderDiagnosticBanner(_ result: SummaryProviderDiagnosticResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: summaryProviderDiagnosticIcon(result.status))
                .font(ABTypography.captionSemibold)
            Text(result.message)
                .font(ABTypography.caption)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(summaryProviderDiagnosticColor(result.status))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(summaryProviderDiagnosticColor(result.status).opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    func summaryProviderDiagnosticIcon(_ status: SummaryProviderDiagnosticResult.Status) -> String {
        switch status {
        case .success:
            return "checkmark.circle.fill"
        case .warning:
            return "arrow.clockwise"
        case .failure:
            return "exclamationmark.triangle.fill"
        }
    }

    func summaryProviderDiagnosticColor(_ status: SummaryProviderDiagnosticResult.Status) -> Color {
        switch status {
        case .success:
            return ABDesign.green
        case .warning:
            return ABDesign.yellow
        case .failure:
            return ABDesign.red
        }
    }

}
