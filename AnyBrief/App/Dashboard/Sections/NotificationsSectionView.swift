
import SwiftUI

extension DashboardView {
    var notificationsSection: some View {
        sectionCard() {
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

            }
        }
    }

    func notificationRow(_ notification: InAppNotificationItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            permissionIcon(
                systemImage: notificationIcon(for: notification.category),
                foreground: notification.isRead ? ABDesign.secondaryText : ABDesign.accent,
                background: notification.isRead ? ABDesign.subtleBackground : ABDesign.accent.opacity(0.10),
                size: 28
            )

            VStack(alignment: .leading, spacing: 4) {
                VStack(alignment: .leading, spacing: 4) {
                        Text(notification.title)
                            .font(ABTypography.bodySemibold)
                        .foregroundStyle(notification.isRead ? ABDesign.secondaryText : ABDesign.primaryText)
                        .lineLimit(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.timestampFormatter.string(from: notification.createdAt))
                        .font(ABTypography.caption)
                        .foregroundStyle(ABDesign.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(notification.body)
                    .font(ABTypography.caption)
                    .foregroundStyle(notification.isRead ? ABDesign.disabledText : ABDesign.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if notification.category == NotificationService.Category.updateAvailable.rawValue,
               viewModel.availableUpdate != nil {
                Button("Download update", action: viewModel.openAvailableUpdateDownload)
                    .buttonStyle(WorkspaceButtonStyle())
            }

            if notification.category == NotificationService.Category.recordingSourceUnavailable.rawValue,
               viewModel.effectiveAppState == .recording {
                Button("Stop Recording", action: viewModel.stopRecording)
                    .buttonStyle(WorkspaceButtonStyle(prominent: true, destructive: true))
                    .disabled(viewModel.isStoppingRecording)
            }

            Spacer(minLength: 10)
        }
        .padding(.horizontal, 0)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ABDesign.cardBackground)
        .opacity(notification.isRead ? 0.72 : 1)
    }

    func notificationIcon(for category: String) -> String {
        switch category {
        case NotificationService.Category.updateAvailable.rawValue, NotificationService.Category.updateCheck.rawValue:
            return "arrow.down.circle"
        case NotificationService.Category.recordingStarted.rawValue:
            return "record.circle"
        case NotificationService.Category.recordingStopped.rawValue:
            return "stop.circle"
        case NotificationService.Category.preEnd.rawValue:
            return "timer"
        case NotificationService.Category.summaryReady.rawValue:
            return "doc.text"
        case NotificationService.Category.recordingInterrupted.rawValue,
             NotificationService.Category.recordingSourceUnavailable.rawValue,
             "recording_error":
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
