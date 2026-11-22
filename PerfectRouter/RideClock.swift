import CoreLocation
import Foundation

/// Clock predictions along a ride: riding time plus a stop allowance for
/// each stop the rider passes, restarting at every riding day's start.
///
/// Riding time (`FuelStopRidingTime`) is time moving and stays that way in
/// the "riding" captions. A clock — "arrive ~6:20 PM", where an Evening
/// falls, whether a fuel stop lands at lunch — also counts the time the
/// rider spends stopped on the way there.
///
/// Clocks are minutes from midnight on the morning a riding day starts, so a
/// day that runs past midnight reads above 1,440. They use the phone's time
/// zone; local time along the route is a separate change.
struct RideClock: Equatable, Sendable {

    /// What a stop on the plan is, which sets its allowance.
    enum StopKind: Equatable, Sendable {
        /// A fuel stop. With food close by, it is a Meal stop when the
        /// rider reaches it inside a meal window.
        case fuel(hasFood: Bool)
        /// Any other intermediate waypoint: a sight, coffee, a food place.
        case waypoint
    }

    /// A stop on the plan, by distance from the route start.
    struct Stop: Equatable, Sendable {
        var distance: CLLocationDistance
        var kind: StopKind
    }

    /// Where a riding day starts and its clock there.
    struct DayStart: Equatable, Sendable {
        var distance: CLLocationDistance
        var minutes: Int
    }

    static let fuelStopAllowance: TimeInterval = 15 * 60
    static let mealStopAllowance: TimeInterval = 45 * 60
    static let waypointAllowance: TimeInterval = 15 * 60

    var legs: [FuelStopRidingTime.Leg]
    /// Riding days by start distance. The first is the ride start and its
    /// departure clock; later ones are Overnights or Evenings.
    var dayStarts: [DayStart]
    var stops: [Stop]
    var mealWindows: [MealWindow] = MealWindow.typical

    init(
        legs: [FuelStopRidingTime.Leg],
        dayStarts: [DayStart],
        stops: [Stop] = [],
        mealWindows: [MealWindow] = MealWindow.typical
    ) {
        self.legs = legs
        self.dayStarts = dayStarts
            .filter { $0.distance.isFinite }
            .sorted { $0.distance < $1.distance }
        self.stops = stops
            .filter { $0.distance.isFinite }
            .sorted { $0.distance < $1.distance }
        self.mealWindows = mealWindows
    }

    /// The same clock with more stops on the plan.
    func adding(_ more: [Stop]) -> RideClock {
        RideClock(legs: legs, dayStarts: dayStarts, stops: stops + more, mealWindows: mealWindows)
    }

    /// The riding day `distance` falls in: the last start at or before it.
    func dayStart(for distance: CLLocationDistance) -> DayStart {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        return dayStarts.last { $0.distance <= distance + tolerance }
            ?? dayStarts.first
            ?? DayStart(distance: 0, minutes: 0)
    }

    /// Clock when the rider reaches `distance`: that day's start clock plus
    /// riding time plus the allowance of every stop passed before it. A stop
    /// at `distance` itself is the arrival, so its allowance is not counted.
    func minutes(atDistance distance: CLLocationDistance) -> Double {
        let distance = distance.isFinite ? max(0, distance) : 0
        let start = dayStart(for: distance)
        return minutes(atDistance: distance, from: start)
    }

    /// Like `minutes(atDistance:)`, measured from a given day start.
    func minutes(atDistance distance: CLLocationDistance, from start: DayStart) -> Double {
        var clock = Double(start.minutes) * 60
        var cursor = max(0, start.distance)
        for stop in stopsAfter(start.distance) {
            guard stop.distance < distance - FuelStopRidingTime.sameStopToleranceMeters else { break }
            clock += ride(from: cursor, to: stop.distance)
            clock += allowance(for: stop.kind, arrivingAtSeconds: clock)
            cursor = stop.distance
        }
        clock += ride(from: cursor, to: distance)
        return clock / 60
    }

    /// Where the clock reaches `target` minutes on the riding day that
    /// starts at `start`. Clamps to the end of the route. When the target
    /// passes while the rider is stopped, the answer is that stop.
    func distance(reachingMinutes target: Double, from start: DayStart) -> CLLocationDistance {
        var remaining = (target - Double(start.minutes)) * 60
        guard remaining > 0 else { return max(0, start.distance) }
        var cursor = max(0, start.distance)
        var clock = Double(start.minutes) * 60
        for stop in stopsAfter(start.distance) {
            let toStop = ride(from: cursor, to: stop.distance)
            if toStop >= remaining { break }
            remaining -= toStop
            clock += toStop
            cursor = stop.distance
            let pause = allowance(for: stop.kind, arrivingAtSeconds: clock)
            if pause >= remaining { return cursor }
            remaining -= pause
            clock += pause
        }
        let riding = FuelStopRidingTime.ridingTime(atDistance: cursor, legs: legs) + remaining
        return FuelStopRidingTime.distance(atRidingTime: riding, legs: legs)
    }

    /// Whether a clock (minutes from that morning's midnight) falls in a
    /// meal window. Past midnight wraps to the next day's clock.
    func isMealTime(minutes: Double) -> Bool {
        Self.isMealTime(minutes: minutes, windows: mealWindows)
    }

    static func isMealTime(minutes: Double, windows: [MealWindow]) -> Bool {
        guard minutes.isFinite else { return false }
        let wrapped = Int(minutes.rounded(.down)) % (24 * 60)
        let clock = wrapped < 0 ? wrapped + 24 * 60 : wrapped
        return windows.contains { window in
            if window.startMinutes <= window.endMinutes {
                return clock >= window.startMinutes && clock < window.endMinutes
            }
            return clock >= window.startMinutes || clock < window.endMinutes
        }
    }

    private func stopsAfter(_ distance: CLLocationDistance) -> [Stop] {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        return stops.filter { $0.distance > distance + tolerance }
    }

    private func ride(from: CLLocationDistance, to: CLLocationDistance) -> TimeInterval {
        guard to > from else { return 0 }
        return FuelStopRidingTime.ridingTime(atDistance: to, legs: legs)
            - FuelStopRidingTime.ridingTime(atDistance: from, legs: legs)
    }

    private func allowance(for kind: StopKind, arrivingAtSeconds seconds: Double) -> TimeInterval {
        switch kind {
        case .waypoint:
            return Self.waypointAllowance
        case .fuel(let hasFood):
            if hasFood, isMealTime(minutes: seconds / 60) {
                return Self.mealStopAllowance
            }
            return Self.fuelStopAllowance
        }
    }
}
