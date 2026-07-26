
import SwiftUI

extension DashboardView {
    var notificationsSection: some View {
        sectionCard(title: String(localized: "Notifications")) {
            let notifications = notificationStore.notifications
            if notifications.isEmpty {
                emptyState(
                    systemImage: "bell.slash",
                    title: String(localized: "No notifications"),
                    message: String(localized: "New in-app alerts about recording, summary status, and important errors will appear here."),
                    minHeight: 180
                )
            } else {
                VStack(spacing: 0) {
                    ForEach(notifications) { notification in
                        notificationRow(notification)

                        if notification.id != notifications.last?.id {
                            Divider()
                        }
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(ABDesign.hairline, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    func notificationRow(_ notification: InAppNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            permissionIcon(
                systemImage: notificationIcon(for: notification.category),
                foreground: ABDesign.accent,
                background: ABDesign.accent.opacity(0.10),
                size: 28
            )

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                        Text(notification.title)
                            .font(ABTypography.bodySemibold)
                        .foregroundStyle(ABDesign.primaryText)
                        .lineLimit(1)
                    Text(Self.timestampFormatter.string(from: notification.createdAt))
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                        .lineLimit(1)
                }

                Text(notification.body)
                    .font(ABTypography.caption)
                    .foregroundStyle(ABDesign.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ABDesign.cardBackground)
    }

    func notificationIcon(for category: String) -> String {
        switch category {
        case NotificationService.Category.recordingStarted.rawValue:
            return "record.circle"
        case NotificationService.Category.recordingStopped.rawValue:
            return "stop.circle"
        case NotificationService.Category.preEnd.rawValue:
            return "timer"
        case NotificationService.Category.summaryReady.rawValue:
            return "doc.text"
        case NotificationService.Category.recordingInterrupted.rawValue, "recording_error":
            return "exclamationmark.octagon"
        case NotificationService.Category.autoSkipped.rawValue:
            return "person.crop.circle.badge.exclamationmark"
        case "permissions_error":
            return "lock.trianglebadge.exclamationmark"
        default:
            return "bell"
        }
    }

}
