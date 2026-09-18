
import AppKit
import SwiftUI

struct AutopilotDayScheduleView: View {
    let events: [DashboardViewModel.AutopilotScheduleEvent]
    let onSetAutopilotEnabled: (Bool, DashboardViewModel.AutopilotScheduleEvent) -> Void
    var onStartRecording: ((DashboardViewModel.AutopilotScheduleEvent) -> Void)? = nil
    var canStartRecording: (DashboardViewModel.AutopilotScheduleEvent) -> Bool = { _ in false }
    var recordingError: String? = nil
    var scheduleError: String? = nil
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private static let scheduleRowHeight: CGFloat = 54
    private static let scheduleRowSpacing: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.dayFormatter.string(from: now))
                    .font(ABTypography.pageTitle)
                    .foregroundStyle(ABDesign.primaryText)
                Text(Self.weekdayFormatter.string(from: now))
                    .font(ABTypography.body)
                    .foregroundStyle(ABDesign.secondaryText)
            }

            if let scheduleError {
                Label(scheduleError, systemImage: "exclamationmark.triangle")
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.red)
            }

            if let recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle")
                    .font(ABTypography.caption).foregroundStyle(ABDesign.red)
            }

            if todayEvents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "calendar")
                        .font(ABTypography.iconLarge)
                        .foregroundStyle(ABDesign.secondaryText)
                    Text("No calendar events today.", comment: "Empty Autopilot day schedule message")
                        .font(ABTypography.body)
                        .foregroundStyle(ABDesign.secondaryText)
                }
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: Self.scheduleRowSpacing) {
                        ForEach(todayEvents) { event in
                            scheduleRow(event)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.automatic)
                .frame(
                    maxWidth: .infinity,
                    minHeight: scheduleListMinHeight,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .layoutPriority(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onReceive(timer) { date in
            now = date
        }
    }

    private func scheduleRow(_ event: DashboardViewModel.AutopilotScheduleEvent) -> some View {
        let isCurrent = now >= event.startAt && now <= event.endAt
        let isPast = now > event.endAt
        let accentColor = isCurrent ? ABDesign.accent : (isPast ? ABDesign.secondaryText.opacity(0.45) : Color(red: 0.40, green: 0.55, blue: 0.70))
        let backgroundColor = isCurrent
            ? ABDesign.accent.opacity(0.10)
            : Color.clear

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                Text(Self.timeFormatter.string(from: event.startAt))
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(isPast ? ABDesign.secondaryText : ABDesign.primaryText)
                Text(Self.timeFormatter.string(from: event.endAt))
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
            }
            .frame(width: 54, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(accentColor)
                .frame(width: 3, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(event.title)
                        .font(ABTypography.bodySemibold)
                        .foregroundStyle(isPast ? ABDesign.secondaryText : ABDesign.primaryText)
                        .lineLimit(2)
                    if !event.autopilotEnabled {
                        Text("Skipped", comment: "Calendar event excluded from Autopilot badge")
                            .font(ABTypography.captionSemibold)
                            .foregroundStyle(ABDesign.secondaryText)
                    }
                }

                Text(Self.participantCountText(event.participantCount))
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 6) {
                Toggle(
                    String(localized: "Autopilot"),
                    isOn: Binding(
                        get: { event.autopilotEnabled },
                        set: { onSetAutopilotEnabled($0, event) }
                    )
                )
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(event.isRecurring
                    ? String(localized: "Enable or disable Autopilot for the entire recurring series")
                    : String(localized: "Enable or disable Autopilot for this meeting"))

                HStack(spacing: 8) {
                    if let onStartRecording {
                        Button { onStartRecording(event) } label: {
                            Label("Start recording", systemImage: "record.circle")
                                .font(ABTypography.captionSemibold)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        .disabled(!canStartRecording(event))
                        .accessibilityIdentifier("calendar.record.\(event.id)")
                    }
                    if let meetingURL = event.meetingURL {
                        Button { NSWorkspace.shared.open(meetingURL) } label: {
                            Text("Join", comment: "Join meeting button in Autopilot day schedule")
                                .font(ABTypography.captionSemibold)
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .fixedSize()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(minHeight: Self.scheduleRowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(backgroundColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isCurrent ? ABDesign.accent.opacity(0.18) : ABDesign.hairline, lineWidth: 1)
                )
        )
    }

    private var todayEvents: [DashboardViewModel.AutopilotScheduleEvent] {
        events
            .filter { Calendar.current.isDate($0.startAt, inSameDayAs: now) || Calendar.current.isDate($0.endAt, inSameDayAs: now) }
            .sorted { $0.startAt < $1.startAt }
    }

    private var scheduleListMinHeight: CGFloat {
        let rows = CGFloat(todayEvents.count)
        let gaps = CGFloat(max(todayEvents.count - 1, 0))
        return min(rows * Self.scheduleRowHeight + gaps * Self.scheduleRowSpacing + 2, 340)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static func participantCountText(_ count: Int) -> String {
        let isRussian = Locale.preferredLanguages.first?.hasPrefix("ru") == true
        let mod10 = count % 10
        let mod100 = count % 100
        let format: String
        if isRussian, mod10 == 1, mod100 != 11 {
            format = String(localized: "participantCount.one")
        } else if isRussian, (2...4).contains(mod10), !(12...14).contains(mod100) {
            format = String(localized: "participantCount.few")
        } else if count == 1 {
            format = String(localized: "participantCount.one")
        } else {
            format = String(localized: "participantCount.many")
        }
        return String(format: format, count)
    }
}
