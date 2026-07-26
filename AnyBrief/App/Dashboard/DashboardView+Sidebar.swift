import SwiftUI

extension DashboardView {
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image("PrimaryLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 142, height: 46, alignment: .leading)
                .accessibilityLabel(Text("AnyBrief"))
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 20)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(spacing: 6) {
                ForEach(visiblePanes) { pane in
                    Button {
                        selectPane(pane)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pane.icon)
                                .font(ABTypography.bodyMedium)
                                .frame(width: 16)
                            Text(pane.title)
                                .font(ABTypography.bodySemibold)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .layoutPriority(1)
                                .padding(.trailing, pane == .notifications && notificationStore.unreadCount > 0 ? 28 : 0)
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34, alignment: .leading)
                        .contentShape(Rectangle())
                        .foregroundStyle(selectedPane == pane ? ABDesign.accent : ABDesign.primaryText)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedPane == pane ? ABDesign.selectedSidebarBackground : Color.clear)
                        )
                        .overlay(alignment: .trailing) {
                            if pane == .notifications, notificationStore.unreadCount > 0 {
                                Text("\(notificationStore.unreadCount)")
                                    .font(ABTypography.captionSemibold)
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .frame(minWidth: 22, minHeight: 22)
                                    .background(Capsule().fill(ABDesign.red))
                                    .fixedSize(horizontal: true, vertical: false)
                                    .padding(.trailing, 8)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("sidebar.pane.\(pane.rawValue)")
                }
            }
            .padding(.horizontal, 6)

            Spacer()

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(Self.appVersionText)
                        .font(ABTypography.captionMedium)
                        .foregroundStyle(ABDesign.secondaryText)
                        .lineLimit(1)

                    Button {
                        viewModel.checkForUpdates()
                    } label: {
                        Image(systemName: viewModel.isCheckingForUpdates ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                            .font(ABTypography.iconSmall)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ABDesign.secondaryText)
                    .help(Text(String(localized: "Check for updates")))
                    .disabled(viewModel.isCheckingForUpdates)
                }

                if let updateCheckMessage = viewModel.updateCheckMessage {
                    Text(updateCheckMessage)
                        .font(ABTypography.captionMedium)
                        .foregroundStyle(viewModel.updateCheckMessageIsError ? ABDesign.red : ABDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineLimit(3)
                }

                if viewModel.availableUpdate != nil {
                    Button {
                        viewModel.openAvailableUpdateDownload()
                    } label: {
                        Text("Download update")
                            .font(ABTypography.captionMedium)
                            .foregroundStyle(ABDesign.accent)
                    }
                    .buttonStyle(.plain)
                }

                Link(Self.websiteLabel, destination: Self.websiteURL)
                    .font(ABTypography.captionMedium)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)
        }
        .frame(width: 180)
        .fixedSize(horizontal: true, vertical: false)
        .background(ABDesign.chromeBackground)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(ABDesign.hairline)
                .frame(width: 0.5)
        }
    }

    var visiblePanes: [Pane] {
        Pane.allCases.filter { pane in
            switch pane {
            case .liveTranscript:
                return viewModel.liveTranscriptEnabled
            default:
                return true
            }
        }
    }

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
