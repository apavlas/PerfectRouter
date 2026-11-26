import CoreLocation
import Foundation
import MessageUI
import Observation
import UserNotifications

/// A ride the rider has checked in with a Rider Group for.
///
/// Everything runs on the phone, with no server: the start text tells the
/// group when the rider expects to arrive and when to start worrying, so the
/// group itself is the backstop if the phone is dead or the app never runs
/// again. The app adds local reminders to the rider at the ETA and when they
/// are overdue, each opening a text to the group in one tap.
struct RideCheckIn: Codable, Equatable {
    var groupID: UUID
    var groupName: String
    var recipients: [String]
    var destinationName: String
    var startedAt: Date
    var expectedArrival: Date
    /// When the group should act if they haven't heard anything.
    var overdueAt: Date

    /// Extra time after the ETA before the rider counts as overdue: a quarter
    /// of the ride, at least 30 minutes and at most 2 hours.
    static func grace(forRideTime rideTime: TimeInterval) -> TimeInterval {
        min(max(rideTime * 0.25, 30 * 60), 2 * 60 * 60)
    }

    /// Predicted arrival: riding time plus 15 minutes for every stop on the
    /// plan, matching the stop allowance the rest of the app uses.
    static func expectedArrival(start: Date, ridingTime: TimeInterval, stopCount: Int) -> Date {
        start.addingTimeInterval(ridingTime + Double(max(stopCount, 0)) * 15 * 60)
    }

    static func make(
        group: RiderGroup,
        destinationName: String,
        start: Date,
        ridingTime: TimeInterval,
        stopCount: Int
    ) -> RideCheckIn {
        let arrival = expectedArrival(start: start, ridingTime: ridingTime, stopCount: stopCount)
        return RideCheckIn(
            groupID: group.id,
            groupName: group.name,
            recipients: group.phoneNumbers,
            destinationName: destinationName,
            startedAt: start,
            expectedArrival: arrival,
            overdueAt: arrival.addingTimeInterval(grace(forRideTime: arrival.timeIntervalSince(start)))
        )
    }

    func isOverdue(now: Date = Date()) -> Bool { now >= overdueAt }

    // MARK: - Messages

    static func clock(_ date: Date, relativeTo now: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        formatter.dateStyle = calendar.isDate(date, inSameDayAs: now) ? .none : .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func startMessage(timeZone: TimeZone = .current) -> String {
        let eta = Self.clock(expectedArrival, relativeTo: startedAt, timeZone: timeZone)
        let overdue = Self.clock(overdueAt, relativeTo: startedAt, timeZone: timeZone)
        return "Heading out now to \(destinationName). I expect to get there around \(eta). "
            + "I'll text when I arrive. If you haven't heard from me by \(overdue), please call me."
    }

    func arrivalMessage() -> String {
        "Made it to \(destinationName) safely. Thanks for keeping an eye out."
    }

    /// Sent by the rider when they're running late but fine, or by the group
    /// prompt when overdue. Includes a location link when one is known.
    func lateMessage(location: CLLocationCoordinate2D?, now: Date = Date(), timeZone: TimeZone = .current) -> String {
        let eta = Self.clock(expectedArrival, relativeTo: now, timeZone: timeZone)
        var text = "I'm running behind my \(eta) arrival at \(destinationName)."
        if let location, let link = Self.mapsLink(location) {
            text += " I'm here: \(link)"
        }
        return text
    }

    static func mapsLink(_ coordinate: CLLocationCoordinate2D) -> String? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        let lat = String(format: "%.5f", coordinate.latitude)
        let lon = String(format: "%.5f", coordinate.longitude)
        return "https://maps.apple.com/?ll=\(lat),\(lon)&q=My%20location"
    }
}

/// Keeps the active check-in across launches, so a ride the app was closed
/// during still shows "I've arrived" when it is opened again.
struct RideCheckInStore {
    static let key = "safety.activeCheckIn"
    var defaults: UserDefaults = .standard

    func load() -> RideCheckIn? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        return try? JSONDecoder().decode(RideCheckIn.self, from: data)
    }

    func save(_ checkIn: RideCheckIn?) {
        guard let checkIn, let data = try? JSONEncoder().encode(checkIn) else {
            defaults.removeObject(forKey: Self.key)
            return
        }
        defaults.set(data, forKey: Self.key)
    }
}

