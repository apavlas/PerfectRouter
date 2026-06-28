import Foundation
import UserNotifications

/// Posts a local notification warning the rider about rain along their planned
/// route, so they're alerted even when they've put the phone away after
/// plotting a ride. The in-app banner still shows the same warning on screen.
///
/// A single notification (a fixed identifier) represents "rain on the current
/// ride" — re-checking a route replaces it rather than stacking duplicates, and
/// clearing it removes the warning once rain is no longer expected.
struct WeatherNotificationService {

    private let center = UNUserNotificationCenter.current()

    /// Stable identifier so each weather refresh replaces the previous warning
    /// instead of piling up multiple notifications.
    private let rainNotificationID = "moto.route.rain-warning"

    /// Shows (or replaces) the rain warning notification, or clears it when
    /// `message` is `nil` (rain no longer expected for the current route).
    ///
    /// The first time there's something to warn about, this asks the rider for
    /// notification permission in context. If permission is denied the call
    /// quietly does nothing — the on-screen warning still informs the rider.
    func updateRainWarning(_ message: String?) async {
        // Always clear the prior warning first so a now-dry route doesn't leave
        // a stale rain alert behind.
        center.removePendingNotificationRequests(withIdentifiers: [rainNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [rainNotificationID])

        guard let message else { return }

        guard await isAuthorized() else { return }

        let content = UNMutableNotificationContent()
        content.title = "Rain expected on your ride"
        content.body = message
        content.sound = .default

        // A nil trigger delivers immediately (suppressed by the system while the
        // app is foreground, where the in-app warning already covers it).
        let request = UNNotificationRequest(
            identifier: rainNotificationID,
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    /// Returns whether we may post notifications, requesting permission in
    /// context the first time. Idempotent: the system only prompts once.
    private func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            return granted
        case .denied:
            return false
        @unknown default:
            return false
        }
    }
}
