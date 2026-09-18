import SwiftUI

/// CalDAV-owned settings UI for calendar automation and autopilot.
struct CalDAVSettingsView: View {
    @ObservedObject var viewModel: DashboardViewModel
    private let compactColumns = [
        GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .topLeading),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            connectionFields
            Divider()
            autopilotFields
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        WorkspaceSettingsSectionHeader(
            title: String(localized: "CalDAV calendar"),
            isOn: $viewModel.calDAVEnabled
        )
    }

    private var connectionFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            if showsRussianYandexCalendarHelp {
                yandexCalendarHelpLink
            }

            labeledField(
                String(localized: "CalDAV URL"),
                help: String(localized: "Server address for your calendar account. Use the CalDAV endpoint from your calendar provider, not a normal web calendar page.")
            ) {
                TextField("https://calendar.example.com", text: $viewModel.caldavURL)
                    .font(ABTypography.field)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.regular)
            }

            LazyVGrid(columns: compactColumns, alignment: .leading, spacing: 16) {
                labeledField(
                    String(localized: "Username"),
                    help: String(localized: "Usually your calendar account email or provider-specific CalDAV username.")
                ) {
                    TextField("name@example.com", text: $viewModel.caldavUsername)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                }
                labeledField(
                    String(localized: "Password"),
                    help: String(localized: "Use an app password if your provider supports it. The value is stored through the app secret store.")
                ) {
                    SecureField("", text: $viewModel.caldavPassword)
                        .font(ABTypography.field)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.regular)
                }
            }

            VStack(alignment: .leading, spacing: 16) {
                labeledField(
                    String(localized: "Connection"),
                    help: String(localized: "Checks credentials and loads available calendars. Select a calendar after a successful check.")
                ) {
                    Button {
                        viewModel.loadCalendars()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "checkmark.circle")
                            Text(
                                viewModel.isLoadingCalendars
                                    ? String(localized: "Checking…")
                                    : String(localized: "Check")
                            )
                            if !viewModel.calendarSettingsMessageIsError,
                               viewModel.calendarSettingsMessage != nil,
                               !viewModel.discoveredCalendars.isEmpty {
                                Divider()
                                    .frame(height: 18)
                                Text(
                                    String(
                                        format: String(localized: "Found calendars: %d"),
                                        viewModel.discoveredCalendars.count
                                    )
                                )
                                .foregroundStyle(ABDesign.green)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                Text(verbatim: "→")
                                    .font(ABTypography.bodyMedium)
                                    .foregroundStyle(ABDesign.green)
                            }
                        }
                        .frame(minHeight: 26)
                    }
                    .buttonStyle(WorkspaceButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .disabled(
                        !viewModel.calendarConnectionFieldsReady ||
                            viewModel.isTestingCalendarSettings ||
                            viewModel.isLoadingCalendars
                    )
                }

                labeledField(
                    String(localized: "Calendar"),
                    help: String(localized: "The calendar AnyBrief watches for scheduled meeting automation.")
                ) {
                    Menu {
                        Button(String(localized: "Select calendar")) {
                            viewModel.calDAVCalendarID = ""
                        }
                        if !viewModel.calDAVCalendarID.isEmpty,
                           !viewModel.discoveredCalendars.contains(where: { $0.id == viewModel.calDAVCalendarID }) {
                            Button(viewModel.calDAVCalendarID) {
                                viewModel.calDAVCalendarID = viewModel.calDAVCalendarID
                            }
                        }
                        ForEach(viewModel.discoveredCalendars) { calendar in
                            Button("\(calendar.displayName) (\(calendar.id))") {
                                viewModel.selectCalendar(calendar)
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(selectedCalendarLabel())
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.down")
                                .font(ABTypography.caption)
                        }
                        .font(ABTypography.field)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color(nsColor: .controlBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(ABDesign.badgeBackground, lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .disabled(!viewModel.calendarConnectionVerified || viewModel.discoveredCalendars.isEmpty)
                }
                .frame(maxWidth: .infinity)
            }

            if let message = viewModel.calendarSettingsMessage,
               viewModel.calendarSettingsMessageIsError {
                Text(message)
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let setupMessage = viewModel.calendarSetupMessage {
                Text(setupMessage)
                    .font(ABTypography.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!viewModel.calDAVEnabled)
        .opacity(viewModel.calDAVEnabled ? 1 : 0.55)
    }

    private var yandexCalendarHelpLink: some View {
        Link(destination: Self.yandexCalendarHelpURL) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.circle")
                    .foregroundStyle(ABDesign.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "How to connect Yandex Calendar"))
                        .font(ABTypography.bodyMedium)
                        .foregroundStyle(ABDesign.primaryText)
                    Text(String(localized: "CalDAV URL, app password, and calendar selection"))
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: "arrow.up.right")
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(ABDesign.accent.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(ABDesign.accent.opacity(0.18), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var autopilotFields: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(String(localized: "Calendar Autopilot Settings"))
                .font(ABTypography.itemTitle)
                .foregroundStyle(ABDesign.primaryText)

            WorkspaceSettingsSectionHeader(
                title: String(localized: "Enable autopilot for scheduled calls"),
                isOn: $viewModel.calendarAutopilotEnabled
            )

            VStack(alignment: .leading, spacing: 16) {
                settingsToggleRow(
                    String(localized: "Do not record microphone audio on auto-start"),
                    help: String(localized: "Autopilot will start with microphone paused. System audio is still recorded; you can resume the microphone manually during recording."),
                    isOn: $viewModel.calendarAutopilotMuteMicrophone
                )

                labeledField(
                    String(localized: "Record events"),
                    help: String(localized: "Filters which calendar events are eligible for autopilot. The default avoids ordinary solo calendar blocks.")
                ) {
                    Picker("", selection: $viewModel.calendarAutopilotFilter) {
                        Text(String(localized: "Meeting URL or more than 1 participant"))
                            .tag("meeting_url_or_multiparticipant")
                        Text(String(localized: "More than 1 participant")).tag("multiparticipant")
                        Text(String(localized: "Meeting URL only")).tag("meeting_url")
                        Text(String(localized: "All events")).tag("all")
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                labeledField(
                    String(localized: "Check every"),
                    help: String(localized: "How often AnyBrief refreshes the calendar schedule. Short intervals react faster but do more background work.")
                ) {
                    Picker("", selection: $viewModel.calendarAutopilotPollIntervalSec) {
                        Text(String(localized: "10 seconds")).tag(10)
                        Text(String(localized: "30 seconds")).tag(30)
                        Text(String(localized: "1 minute")).tag(60)
                        Text(String(localized: "5 minutes")).tag(300)
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }
            }
            .disabled(!viewModel.calendarAutopilotEnabled)
            .opacity(viewModel.calendarAutopilotEnabled ? 1 : 0.55)
        }
        .disabled(!viewModel.calDAVEnabled || !viewModel.calendarConnectionVerified || !viewModel.calendarSelectionReady)
        .opacity(viewModel.calDAVEnabled && viewModel.calendarConnectionVerified && viewModel.calendarSelectionReady ? 1 : 0.55)
    }

    private func selectedCalendarLabel() -> String {
        if viewModel.calDAVCalendarID.isEmpty {
            return String(localized: "Select calendar")
        }
        if let calendar = viewModel.discoveredCalendars.first(where: { $0.id == viewModel.calDAVCalendarID }) {
            return "\(calendar.displayName) (\(calendar.id))"
        }
        return viewModel.calDAVCalendarID
    }

    private var showsRussianYandexCalendarHelp: Bool {
        LanguagePreferences.effectiveLanguageCode(for: viewModel.languageSelection) == "ru"
    }

    private static let yandexCalendarHelpURL = URL(string: "https://anybrief.ru/help/yandex-calendar.html")!

    private func labeledField<Content: View>(
        _ label: String,
        help: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        WorkspaceFormField(title: label, help: help, fillWidth: true, content: content)
    }

    private func settingsToggleRow(_ title: String, help: String? = nil, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 5) {
                Text(title)
                    .font(ABTypography.bodyMedium)
                    .foregroundStyle(ABDesign.primaryText)
                if let help {
                    HelpTooltipIcon(text: help)
                }
            }
        }
        .toggleStyle(.checkbox)
    }
}
