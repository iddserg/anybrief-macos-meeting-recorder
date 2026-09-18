import SwiftUI

extension DashboardView {
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(nsImage: NSImage(named: "AnyBriefAppIcon") ?? NSImage())
                    .resizable().scaledToFit().frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text("AnyBrief")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(ABDesign.primaryText)
            }
            .frame(height: 32, alignment: .leading)
            .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 16)
            .accessibilityElement(children: .combine)
            VStack(spacing: WorkspaceDesign.listRowSpacing) {
                sidebarItem(.meetings)
                sidebarItem(.autopilot)
                sidebarItem(.postProcessing)
            }.padding(.horizontal, 10)
            if viewModel.recordingActivity != nil || !viewModel.processingActivities.isEmpty {
                Divider().padding(.vertical, 16).padding(.horizontal, 18)
                VStack(spacing: WorkspaceDesign.listRowSpacing) {
                    if viewModel.recordingActivity != nil { sidebarItem(.status) }
                    if !viewModel.processingActivities.isEmpty { sidebarItem(.processing) }
                }.padding(.horizontal, 10)
            }
            Spacer(minLength: 24)
            VStack(spacing: 4) {
                sidebarItem(.notifications)
                sidebarItem(.settings)
            }.padding(.horizontal, 10)
            HStack(spacing: 8) {
                Text(Self.appVersionText).fixedSize()
                Spacer(minLength: 0)
                Menu {
                    Button("Readiness") { selectPane(.setup) }
                        .accessibilityIdentifier("sidebar.setup")
                    Button("Logs") { selectPane(.logs) }
                    Button("Permissions") { selectPane(.permissions) }
                    Button(viewModel.isCheckingForUpdates ? String(localized: "Checking for updates...") : String(localized: "Check for updates")) { viewModel.checkForUpdates() }
                        .disabled(viewModel.isCheckingForUpdates)
                    if viewModel.availableUpdate != nil {
                        Button("Download update") { viewModel.openAvailableUpdateDownload() }
                    }
                    Divider()
                    Link(Self.websiteLabel, destination: Self.websiteURL)
                        .accessibilityIdentifier("sidebar.website")
                    Link("Feedback…", destination: Self.websiteURL.appendingPathComponent("feedback.html"))
                        .accessibilityIdentifier("sidebar.feedback")
                } label: {
                    Text("Diagnostics").lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.mini)
                .fixedSize()
                .accessibilityIdentifier("sidebar.diagnostics")
            }
            .font(ABTypography.caption)
            .foregroundStyle(ABDesign.secondaryText)
            .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 18)
        }
        .frame(width: WorkspaceDesign.sidebarWidth)
        .background(WorkspaceDesign.secondarySurface)
        .overlay(alignment: .trailing) { Rectangle().fill(ABDesign.hairline).frame(width: 1) }
    }

    func sidebarItem(_ pane: Pane) -> some View {
        Button { selectPane(pane) } label: {
            HStack(spacing: 8) {
                Image(systemName: pane.icon).frame(width: 18)
                Text(pane.title).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if pane == .processing, viewModel.processingActivities.count > 1 {
                    Text("\(viewModel.processingActivities.count)").font(ABTypography.captionMedium)
                }
                if pane == .notifications, selectedPane != .notifications, notificationStore.unreadCount > 0 {
                    Text("\(notificationStore.unreadCount)").font(ABTypography.captionMedium)
                        .foregroundStyle(ABDesign.accent)
                }
            }
            .font(WorkspaceDesign.navigationFont).padding(.horizontal, 10).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(selectedPane == pane ? ABDesign.accent : ABDesign.primaryText)
            .background(selectedPane == pane ? ABDesign.selectedSidebarBackground : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 7)).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityIdentifier("sidebar.pane.\(pane.rawValue)")
    }

    var visiblePanes: [Pane] { [.meetings, .autopilot, .postProcessing, .notifications, .settings, .setup, .logs, .permissions] }

    static var appVersionText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        return "v\(version)"
    }

    static var isRussian: Bool {
        let lang = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first
            ?? Locale.current.language.languageCode?.identifier
            ?? "en"
        return lang.hasPrefix("ru")
    }

    static var websiteURL: URL {
        URL(string: isRussian ? "https://anybrief.ru" : "https://anybrief.pro")!
    }

    static var websiteLabel: String {
        isRussian ? "anybrief.ru" : "anybrief.pro"
    }
}
