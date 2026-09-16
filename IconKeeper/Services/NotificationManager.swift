//
//  NotificationManager.swift
//  IconKeeper
//
//  Thin wrapper around UserNotifications for status alerts (e.g. "reapplied
//  your icon after an update").
//
//  Notifications are batched: events of the same kind arriving within a short
//  window become one banner. After a mass update — or a launch that finds a
//  hundred items reset overnight — that's one "Restored 100 icons", not a
//  hundred banners.
//

import UserNotifications

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    var isEnabled = true
    /// How long to wait for more events of the same kind before posting.
    var batchWindow: Duration = .seconds(2)

    private var pending: [NotificationEvent: [String]] = [:]
    private var flushTask: Task<Void, Never>?

    private init() {}

    /// Asks the user for notification permission (no-op if already decided).
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Records an event about a named item; posted after the batch window.
    func post(_ event: NotificationEvent, itemName: String) {
        guard isEnabled else { return }
        pending[event, default: []].append(itemName)
        guard flushTask == nil else { return }
        flushTask = Task { [weak self, batchWindow] in
            try? await Task.sleep(for: batchWindow)
            self?.flush()
        }
    }

    private func flush() {
        flushTask = nil
        let batches = pending
        pending = [:]
        guard isEnabled else { return }
        for (event, names) in batches {
            let (title, body) = Self.content(for: event, names: names)
            deliver(title: title, body: body)
        }
    }

    /// The banner text for a batch. Internal for testing.
    static func content(for event: NotificationEvent, names: [String]) -> (title: String, body: String) {
        let unique = names.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let count = unique.count
        let list = unique.prefix(3).joined(separator: ", ") + (count > 3 ? " and \(count - 3) more" : "")
        switch event {
        case .iconRestored:
            return count == 1
                ? ("Icon Restored", "\(list)'s icon was reset — IconKeeper put yours back.")
                : ("\(count) Icons Restored", "IconKeeper put your icons back on \(list).")
        case .externalChange:
            return count == 1
                ? ("\(list)'s icon was changed", "IconKeeper left it alone. Open IconKeeper to keep your icon or adopt the new one.")
                : ("\(count) icons were changed", "IconKeeper left \(list) alone. Open IconKeeper to keep your icons or adopt the new ones.")
        case .repeatedRemoval:
            return count == 1
                ? ("Keep removing \(list)'s icon?", "IconKeeper keeps restoring it. Open IconKeeper and choose Restore Original to remove it and pause protection.")
                : ("Keep removing these icons?", "IconKeeper keeps restoring \(list). Choose Restore Original in IconKeeper to remove them and pause protection.")
        }
    }

    private func deliver(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
