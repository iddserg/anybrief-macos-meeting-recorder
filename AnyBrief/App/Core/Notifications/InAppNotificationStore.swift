import Combine
import Foundation

/// Stores in-app notification state for the dashboard notification center.
struct InAppNotificationItem: Identifiable, Equatable {
    let id: UUID
    let category: String
    let title: String
    let body: String
    let createdAt: Date
    let isRead: Bool

    init(
        id: UUID = UUID(),
        category: String,
        title: String,
        body: String,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.isRead = isRead
    }
}

final class InAppNotificationStore: ObservableObject {
    @Published private(set) var notifications: [InAppNotificationItem] = []

    var unreadNotifications: [InAppNotificationItem] {
        notifications.filter { !$0.isRead }
    }

    var unreadCount: Int {
        unreadNotifications.count
    }

    @discardableResult
    func add(category: String, title: String, body: String) -> InAppNotificationItem {
        let item = InAppNotificationItem(category: category, title: title, body: body)
        notifications.insert(item, at: 0)
        return item
    }

    @discardableResult
    func addIfUnreadDuplicateIsMissing(category: String, title: String, body: String) -> InAppNotificationItem? {
        if notifications.contains(where: {
            !$0.isRead && $0.category == category && $0.title == title && $0.body == body
        }) {
            return nil
        }

        return add(category: category, title: title, body: body)
    }

    func markAsRead(id: UUID) {
        guard let index = notifications.firstIndex(where: { $0.id == id }) else {
            return
        }
        let notification = notifications[index]
        notifications[index] = InAppNotificationItem(
            id: notification.id,
            category: notification.category,
            title: notification.title,
            body: notification.body,
            createdAt: notification.createdAt,
            isRead: true
        )
    }

    func markAllAsRead() {
        notifications = notifications.map { notification in
            guard !notification.isRead else {
                return notification
            }

            return InAppNotificationItem(
                id: notification.id,
                category: notification.category,
                title: notification.title,
                body: notification.body,
                createdAt: notification.createdAt,
                isRead: true
            )
        }
    }

    func removeReadNotifications() {
        notifications.removeAll { $0.isRead }
    }
}
