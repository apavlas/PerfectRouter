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
/// day that runs past midnight reads above 1,440. Every clock in or out is
/// local time at that point on the route (#67): a day start's clock is local
/// where it starts, and `minutes(atDistance:)` answers in the zone at
/// `distance`. Meal windows and hotel time are checked against that local
/// clock. A point with no known zone uses the phone's.
struct RideClock: Equatable, Sendable {

    /// Time zone offsets along the route, as a step function: each mark's
    /// offset holds from its distance up to the next mark. Before the first
    /// mark, and with no marks at all, the phone's offset applies.
    struct Zones: Equatable, Sendable {
        struct Mark: Equatable, Sendable {
            var distance: CLLocationDistance
            var secondsFromGMT: Int
        }

        var marks: [Mark]
        var phoneSecondsFromGMT: Int

        init(marks: [Mark] = [], phoneSecondsFromGMT: Int = TimeZone.current.secondsFromGMT()) {
            self.marks = marks
                .filter { $0.distance.isFinite }
                .sorted { $0.distance < $1.distance }
            self.phoneSecondsFromGMT = phoneSecondsFromGMT
        }

        /// No zone data: every point reads the phone's time zone.
        static let phone = Zones()

        func secondsFromGMT(at distance: CLLocationDistance) -> Int {
            let tolerance = FuelStopRidingTime.sameStopToleranceMeters
            return marks.last { $0.distance <= distance + tolerance }?.secondsFromGMT
                ?? phoneSecondsFromGMT
        }

        /// Distances after `distance` where the offset changes.
        func changes(after distance: CLLocationDistance) -> [CLLocationDistance] {
            var result: [CLLocationDistance] = []
            var current = secondsFromGMT(at: distance)
            for mark in marks where mark.distance > distance + FuelStopRidingTime.sameStopToleranceMeters {
                if mark.secondsFromGMT != current {
                    result.append(mark.distance)
                    current = mark.secondsFromGMT
                }
            }
            return result
        }
    }

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
    /// Time zones along the route. Defaults to the phone's everywhere.
    var zones: Zones

    init(
        legs: [FuelStopRidingTime.Leg],
        dayStarts: [DayStart],
        stops: [Stop] = [],
        mealWindows: [MealWindow] = MealWindow.typical,
        hotelMinutes: Int? = nil,
        zones: Zones = .phone
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
        self.zones = zones
    }

    /// The same clock with more stops on the plan.
    func adding(_ more: [Stop]) -> RideClock {
        RideClock(
            legs: legs,
            dayStarts: dayStarts,
            stops: stops + more,
            mealWindows: mealWindows,
            hotelMinutes: hotelMinutes,
            zones: zones
        )
    }

