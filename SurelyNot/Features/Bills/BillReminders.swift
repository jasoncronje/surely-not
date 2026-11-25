import Foundation
import UserNotifications

/// A notification on the morning before each bill is due.
///
/// Reminders are local to this phone. They are worked out again every time
/// bills load, so a bill that has been paid loses its reminder, and next
/// month's are already in place if the app is not opened for a while.
enum BillReminders {
    nonisolated struct Reminder: Equatable, Sendable {
        let id: String
        let title: String
        let body: String
        let fireDate: Date
    }

    nonisolated static let enabledKey = "billRemindersEnabled"
    /// Every reminder's identifier starts with this, so they can be told
    /// apart from any other notification the app may send.
    nonisolated static let prefix = "bill-"
    /// The hour of the morning, the day before, that a reminder arrives.
    nonisolated static let hour = 9

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    /// The reminders to have waiting: this month's bills that are still
    /// unpaid, and every bill's turn next month.
    nonisolated static func plan(
        statuses: [BillStatus],
        now: Date = .now,
        calendar: Calendar = .current
    ) -> [Reminder] {
        var result: [Reminder] = []
        let nextMonth = calendar.date(byAdding: .month, value: 1, to: now)
        for status in statuses where !status.bill.isIncome {
            var dueDates: [Date] = []
            if !status.isPaid, let due = Day.date(status.dueDate) {
                dueDates.append(due)
            }
            if let nextMonth,
               let due = BillSchedule.dueDate(day: status.bill.expectedDayOfMonth, inMonthOf: nextMonth, calendar: calendar) {
                dueDates.append(due)
            }
            for due in dueDates {
                guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: due),
                      let fire = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: dayBefore),
                      fire > now else { continue }
                let bill = status.bill
                let amount = MoneyFormat.string(cents: abs(bill.amountCents), currency: bill.currency)
                result.append(Reminder(
                    id: "\(prefix)\(bill.id)-\(WidgetSnapshot.monthKey(due, calendar: calendar))",
                    title: bill.autopay == true ? "\(bill.title) comes out tomorrow" : "\(bill.title) is due tomorrow",
                    body: bill.autopay == true ? "\(amount), paid automatically." : "\(amount). Open Surely Not to see your bills.",
                    fireDate: fire
                ))
            }
        }
        return result.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
    }

    /// Replaces the waiting reminders with the ones these bills call for.
    /// Does nothing while reminders are off or notifications are not allowed.
    static func sync(statuses: [BillStatus]) async {
        guard isEnabled else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .authorized else { return }
        await removeAll()
        let calendar = Calendar.current
        for reminder in plan(statuses: statuses) {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
            try? await center.add(UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger))
        }
    }

    /// Asks for permission and turns reminders on. Returns false if the
    /// person, or a setting on the phone, says no.
    static func enable() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: enabledKey)
        return granted
    }

    static func disable() async {
        UserDefaults.standard.set(false, forKey: enabledKey)
        await removeAll()
    }

    /// How many reminders are waiting to be delivered.
    static func waitingCount() async -> Int {
        await UNUserNotificationCenter.current().pendingNotificationRequests()
            .count { $0.identifier.hasPrefix(prefix) }
    }

    static func removeAll() async {
        let center = UNUserNotificationCenter.current()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
    }
}
