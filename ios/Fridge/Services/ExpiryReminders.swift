import Foundation
import Observation
import UIKit
import UserNotifications

/// F5.1: at most one local notification a day listing what's about to expire. No server:
/// digests for the next 7 days are scheduled ahead and rebuilt whenever the pantry changes,
/// the app comes to the foreground, or the daily background refresh runs.
@MainActor @Observable
final class ExpiryReminders: NSObject {
    static let shared = ExpiryReminders()

    static let backgroundTaskId = "com.barryxyz.fridge.refresh"
    private static let idPrefix = "expiry-digest-"
    private static let daysAhead = 7

    // MARK: Settings (on this device; reminders belong to a device, not the account)

    private let defaults = UserDefaults.standard
    var enabled: Bool { didSet { defaults.set(enabled, forKey: "reminders.enabled"); settingsChanged() } }
    var hour: Int { didSet { defaults.set(hour, forKey: "reminders.hour"); settingsChanged() } }
    var minute: Int { didSet { defaults.set(minute, forKey: "reminders.minute"); settingsChanged() } }
    /// "Warn me" 1–3 days before.
    var leadDays: Int { didSet { defaults.set(leadDays, forKey: "reminders.lead"); settingsChanged() } }
    /// The in-context question was shown (after the first pantry save); never asked again.
    private(set) var asked: Bool { didSet { defaults.set(asked, forKey: "reminders.asked") } }

    /// Set after the first pantry save: the app shows "Get a heads-up…?".
    var offerPrompt = false
    /// Increments when a reminder is tapped: the Pantry tab opens on All, Use these first expanded.
    private(set) var openPantryRequest = 0

    private override init() {
        enabled = defaults.bool(forKey: "reminders.enabled")
        hour = defaults.object(forKey: "reminders.hour") as? Int ?? 9
        minute = defaults.object(forKey: "reminders.minute") as? Int ?? 0
        leadDays = defaults.object(forKey: "reminders.lead") as? Int ?? 2
        asked = defaults.bool(forKey: "reminders.asked")
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    var time: Date {
        get { Calendar.current.date(from: DateComponents(hour: hour, minute: minute)) ?? .now }
        set {
            let c = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            if c.hour != hour { hour = c.hour ?? 9 }
            if c.minute != minute { minute = c.minute ?? 0 }
        }
    }

    // MARK: Permission

    /// After any pantry save: the first time, offer reminders (with an explanation first).
    func pantrySaved() {
        pantryChanged()
        guard !asked else { return }
        asked = true
        Task {
            try? await Task.sleep(for: .seconds(1))     // let the add / review sheet close first
            offerPrompt = true
        }
    }

    /// Asks iOS; turns reminders on when allowed. Returns whether they're on.
    @discardableResult
    func turnOn() async -> Bool {
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        enabled = granted
        return granted
    }

    /// Notifications allowed for the app in iOS Settings?
    func systemAllows() async -> Bool {
        let s = await UNUserNotificationCenter.current().notificationSettings()
        return s.authorizationStatus == .authorized || s.authorizationStatus == .provisional
    }

    // MARK: Scheduling

    private var pending: Task<Void, Never>?

    /// The pantry changed (or the app came back): rebuild the digests from fresh data, once
    /// even if several changes come in at the same time.
    func pantryChanged() {
        OfflineStore.shared.markStale()          // the server may have changed rows (F3.6)
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            _ = try? await PantryAPI.activeItems()       // reschedules through `update`
        }
    }

    private func settingsChanged() {
        if enabled { pantryChanged() } else { Task { await Self.cancelAll() } }
    }

