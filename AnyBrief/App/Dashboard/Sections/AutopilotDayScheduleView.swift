
import AppKit
import SwiftUI

struct AutopilotDayScheduleView: View {
    let events: [DashboardViewModel.AutopilotScheduleEvent]
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private static let scheduleRowHeight: CGFloat = 54
    private static let scheduleRowSpacing: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.dayFormatter.string(from: now))
                        .font(ABTypography.pageTitle)
                        .foregroundStyle(ABDesign.primaryText)
                    Text(Self.weekdayFormatter.string(from: now))
                        .font(ABTypography.body)
                        .foregroundStyle(ABDesign.secondaryText)
                }

                Spacer()

                Label(Self.timeFormatter.string(from: now), systemImage: "clock")
                    .font(ABTypography.bodySemibold)
                    .foregroundStyle(ABDesign.primaryText)
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(
                        Capsule()
                            .fill(Color.black.opacity(0.04))
                    )
            }

            Text("All day", comment: "Calendar all-day row label")
                .font(ABTypography.captionSemibold)
                .foregroundStyle(ABDesign.secondaryText)
                .textCase(.uppercase)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(ABDesign.hairline)
                        .frame(height: 1)
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
        let isFuture = now < event.startAt
        let accentColor = isCurrent ? ABDesign.accent : (isPast ? ABDesign.secondaryText.opacity(0.45) : Color(red: 0.40, green: 0.55, blue: 0.70))
        let backgroundColor = isCurrent
            ? ABDesign.accent.opacity(0.10)
            : (isPast ? Color.black.opacity(0.025) : Color(red: 0.88, green: 0.91, blue: 0.95).opacity(0.55))

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
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isCurrent {
                        Text("Now", comment: "Current calendar event badge")
                            .font(ABTypography.captionSemibold)
                            .foregroundStyle(ABDesign.accent)
                    } else if isPast {
                        Text("Done", comment: "Past calendar event badge")
                            .font(ABTypography.captionSemibold)
                            .foregroundStyle(ABDesign.secondaryText)
                    } else if isFuture {
                        Text("Upcoming", comment: "Future calendar event badge")
                            .font(ABTypography.captionSemibold)
                            .foregroundStyle(Color(red: 0.40, green: 0.55, blue: 0.70))
                    }
                }

                HStack(spacing: 6) {
                    Text(Self.participantCountText(event.participantCount))
                    if event.hasMeetingURL {
                        Image(systemName: "link")
                    }
                }
                .font(ABTypography.caption)
                .foregroundStyle(ABDesign.secondaryText)
                .lineLimit(1)
            }

            Spacer(minLength: 0)

            if let meetingURL = event.meetingURL {
                Button {
                    NSWorkspace.shared.open(meetingURL)
                } label: {
                    Text("Join", comment: "Join meeting button in Autopilot day schedule")
                        .font(ABTypography.captionSemibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.scheduleRowHeight)
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
