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
        /// A food place the rider applied. Inside a meal window it is that
        /// meal (#66): the Meal stop allowance, and no Meal stop is sought
        /// for that meal on that riding day.
        case food
        /// Any other intermediate waypoint: a sight, coffee.
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
    /// The rider's hotel time. A riding day with no later day start ends at
    /// the destination or at its Evening, whichever comes first; this is
    /// the Evening's clock. Nil: the day ends at the destination.
    var hotelMinutes: Int?

    init(
        legs: [FuelStopRidingTime.Leg],
        dayStarts: [DayStart],
        stops: [Stop] = [],
        mealWindows: [MealWindow] = MealWindow.typical,
        hotelMinutes: Int? = nil
    ) {
        self.legs = legs
        self.dayStarts = dayStarts
            .filter { $0.distance.isFinite }
            .sorted { $0.distance < $1.distance }
        self.stops = stops
            .filter { $0.distance.isFinite }
            .sorted { $0.distance < $1.distance }
        self.mealWindows = mealWindows
        self.hotelMinutes = hotelMinutes
    }

    /// The same clock with more stops on the plan.
    func adding(_ more: [Stop]) -> RideClock {
        RideClock(
            legs: legs,
            dayStarts: dayStarts,
            stops: stops + more,
            mealWindows: mealWindows,
            hotelMinutes: hotelMinutes
        )
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
        minutes(atDistance: distance, from: start, mealAware: true)
    }

    /// `mealAware: false` counts every stop at its plain allowance. Used for
    /// a day's end clock, which the meal rules themselves read.
    private func minutes(
        atDistance distance: CLLocationDistance,
        from start: DayStart,
        mealAware: Bool
    ) -> Double {
        var clock = Double(start.minutes) * 60
        var cursor = max(0, start.distance)
        for stop in stopsAfter(start.distance) {
            guard stop.distance < distance - FuelStopRidingTime.sameStopToleranceMeters else { break }
            clock += ride(from: cursor, to: stop.distance)
            clock += mealAware
                ? allowance(for: stop, arrivingAtSeconds: clock, dayStart: start)
                : plainAllowance(for: stop.kind)
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
            let pause = allowance(for: stop, arrivingAtSeconds: clock, dayStart: start)
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

    /// Whether a fuel stop reached at `minutes` (on the riding day that
    /// holds `distance`) should be a Meal stop (#66): inside a meal window,
    /// except breakfast on a day that starts at or after 7:00, dinner on a
    /// day that ends before 8:00 PM (the rider eats at the hotel), and a
    /// meal a food waypoint already covers that day.
    func isMealStopTime(minutes: Double, atDistance distance: CLLocationDistance) -> Bool {
        isMealStopTime(minutes: minutes, dayStart: dayStart(for: distance))
    }

    private func isMealStopTime(minutes: Double, dayStart start: DayStart) -> Bool {
        guard let window = mealWindow(at: minutes) else { return false }
        if window == .breakfast, start.minutes >= Self.breakfastSkipStartMinutes { return false }
        if window == .dinner, dayEndMinutes(from: start) < Double(Self.dinnerSkipEndMinutes) { return false }
        return !foodCovers(window, on: start)
    }

    /// A riding day that starts at or after this skips breakfast stops.
    static let breakfastSkipStartMinutes = 7 * 60
    /// A riding day that ends before this skips dinner stops.
    static let dinnerSkipEndMinutes = 20 * 60

    private func mealWindow(at minutes: Double) -> MealWindow? {
        guard minutes.isFinite else { return nil }
        let wrapped = Int(minutes.rounded(.down)) % (24 * 60)
        let clock = wrapped < 0 ? wrapped + 24 * 60 : wrapped
        return mealWindows.first { window in
            if window.startMinutes <= window.endMinutes {
                return clock >= window.startMinutes && clock < window.endMinutes
            }
            return clock >= window.startMinutes || clock < window.endMinutes
        }
    }

    /// Where the riding day that starts at `start` ends: the next day start,
    /// or the destination capped at the Evening when there is a hotel time.
    private func dayEndMinutes(from start: DayStart) -> Double {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        if let next = dayStarts.first(where: { $0.distance > start.distance + tolerance }) {
            return minutes(atDistance: next.distance, from: start, mealAware: false)
        }
        let end = minutes(atDistance: routeLength, from: start, mealAware: false)
        guard let hotelMinutes else { return end }
        return min(end, Double(hotelMinutes))
    }

    /// True when a food waypoint on the riding day that starts at `start`
    /// is reached inside `window`.
    private func foodCovers(_ window: MealWindow, on start: DayStart) -> Bool {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        let dayEnd = dayStarts.first(where: { $0.distance > start.distance + tolerance })?.distance ?? .infinity
        return stops.contains { stop in
            guard stop.kind == .food,
                  stop.distance > start.distance + tolerance,
                  stop.distance < dayEnd - tolerance else { return false }
            let arrival = minutes(atDistance: stop.distance, from: start, mealAware: false)
            return mealWindow(at: arrival) == window
        }
    }

    private var routeLength: CLLocationDistance {
        legs.reduce(0) { total, leg in
            guard leg.distanceMeters.isFinite else { return total }
            return total + max(0, leg.distanceMeters)
        }
    }

    private func plainAllowance(for kind: StopKind) -> TimeInterval {
        switch kind {
        case .waypoint, .food: return Self.waypointAllowance
        case .fuel: return Self.fuelStopAllowance
        }
    }

    private func allowance(for stop: Stop, arrivingAtSeconds seconds: Double, dayStart start: DayStart) -> TimeInterval {
        let minutes = seconds / 60
        switch stop.kind {
        case .waypoint:
            return Self.waypointAllowance
        case .food:
            return mealWindow(at: minutes) == nil ? Self.waypointAllowance : Self.mealStopAllowance
        case .fuel(let hasFood):
            if hasFood, isMealStopTime(minutes: minutes, dayStart: start) {
                return Self.mealStopAllowance
            }
            return Self.fuelStopAllowance
        }
    }
}