    /// Cancels and reschedules the next 7 days of digests from these (active) items.
    func update(with items: [PantryItem], now: Date = .now) async {
        await Self.cancelAll()
        guard enabled, await systemAllows() else { return }
        let center = UNUserNotificationCenter.current()
        for d in ExpiryDigest.plan(items: items, now: now, days: Self.daysAhead, leadDays: leadDays,
                                   hour: hour, minute: minute) {
            let content = UNMutableNotificationContent()
            content.title = d.title
            content.body = d.body
            content.sound = .default
            let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d.fireDate)
            let id = Self.idPrefix + d.fireDate.formatted(.iso8601.year().month().day())
            try? await center.add(UNNotificationRequest(identifier: id, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)))
        }
    }

    static func cancelAll() async {
        let center = UNUserNotificationCenter.current()
        let ids = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    /// Settings → "Send a test reminder": today's digest in 5 seconds.
    func sendTest() async -> String? {
        var allowed = await systemAllows()
        if !allowed { allowed = await turnOn() }
        guard allowed else { return "Notifications are off for Fridge in iOS Settings." }
        guard let items = try? await PantryAPI.activeItems() else { return "Couldn't load your pantry." }
        let content = UNMutableNotificationContent()
        if let d = ExpiryDigest.digest(items: items, day: Calendar.current.startOfDay(for: .now), leadDays: leadDays) {
            content.title = d.title
            content.body = d.body
        } else {
            content.title = "Nothing expires soon"
            content.body = "No reminder would be sent today: nothing expires in the next \(leadDays) day\(leadDays == 1 ? "" : "s")."
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: "expiry-test", content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        try? await UNUserNotificationCenter.current().add(request)
        return nil
    }
}

extension ExpiryReminders: UNUserNotificationCenterDelegate {
    /// Show reminders while the app is open too.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification)
        async -> UNNotificationPresentationOptions { [.banner, .sound] }

    /// Tap: open the pantry.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { openPantryRequest += 1 }
    }
}

/// The digest text and days, separate from UserNotifications so it can be unit tested.
enum ExpiryDigest {
    struct Digest: Equatable {
        let fireDate: Date
        let title: String
        let body: String
    }

    /// One digest per day (from today if the time hasn't passed) that has something to say.
    static func plan(items: [PantryItem], now: Date, days: Int, leadDays: Int, hour: Int, minute: Int,
                     calendar: Calendar = .current) -> [Digest] {
        let today = calendar.startOfDay(for: now)
        return (0..<days).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let fire = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                  fire > now,
                  let d = digest(items: items, day: day, leadDays: leadDays, calendar: calendar) else { return nil }
            return Digest(fireDate: fire, title: d.title, body: d.body)
        }
    }

    /// What the reminder on `day` says: items expiring that day up to `leadDays - 1` days later,
    /// plus items that expired the day before (one mention). Staples aren't included.
    static func digest(items: [PantryItem], day: Date, leadDays: Int,
                       calendar: Calendar = .current) -> (title: String, body: String)? {
        let start = calendar.startOfDay(for: day)
        let entries: [(name: String, amount: String, offset: Int, date: Date)] = items.compactMap { item in
            guard item.status == .active, !item.isStaple, let exp = item.expiresAt,
                  let offset = calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: exp)).day,
                  offset == -1 || (0..<max(1, leadDays)).contains(offset) else { return nil }
            let amount = item.quantity == nil ? "" : MacroFormat.amount(item.quantity, unit: item.unit == "each" ? nil : item.unit)
            return (item.displayName, amount, offset, exp)
        }
        .sorted { ($0.offset, $0.date, $0.name) < ($1.offset, $1.date, $1.name) }
        guard !entries.isEmpty else { return nil }

        func when(_ offset: Int) -> String {
            switch offset {
            case -1: "expired yesterday"
            case 0: "today"
            case 1: "tomorrow"
            default: "in \(offset) days"
            }
        }
        func named(_ e: (name: String, amount: String, offset: Int, date: Date)) -> String {
            e.amount.isEmpty ? e.name : "\(e.name) (\(e.amount))"
        }

        // The title says when; the body lists the items with how much is left. When the items
        // expire on different days, the body groups them by day ("Today: … · Tomorrow: …").
        let offsets = entries.map(\.offset).reduce(into: [Int]()) { if !$0.contains($1) { $0.append($1) } }
        let shown = Array(entries.prefix(3))
        var body: String
        if offsets.count == 1 {
            body = shown.map(named).joined(separator: ", ")
        } else {
            body = offsets.compactMap { o -> String? in
                let group = shown.filter { $0.offset == o }
                guard !group.isEmpty else { return nil }
                return "\(when(o).capitalizedFirst): " + group.map(named).joined(separator: ", ")
            }.joined(separator: " · ")
        }
        if entries.count > 3 { body += " +\(entries.count - 3) more" }

        let title: String
        if entries.count == 1 {
            let e = entries[0]
            title = e.offset == -1 ? "\(e.name.capitalizedFirst) expired yesterday" : "\(e.name.capitalizedFirst) expires \(when(e.offset))"
        } else if offsets.count == 1 {
            title = offsets[0] == -1 ? "\(entries.count) items expired yesterday" : "\(entries.count) items expire \(when(offsets[0]))"
        } else {
            title = "\(entries.count) items expire soon"
        }
        return (title, body)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
