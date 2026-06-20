//
//  NotificationManager.swift
//  IconKeeper
//
//  Thin wrapper around UserNotifications for status alerts (e.g. "reapplied
//  your icon after an update").
//

import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    private var authorized = false
    var isEnabled = true

    private init() {}

    /// Asks the user for notification permission (no-op if already decided).
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    /// Posts an immediate banner if notifications are enabled and authorized.
    func notify(title: String, body: String) {
        guard isEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
