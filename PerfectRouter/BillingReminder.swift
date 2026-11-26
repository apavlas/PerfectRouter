import Foundation
import UserNotifications

/// Honest billing: tell the rider before a trial turns into a charge, and
/// before a yearly plan renews. The rules are pure so they can be unit
/// tested; `ProStore` feeds them what StoreKit reports.
enum BillingReminder {
    /// What the current Pro plan does next.
    struct Renewal: Equatable, Sendable {
        var productID: String
        /// When the trial ends or the period renews.
        var expirationDate: Date
        var isTrial: Bool
        var willAutoRenew: Bool
    }

    /// The trial reminder comes this many days before the first charge.
    static let trialLeadDays = 2
    /// The yearly renewal reminder comes this many days before the charge.
    /// Monthly plans get none: Apple's receipt each month is reminder enough.
    static let yearlyRenewalLeadDays = 7

    private static let day: TimeInterval = 86_400

    static func leadDays(for renewal: Renewal) -> Int? {
        if renewal.isTrial { return trialLeadDays }
        return renewal.productID == ProAccess.yearlyProductID ? yearlyRenewalLeadDays : nil
    }

    /// Whether the in-app reminder shows now: a charge is coming, and it's
    /// within the lead time. A plan the rider already cancelled shows none.
    static func isDue(_ renewal: Renewal, now: Date) -> Bool {
        guard renewal.willAutoRenew, let lead = leadDays(for: renewal) else { return false }
        let remaining = renewal.expirationDate.timeIntervalSince(now)
        return remaining > 0 && remaining <= TimeInterval(lead) * day
    }

    /// The reminder line. `price` is nil when the App Store hasn't answered.
    static func text(for renewal: Renewal, dateText: String, price: String?) -> String {
        let period = PaywallCopy.periodNoun(renewal.productID)
        if renewal.isTrial {
            guard let price else {
                return "Your Pro trial ends \(dateText). Pro then renews automatically unless you cancel."
            }
            return "Your Pro trial ends \(dateText). After that it's \(price) a \(period) unless you cancel."
        }
        guard let price else { return "Pro renews \(dateText)." }
        return "Pro renews \(dateText) for \(price) a \(period)."
    }

    /// When the trial-ending notification fires, or nil when none is due:
    /// not a trial, already cancelled, or too close to the end to warn.
    static func trialNotificationDate(for renewal: Renewal?, now: Date) -> Date? {
        guard let renewal, renewal.isTrial, renewal.willAutoRenew else { return nil }
        let fireDate = renewal.expirationDate.addingTimeInterval(-TimeInterval(trialLeadDays) * day)
        return fireDate > now ? fireDate : nil
    }
}

/// Schedules the one "your trial ends soon" notification, replacing it
/// whenever StoreKit reports a change, and removing it once the rider
/// cancels or the trial converts.
struct BillingReminderNotifier {
    private let center = UNUserNotificationCenter.current()
    static let trialEndingID = "pro.trial-ending"

    func update(trialEnding renewal: BillingReminder.Renewal?) async {
        center.removePendingNotificationRequests(withIdentifiers: [Self.trialEndingID])
        let now = Date()
        guard let fireDate = BillingReminder.trialNotificationDate(for: renewal, now: now),
              await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your Pro trial ends in \(BillingReminder.trialLeadDays) days"
        content.body = "You'll be charged when it ends unless you cancel in Settings before then."
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: fireDate.timeIntervalSince(now), repeats: false)
        let request = UNNotificationRequest(identifier: Self.trialEndingID, content: content, trigger: trigger)
        try? await center.add(request)
    }

    /// Asks once, in context, right after the trial starts. If the rider
    /// says no, the in-app reminder row still shows.
    private func isAuthorized() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
