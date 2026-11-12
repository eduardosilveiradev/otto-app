import Foundation
import UserNotifications

/// One reminder Otto set, from the server's {"type":"reminders","items":[{"id","at","text"}]} frame.
struct ReminderItem: Decodable, Sendable, Equatable {
    let id: String
    let at: String
    let text: String
}

/// What to do with a reminder set, given what's already pending. Pure, so Scripts/reminders-check.sh runs it as is.
enum ReminderPlan {
    static let prefix = "otto-reminder-"
    /// A pending one this close to firing stays even if it left the set: the server drops a reminder the
    /// moment it fires, and a clock a few seconds apart must not cancel the banner the server now leaves to us.
    static let keepWithin: TimeInterval = 60

    static func identifier(_ id: String) -> String { prefix + id }

    /// Everything still to come gets (re)scheduled, which also replaces a moved time or new text; ours that
    /// left the set are removed. Other notifications (Otto's messages, pips) are never touched.
    static func plan(_ items: [ReminderItem], pending: [String: Date], now: Date, date: (String) -> Date?)
        -> (add: [(id: String, date: Date, text: String)], remove: [String]) {
        let add = items.compactMap { i -> (id: String, date: Date, text: String)? in
            guard let d = date(i.at), d > now else { return nil }
            return (identifier(i.id), d, i.text)
        }
        let wanted = Set(add.map(\.id))
        let remove = pending.filter { $0.key.hasPrefix(prefix) && !wanted.contains($0.key) && $0.value.timeIntervalSince(now) > keepWithin }
            .map(\.key).sorted()
        return (add, remove)
    }

    /// Only what iOS really has pending for that exact time: the server stops alerting for those.
    static func acks(_ items: [ReminderItem], pending: [String: Date], date: (String) -> Date?) -> [ReminderItem] {
        items.filter { i in
            guard let want = date(i.at), let have = pending[identifier(i.id)] else { return false }
            return abs(have.timeIntervalSince(want)) < 1
        }
    }
}

/// Reminders scheduled on the phone itself, so they arrive with the Mac asleep, off or offline.
enum Reminders {
    /// Applies the set and returns the ack frame to send back, or nil when there is nothing to ack.
    static func sync(_ items: [ReminderItem]) async -> String? {
        let center = UNUserNotificationCenter.current()
        let now = Date()
        let plan = ReminderPlan.plan(items, pending: await pending(center), now: now, date: LiveBackend.date)
        center.removePendingNotificationRequests(withIdentifiers: plan.remove)
        for r in plan.add {
            let content = UNMutableNotificationContent()
            content.title = "Otto"
            content.body = r.text
            content.sound = .default
            content.categoryIdentifier = Notifier.category   // inline Reply goes to the thread like any banner's
            content.threadIdentifier = "reminder"
            content.relevanceScore = 1                        // a reminder they set: top of the summary
            content.userInfo["reminder"] = r.id
            let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: r.date)
            try? await center.add(UNNotificationRequest(identifier: r.id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        // Notifications off: scheduled or not, nothing will show, so the server must keep alerting.
        let status = await center.notificationSettings().authorizationStatus
        guard [.authorized, .provisional, .ephemeral].contains(status) else { return nil }
        let acked = ReminderPlan.acks(items, pending: await pending(center), date: LiveBackend.date)
        guard !acked.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: ["type": "reminders_ack", "items": acked.map { ["id": $0.id, "at": $0.at] }])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func pending(_ center: UNUserNotificationCenter) async -> [String: Date] {
        var out: [String: Date] = [:]
        for r in await center.pendingNotificationRequests() where r.identifier.hasPrefix(ReminderPlan.prefix) {
            if let d = (r.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate() { out[r.identifier] = d }
        }
        return out
    }
}