/// Local reminders to the rider for an active check-in. iOS holds the
/// triggers, so they fire while the app is suspended or closed.
struct RideCheckInNotifier {
    private let center = UNUserNotificationCenter.current()
    static let arrivalID = "safety.checkin.arrival"
    static let overdueID = "safety.checkin.overdue"

    func schedule(_ checkIn: RideCheckIn, now: Date = Date()) async {
        cancel()
        guard await isAuthorized() else { return }
        await add(
            id: Self.arrivalID,
            title: "Arrived at \(checkIn.destinationName)?",
            body: "Open Perfect Router to text \(checkIn.groupName) that you made it.",
            at: checkIn.expectedArrival,
            now: now
        )
        await add(
            id: Self.overdueID,
            title: "You're past your ETA",
            body: "\(checkIn.groupName) will start to worry. Open Perfect Router to text them where you are.",
            at: checkIn.overdueAt.addingTimeInterval(-10 * 60),
            now: now
        )
    }

    func cancel() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.arrivalID, Self.overdueID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.arrivalID, Self.overdueID])
    }

    private func add(id: String, title: String, body: String, at date: Date, now: Date) async {
        let interval = date.timeIntervalSince(now)
        guard interval >= 60 else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: id,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )
        try? await center.add(request)
    }

    private func isAuthorized() async -> Bool {
        let status = await center.notificationSettings().authorizationStatus
        switch status {
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

/// The rider's check-in choice and the ride currently checked in. One shared
/// instance, like `ProStore`, so the planner view model stays untouched.
@MainActor
@Observable
final class RideCheckInController {
    static let shared = RideCheckInController()

    static let selectedGroupKey = "safety.checkInGroupID"

    /// The group to check in with when the rider taps Navigate. Nil is off.
    var selectedGroupID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedGroupID?.uuidString, forKey: Self.selectedGroupKey)
        }
    }

    private(set) var active: RideCheckIn?

    private let store = RideCheckInStore()
    private let notifier = RideCheckInNotifier()

    init() {
        selectedGroupID = UserDefaults.standard.string(forKey: Self.selectedGroupKey).flatMap(UUID.init(uuidString:))
        active = store.load()
    }

    /// The selected group, if it still exists and has someone to text.
    func selectedGroup(in groups: [RiderGroup]) -> RiderGroup? {
        guard let selectedGroupID,
              let group = groups.first(where: { $0.id == selectedGroupID }),
              !group.riders.isEmpty else { return nil }
        return group
    }

    /// The text to the group being composed. Presented from the planning
    /// List in `ContentView`: a sheet on a List section doesn't present when
    /// its row handles the tap.
    var composing: CheckInText?

    /// A check-in waiting for its start text to be sent. Not saved and no
    /// reminders until then, so a cancelled text or a killed app leaves no
    /// check-in the group never heard about.
    private var pending: RideCheckIn?

    /// Opens the start text for `checkIn`; the ride hands off to `then` once
    /// the composer closes.
    func propose(_ checkIn: RideCheckIn, then target: CheckInText.Navigation) {
        pending = checkIn
        composing = CheckInText(
            recipients: checkIn.recipients,
            body: checkIn.startMessage(),
            endsCheckIn: false,
            then: target
        )
    }

    /// Opens a text to the active check-in's group.
    func compose(_ body: String, endsCheckIn: Bool) {
        guard let active else { return }
        composing = CheckInText(recipients: active.recipients, body: body, endsCheckIn: endsCheckIn)
    }

    /// The composer's result. A sent start text activates the check-in; a
    /// sent "I've arrived" ends it.
    func composerFinished(_ text: CheckInText, result: MessageComposeResult) {
        if text.startsCheckIn {
            if result == .sent, let pending { start(pending) }
            pending = nil
        }
        if text.endsCheckIn, result == .sent { finish() }
    }

    private func start(_ checkIn: RideCheckIn) {
        active = checkIn
        store.save(checkIn)
        Task { await notifier.schedule(checkIn) }
    }

    func finish() {
        pending = nil
        active = nil
        store.save(nil)
        notifier.cancel()
    }
}