    /// Minutes to add to a clock kept in the day start's zone to read it in
    /// the zone at `distance`: +60 riding from Mountain into Central.
    func shiftMinutes(at distance: CLLocationDistance, from start: DayStart) -> Double {
        Double(zones.secondsFromGMT(at: distance) - zones.secondsFromGMT(at: start.distance)) / 60
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

    /// Like `minutes(atDistance:)`, measured from a given day start. Local
    /// time at `distance`.
    func minutes(atDistance distance: CLLocationDistance, from start: DayStart) -> Double {
        localMinutes(atDistance: distance, from: start, meals: meals(on: start))
    }

    private func localMinutes(
        atDistance distance: CLLocationDistance,
        from start: DayStart,
        meals: DayMeals
    ) -> Double {
        elapsedMinutes(atDistance: distance, from: start, meals: meals) + shiftMinutes(at: distance, from: start)
    }

    /// The clock at `distance` kept in the day start's zone, so it only
    /// counts riding and stopped time. Allowances read local time.
    private func elapsedMinutes(
        atDistance distance: CLLocationDistance,
        from start: DayStart,
        meals: DayMeals
    ) -> Double {
        var clock = Double(start.minutes) * 60
        var cursor = max(0, start.distance)
        for stop in stopsAfter(start.distance) {
            guard stop.distance < distance - FuelStopRidingTime.sameStopToleranceMeters else { break }
            clock += ride(from: cursor, to: stop.distance)
            clock += allowance(for: stop, arrivingAtSeconds: clock, dayStart: start, meals: meals)
            cursor = stop.distance
        }
        clock += ride(from: cursor, to: distance)
        return clock / 60
    }

    /// Where the local clock first reaches `target` minutes on the riding
    /// day that starts at `start`. Clamps to the end of the route. When the
    /// target passes while the rider is stopped, the answer is that stop;
    /// when it is skipped by a zone line (riding east into a later zone),
    /// the answer is the line.
    func distance(reachingMinutes target: Double, from start: DayStart) -> CLLocationDistance {
        var segmentStart = max(0, start.distance)
        for change in zones.changes(after: start.distance) {
            let reached = distance(reachingElapsedMinutes: target - shiftMinutes(at: segmentStart, from: start), from: start)
            if reached <= segmentStart { return segmentStart }
            if reached < change { return reached }
            segmentStart = change
        }
        let reached = distance(reachingElapsedMinutes: target - shiftMinutes(at: segmentStart, from: start), from: start)
        return max(segmentStart, reached)
    }

    /// Where the clock kept in the day start's zone reaches `target`.
    private func distance(reachingElapsedMinutes target: Double, from start: DayStart) -> CLLocationDistance {
        var remaining = (target - Double(start.minutes)) * 60
        guard remaining > 0 else { return max(0, start.distance) }
        let meals = meals(on: start)
        var cursor = max(0, start.distance)
        var clock = Double(start.minutes) * 60
        for stop in stopsAfter(start.distance) {
            let toStop = ride(from: cursor, to: stop.distance)
            if toStop >= remaining { break }
            remaining -= toStop
            clock += toStop
            cursor = stop.distance
            let pause = allowance(for: stop, arrivingAtSeconds: clock, dayStart: start, meals: meals)
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
        let start = dayStart(for: distance)
        return isMealStopTime(minutes: minutes, dayStart: start, meals: meals(on: start))
    }

    private func isMealStopTime(minutes: Double, dayStart start: DayStart, meals: DayMeals) -> Bool {
        guard let window = mealWindow(at: minutes) else { return false }
        if window == .breakfast, start.minutes >= Self.breakfastSkipStartMinutes { return false }
        if window == .dinner, !meals.dinnerStops { return false }
        return !meals.covered.contains(window)
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

    /// One riding day's meal decisions: the meals applied food waypoints
    /// cover, and whether the day runs late enough for a dinner stop.
    private struct DayMeals: Equatable {
        var covered: [MealWindow] = []
        var dinnerStops = false
    }

    /// The meal decisions for the riding day that starts at `start`. They
    /// feed the clock that decides them (an earlier Meal stop makes a
    /// restaurant arrive later), so they are settled by re-running the day
    /// until nothing changes. Every pass uses real allowances: the dinner
    /// cutoff counts earlier Meal stops and only leaves dinner itself out.
    private func meals(on start: DayStart) -> DayMeals {
        var meals = DayMeals()
        for _ in 0..<4 {
            let noDinner = DayMeals(covered: meals.covered, dinnerStops: false)
            let dinnerStops = dayEndMinutes(from: start, meals: noDinner) >= Double(Self.dinnerSkipEndMinutes)
            let settled = DayMeals(covered: meals.covered, dinnerStops: dinnerStops)
            let next = DayMeals(covered: foodCovered(on: start, meals: settled), dinnerStops: dinnerStops)
            if next == meals { break }
            meals = next
        }
        return meals
    }

    /// The next riding day's start after `start`, if the clock has one.
    private func nextDayStart(after start: DayStart) -> DayStart? {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        return dayStarts.first { $0.distance > start.distance + tolerance }
    }

    /// Where the riding day that starts at `start` ends: the next day start,
    /// or the destination capped at the Evening when there is a hotel time.
    private func dayEndMinutes(from start: DayStart, meals: DayMeals) -> Double {
        if let next = nextDayStart(after: start) {
            return localMinutes(atDistance: next.distance, from: start, meals: meals)
        }
        let end = localMinutes(atDistance: routeLength, from: start, meals: meals)
        guard let hotelMinutes else { return end }
        return min(end, Double(hotelMinutes))
    }

    /// Meals the food waypoints on this riding day are reached in. A day
    /// ends at the next day start or, before later days are known, at hotel
    /// time; a clock past midnight is not today's meal.
    private func foodCovered(on start: DayStart, meals: DayMeals) -> [MealWindow] {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        let dayEnd = nextDayStart(after: start)?.distance ?? .infinity
        let latest = nextDayStart(after: start) == nil ? Double(hotelMinutes ?? 24 * 60) : Double(24 * 60)
        var covered: [MealWindow] = []
        for stop in stops where stop.kind == .food {
            guard stop.distance > start.distance + tolerance,
                  stop.distance < dayEnd - tolerance else { continue }
            let arrival = localMinutes(atDistance: stop.distance, from: start, meals: meals)
            guard arrival <= latest, arrival < Double(24 * 60),
                  let window = mealWindow(at: arrival),
                  !covered.contains(window) else { continue }
            covered.append(window)
        }
        return mealWindows.filter { covered.contains($0) }
    }

    private var routeLength: CLLocationDistance {
        legs.reduce(0) { total, leg in
            guard leg.distanceMeters.isFinite else { return total }
            return total + max(0, leg.distanceMeters)
        }
    }

    private func allowance(
        for stop: Stop,
        arrivingAtSeconds seconds: Double,
        dayStart start: DayStart,
        meals: DayMeals
    ) -> TimeInterval {
        // Meal windows are local time where the stop is.
        let minutes = seconds / 60 + shiftMinutes(at: stop.distance, from: start)
        switch stop.kind {
        case .waypoint:
            return Self.waypointAllowance
        case .food:
            return mealWindow(at: minutes) == nil ? Self.waypointAllowance : Self.mealStopAllowance
        case .fuel(let hasFood):
            if hasFood, isMealStopTime(minutes: minutes, dayStart: start, meals: meals) {
                return Self.mealStopAllowance
            }
            return Self.fuelStopAllowance
        }
    }
}
