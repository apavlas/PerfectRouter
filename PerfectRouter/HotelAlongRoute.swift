import CoreLocation
import Foundation
import MapKit

/// Evening lodging along a planned ride.
///
/// The search is centered on a clock time (6:00 PM unless the rider changes
/// it), one hour either side. The point on the route is where planned riding
/// time reaches that clock, so a later departure moves it. Each option is a
/// real place the caller already found — this type never fills in a name,
/// a phone number, or a page.
enum HotelAlongRoute {

    /// 6:00 PM, minutes from local midnight.
    static let defaultTargetMinutes = 18 * 60

    /// "About 6 PM, an hour either way."
    static let windowHalfMinutes = 60

    /// The next morning's start after an overnight stop. The evening target
    /// is what the rider changes; this clock is the morning the next 6 PM
    /// point is measured from.
    static let morningDepartureMinutes = 8 * 60

    /// First corridor. One widen, to `farRadiusMeters`, when this is empty.
    static let nearRadiusMeters: CLLocationDistance = 5 * AppSettings.metersPerMile

    /// The single wider search. Results from it are labeled farther off.
    static let farRadiusMeters: CLLocationDistance = 15 * AppSettings.metersPerMile

    /// Two or three options when that many fall in the window. Fewer are
    /// kept as-is — a missing place is not invented to fill the row.
    static let maximumOptions = 3

    static let loadFailedCopy = "Couldn't load lodging. Tap to retry."

    /// Route-list row for a planned evening the rider has not applied.
    static let noHotelPickedCopy = "No hotel picked"

    /// An applied hotel this far past the 6 PM point still ends that evening.
    /// The next evening is a full morning-to-target ride away.
    static let appliedHotelSlackMeters: CLLocationDistance = 80 * AppSettings.metersPerMile

    /// One evening whose 6 PM point lies on the route, before the destination.
    struct Evening: Equatable {
        /// 1 for the day that starts at departure, then 2, 3, …
        var dayNumber: Int
        /// Meters from the route origin to this morning's start.
        var dayStartDistance: CLLocationDistance
        /// Meters from the route origin to the target clock.
        var targetDistance: CLLocationDistance
        /// Local minutes from midnight when this morning's riding clock starts.
        var departureMinutes: Int
        /// Riding seconds from that morning until the target clock.
        var ridingSeconds: TimeInterval
    }

    /// A lodging place reduced to the fields selection needs. `key` matches
    /// the stop the caller will show; the name is never rewritten here.
    struct Candidate: Equatable {
        var key: String
        var name: String
        var arrivalMinutes: Int
        var detourMeters: CLLocationDistance
        var distanceAlongRoute: CLLocationDistance
    }

    struct Selection: Equatable {
        /// Chosen keys, closest to the target clock first.
        var keys: [String]
        /// True when the near radius had nothing in the window and the wider
        /// radius supplied the options.
        var widened: Bool
        /// Set only when both radii were empty. Names the clock window.
        var emptyMessage: String?
    }

    /// Riding seconds from a same-day departure clock to the target clock.
    /// Nil when the rider leaves at or after the target — that evening is
    /// already behind them.
    static func ridingSeconds(fromDepartureMinutes departure: Int, toTargetMinutes target: Int) -> TimeInterval? {
        let delta = target - departure
        guard delta > 0 else { return nil }
        return TimeInterval(delta * 60)
    }

    /// Evenings that still need a hotel.
    ///
    /// An overnight consumes only the day it falls in: from that morning
    /// through the target clock, plus `appliedHotelSlackMeters` so a hotel
    /// a short way past 6 PM still counts as that night. A later evening's
    /// hotel does not swallow the nights before it. Days that are only a
    /// projection (no hotel picked yet) start the next morning at the 6 PM
    /// point, so a long ride suggests a hotel for each evening. A day whose
    /// riding time ends before the target clock adds nothing, and neither
    /// do the days after it.
    static func evenings(
        legs: [FuelStopRidingTime.Leg],
        overnightDistances: [CLLocationDistance],
        departureMinutes: Int,
        targetMinutes: Int,
        morningMinutes: Int = morningDepartureMinutes
    ) -> [Evening] {
        let totalDistance = legs.reduce(0.0) { partial, leg in
            guard leg.distanceMeters.isFinite else { return partial }
            return partial + max(0, leg.distanceMeters)
        }
        guard totalDistance > 1 else { return [] }

        let totalTime = FuelStopRidingTime.ridingTime(atDistance: totalDistance, legs: legs)
        var start: CLLocationDistance = 0
        var day = 1
        var clock = departureMinutes
        var planned = overnightDistances
            .filter { $0.isFinite && $0 > FuelStopRidingTime.sameStopToleranceMeters }
            .sorted()
        var results: [Evening] = []

        while start < totalDistance - 1, day <= 14 {
            // Leaving at or after the target clock (an evening start) still
            // rides a full day before the first hotel. Breaking here left a
            // 19-hour ride with no hotels whenever it was planned after 6 PM.
            guard let needed = ridingSeconds(fromDepartureMinutes: clock, toTargetMinutes: targetMinutes)
                ?? ridingSeconds(fromDepartureMinutes: morningMinutes, toTargetMinutes: targetMinutes) else {
                break
            }
            let startTime = FuelStopRidingTime.ridingTime(atDistance: start, legs: legs)
            let available = totalTime - startTime
            if available + 0.5 < needed {
                break
            }
            let targetDistance = FuelStopRidingTime.distance(
                atRidingTime: startTime + needed,
                legs: legs
            )
            // The destination is the end of the ride, not a night on the road.
            guard targetDistance > start + 1, targetDistance + 50 < totalDistance else {
                break
            }
            let tolerance = FuelStopRidingTime.sameStopToleranceMeters
            if let overnight = planned.first(where: {
                $0 > start + tolerance && $0 <= targetDistance + appliedHotelSlackMeters
            }) {
                planned.removeAll { $0 <= overnight + tolerance }
                start = overnight
                day += 1
                clock = morningMinutes
                continue
            }
            results.append(Evening(
                dayNumber: day,
                dayStartDistance: start,
                targetDistance: targetDistance,
                departureMinutes: clock,
                ridingSeconds: needed
            ))
            start = targetDistance
            day += 1
            clock = morningMinutes
        }
        return results
    }

    /// Near options win. An empty near list is the one chance to use `far`.
    /// Anything outside the window, or farther than the radius being tried,
    /// is dropped. Order is minutes from the target, then detour, then name.
    static func select(
        near: [Candidate],
        far: [Candidate],
        targetMinutes: Int,
        maxCount: Int = maximumOptions
    ) -> Selection {
        let nearHits = ranked(near, targetMinutes: targetMinutes, maxDetour: nearRadiusMeters, limit: maxCount)
        if !nearHits.isEmpty {
            return Selection(keys: nearHits.map(\.key), widened: false, emptyMessage: nil)
        }
        let farHits = ranked(far, targetMinutes: targetMinutes, maxDetour: farRadiusMeters, limit: maxCount)
        if !farHits.isEmpty {
            return Selection(keys: farHits.map(\.key), widened: true, emptyMessage: nil)
        }
        return Selection(keys: [], widened: false, emptyMessage: emptyMessage(targetMinutes: targetMinutes))
    }

    /// "No lodging found between 5 and 7 PM" at the default target.
    static func emptyMessage(targetMinutes: Int) -> String {
        "No lodging found between \(betweenPhrase(targetMinutes: targetMinutes))"
    }

    /// "Hotels between 5 and 7 PM".
    static func windowLabel(targetMinutes: Int) -> String {
        "Hotels between \(betweenPhrase(targetMinutes: targetMinutes))"
    }

    /// "5 and 7 PM" when both ends share a half of the day. A window that
    /// crosses noon names both: "11:30 AM and 1:30 PM".
    static func betweenPhrase(targetMinutes: Int) -> String {
        let start = targetMinutes - windowHalfMinutes
        let end = targetMinutes + windowHalfMinutes
        if period(of: start) == period(of: end) {
            let startText = clockText(minutes: start, includePeriod: false, omitZeroMinutes: true)
            let endText = clockText(minutes: end, includePeriod: true, omitZeroMinutes: true)
            return "\(startText) and \(endText)"
        }
        let startText = clockText(minutes: start, includePeriod: true, omitZeroMinutes: true)
        let endText = clockText(minutes: end, includePeriod: true, omitZeroMinutes: true)
        return "\(startText) and \(endText)"
    }

    /// Where a real place sits relative to one evening.
    ///
    /// `distanceAlongRoute` is the nearest point on the planned line.
    /// `detourMeters` is the straight-line distance from the place to that
    /// point (detour routing is not available). `arrivalMinutes` is the
    /// morning's departure plus the route ETA to that point — never the
    /// target clock copied onto every row.
    struct Measurement: Equatable {
        var distanceAlongRoute: CLLocationDistance
        var detourMeters: CLLocationDistance
        var arrivalMinutes: Int
    }

    /// Nil only when the route has no segment to measure against. A place
    /// that cannot be measured is not given a 6:00 PM / 0 mi stand-in.
    static func measurement(
        of coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]],
        legs: [FuelStopRidingTime.Leg],
        dayStartDistance: CLLocationDistance,
        departureMinutes: Int
    ) -> Measurement? {
        guard coordinate.isValidLocation else { return nil }
        guard polylines.contains(where: { $0.count > 1 }) else { return nil }
        let along = RouteGeometry.distanceAlongRoute(of: coordinate, alongPolylines: polylines)
        let detour = RouteGeometry.distanceFromRoute(of: coordinate, alongPolylines: polylines)
        guard along.isFinite, detour.isFinite else { return nil }
        return Measurement(
            distanceAlongRoute: max(0, along),
            detourMeters: max(0, detour),
            arrivalMinutes: arrivalMinutes(
                atDistance: along,
                legs: legs,
                dayStartDistance: dayStartDistance,
                departureMinutes: departureMinutes
            )
        )
    }

    /// Planned departure plus riding time from that morning to `distance`.
    static func arrivalMinutes(
        atDistance distance: CLLocationDistance,
        legs: [FuelStopRidingTime.Leg],
        dayStartDistance: CLLocationDistance,
        departureMinutes: Int
    ) -> Int {
        let origin = dayStartDistance.isFinite ? max(0, dayStartDistance) : 0
        let startTime = FuelStopRidingTime.ridingTime(atDistance: origin, legs: legs)
        let riding = FuelStopRidingTime.ridingTime(atDistance: max(0, distance), legs: legs) - startTime
        let minutes = Int((max(0, riding) / 60).rounded())
        return departureMinutes + max(0, minutes)
    }

    /// "arrive ~6:20 PM · 2 mi off route". Wider-radius options add
    /// "· farther off". A real offset under a mile keeps a tenth so it
    /// does not collapse to "0 mi".
    static func arrivalCaption(
        arrivalMinutes: Int,
        detourMeters: CLLocationDistance,
        fartherOff: Bool,
        usesMetric: Bool = AppSettings.usesMetricUnits
    ) -> String {
        let clock = clockText(minutes: arrivalMinutes, includePeriod: true, omitZeroMinutes: false)
        let distance = formatDetour(max(0, detourMeters), usesMetric: usesMetric)
        var text = "arrive ~\(clock) · \(distance) off route"
        if fartherOff {
            text += " · farther off"
        }
        return text
    }

    /// Whole miles at 2 mi and above a tenth under 10 mi. "2 mi" stays
    /// whole. "0.4 mi" does not round down to "0 mi".
    static func formatDetour(_ meters: CLLocationDistance, usesMetric: Bool) -> String {
        guard meters.isFinite else { return usesMetric ? "0 km" : "0 mi" }
        let unit: CLLocationDistance = usesMetric ? 1_000 : AppSettings.metersPerMile
        let unitName = usesMetric ? "km" : "mi"
        let value = max(0, meters) / unit
        if value >= 10 {
            return FuelStopRidingTime.formatDistance(meters, usesMetric: usesMetric)
        }
        let tenths = (value * 10).rounded() / 10
        if tenths < 0.05 {
            return "0 \(unitName)"
        }
        if abs(tenths - tenths.rounded()) < 0.001 {
            return "\(Int(tenths.rounded())) \(unitName)"
        }
        return String(format: "%.1f \(unitName)", tenths)
    }

    /// One checked hotel per evening. Selecting the same place again removes
    /// it. Selecting a different place on that evening replaces the first.
    /// Other evenings are left alone.
    static func checkedKeys(
        selecting key: String,
        onDay day: Int,
        current: [Int: String]
    ) -> [Int: String] {
        var next = current
        if next[day] == key {
            next.removeValue(forKey: day)
        } else {
            next[day] = key
        }
        return next
    }

    /// The hotels Apply may insert, one per evening, in day order. A second
    /// hotel for an evening already in `checked` does not become another day.
    static func keysToApply(_ checked: [Int: String]) -> [String] {
        checked.keys.sorted().compactMap { checked[$0] }
    }

    /// Stable identity for a real place. Rounded to three decimals, same as
    /// the fuel-stop coordinate key.
    static func placeKey(name: String, latitude: Double, longitude: Double) -> String {
        let lat = Int((latitude * 1000).rounded())
        let lon = Int((longitude * 1000).rounded())
        return "\(name)|\(lat)|\(lon)"
    }

    /// Minutes from midnight in `calendar`.
    static func minutes(from date: Date, calendar: Calendar = .current) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
    }

    /// A date on `day` whose clock is `minutes` from midnight.
    static func date(minutes: Int, on day: Date, calendar: Calendar = .current) -> Date {
        let clamped = min(max(minutes, 0), 24 * 60 - 1)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = clamped / 60
        parts.minute = clamped % 60
        parts.second = 0
        return calendar.date(from: parts) ?? day
    }

    /// The overnight stop before `index`, or the origin. The overnight row
    /// itself still belongs to the day that rode up to it.
    static func dayStartIndex(for index: Int, overnightIndices: [Int]) -> Int {
        overnightIndices.filter { $0 > 0 && $0 < index }.max() ?? 0
    }

    /// Meters of the overnight stop before `distance`. A stop at the hotel
    /// keeps the morning that rode there.
    static func dayStartDistance(
        for distance: CLLocationDistance,
        overnightDistances: [CLLocationDistance]
    ) -> CLLocationDistance {
        guard distance.isFinite else { return 0 }
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        return overnightDistances
            .filter { $0.isFinite && $0 < distance - tolerance }
            .max() ?? 0
    }

    /// "Day 1" on the origin and "Day 2" on the first row of the next morning
    /// when the route has an overnight stop. Nil for a one-day ride, and nil
    /// on rows that stay in the same day.
    static func dayTitle(at index: Int, overnightIndices: [Int]) -> String? {
        let splits = overnightIndices.filter { $0 > 0 }
        guard !splits.isEmpty, index >= 0 else { return nil }
        let day = splits.filter { $0 < index }.count + 1
        if index == 0 { return "Day \(day)" }
        let previous = splits.filter { $0 < index - 1 }.count + 1
        return day == previous ? nil : "Day \(day)"
    }

    /// One riding day on the route list. Boundaries are the planned evenings,
    /// whether or not a hotel was applied. The arrival day has no evening.
    struct RideDay: Equatable {
        var dayNumber: Int
        var startDistance: CLLocationDistance
        var endDistance: CLLocationDistance
        var ridingSeconds: TimeInterval
        /// Planned evening that ends this day when the rider has not applied
        /// a hotel. Nil for an applied hotel and for the arrival day.
        var unpickedEvening: Int?
        var exceedsDailyLimit: Bool
    }

    /// Morning departure to the evening target. That is the day's riding budget.
    static func dailyRidingLimit(
        targetMinutes: Int,
        morningMinutes: Int = morningDepartureMinutes
    ) -> TimeInterval {
        let minutes = targetMinutes - morningMinutes
        guard minutes > 0 else { return TimeInterval(10 * 60 * 60) }
        return TimeInterval(minutes * 60)
    }

    /// Day boundaries from the planned evenings.
    ///
    /// Zero, one, or every hotel applied keeps the same days. A hotel near an
    /// evening's 6 PM point ends that day; the miles change only by the
    /// detour. An evening with no hotel stays a boundary. A day longer than
    /// `dailyLimit` sets `exceedsDailyLimit`.
    static func rideDays(
        evenings: [Evening],
        overnightDistances: [CLLocationDistance],
        totalDistance: CLLocationDistance,
        legs: [FuelStopRidingTime.Leg],
        dailyLimit: TimeInterval
    ) -> [RideDay] {
        guard totalDistance.isFinite, totalDistance > 1 else { return [] }
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        let ordered = evenings
            .filter { $0.targetDistance.isFinite && $0.targetDistance > 1 && $0.targetDistance + 50 < totalDistance }
            .sorted { $0.targetDistance < $1.targetDistance }
        guard !ordered.isEmpty else { return [] }

        var hotels = overnightDistances
            .filter { $0.isFinite && $0 > tolerance && $0 + tolerance < totalDistance }
            .sorted()
        var start: CLLocationDistance = 0
        var days: [RideDay] = []

        for (index, evening) in ordered.enumerated() {
            let nextBoundary = index + 1 < ordered.count ? ordered[index + 1].targetDistance : totalDistance
            let gap = max(0, nextBoundary - evening.targetDistance)
            let slack = min(appliedHotelSlackMeters, gap * 0.5)
            let end: CLLocationDistance
            let unpicked: Int?
            if let match = hotels.firstIndex(where: {
                $0 > start + tolerance && $0 <= evening.targetDistance + slack
            }) {
                end = hotels.remove(at: match)
                unpicked = nil
            } else {
                end = evening.targetDistance
                unpicked = evening.dayNumber
            }
            guard end > start + 1 else { continue }
            days.append(makeDay(
                number: days.count + 1,
                start: start,
                end: end,
                legs: legs,
                dailyLimit: dailyLimit,
                unpickedEvening: unpicked
            ))
            start = end
        }

        if totalDistance > start + tolerance {
            days.append(makeDay(
                number: days.count + 1,
                start: start,
                end: totalDistance,
                legs: legs,
                dailyLimit: dailyLimit,
                unpickedEvening: nil
            ))
        }
        return days
    }

    private static func makeDay(
        number: Int,
        start: CLLocationDistance,
        end: CLLocationDistance,
        legs: [FuelStopRidingTime.Leg],
        dailyLimit: TimeInterval,
        unpickedEvening: Int?
    ) -> RideDay {
        let riding = max(
            0,
            FuelStopRidingTime.ridingTime(atDistance: end, legs: legs)
                - FuelStopRidingTime.ridingTime(atDistance: start, legs: legs)
        )
        return RideDay(
            dayNumber: number,
            startDistance: start,
            endDistance: end,
            ridingSeconds: riding,
            unpickedEvening: unpickedEvening,
            exceedsDailyLimit: riding > dailyLimit + 60
        )
    }

    /// `tel:` for a number Apple Maps already published. Nil when there is none.
    static func telephoneURL(from phone: String?) -> URL? {
        guard let phone else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        guard digits.contains(where: \.isNumber) else { return nil }
        return URL(string: "tel:\(digits)")
    }

    /// An http(s) page Apple Maps already published. Nil otherwise.
    static func websiteURL(from url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            return nil
        }
        guard let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func ranked(
        _ candidates: [Candidate],
        targetMinutes: Int,
        maxDetour: CLLocationDistance,
        limit: Int
    ) -> [Candidate] {
        guard limit > 0 else { return [] }
        let windowStart = targetMinutes - windowHalfMinutes
        let windowEnd = targetMinutes + windowHalfMinutes
        var seen = Set<String>()
        let kept = candidates.filter { candidate in
            guard candidate.detourMeters.isFinite, candidate.detourMeters >= 0 else { return false }
            guard candidate.detourMeters <= maxDetour else { return false }
            guard candidate.arrivalMinutes >= windowStart, candidate.arrivalMinutes <= windowEnd else { return false }
            return seen.insert(candidate.key).inserted
        }
        return kept.sorted { lhs, rhs in
            let left = abs(lhs.arrivalMinutes - targetMinutes)
            let right = abs(rhs.arrivalMinutes - targetMinutes)
            if left != right { return left < right }
            if lhs.detourMeters != rhs.detourMeters { return lhs.detourMeters < rhs.detourMeters }
            return lhs.name < rhs.name
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func period(of minutes: Int) -> String {
        let normalized = normalize(minutes)
        return normalized / 60 >= 12 ? "PM" : "AM"
    }

    static func clockText(minutes: Int, includePeriod: Bool, omitZeroMinutes: Bool) -> String {
        let normalized = normalize(minutes)
        let hour24 = normalized / 60
        let minute = normalized % 60
        let period = hour24 >= 12 ? "PM" : "AM"
        var hour = hour24 % 12
        if hour == 0 { hour = 12 }
        let time: String
        if omitZeroMinutes, minute == 0 {
            time = "\(hour)"
        } else {
            time = "\(hour):\(String(format: "%02d", minute))"
        }
        guard includePeriod else { return time }
        return "\(time) \(period)"
    }

    private static func normalize(_ minutes: Int) -> Int {
        let day = 24 * 60
        return ((minutes % day) + day) % day
    }
}

/// One evening's lodging rows. Options are places a search returned.
struct HotelEveningPlan: Identifiable {
    var dayNumber: Int
    /// Meters from the route origin to this morning's start.
    var dayStartDistance: CLLocationDistance = 0
    /// Local minutes from midnight when this morning's riding clock starts.
    var departureMinutes: Int = HotelAlongRoute.morningDepartureMinutes
    var options: [SuggestedStop]
    /// "arrive ~6:20 PM · 2 mi off route", keyed by the option's id.
    var captions: [UUID: String] = [:]
    /// True when these options came from the 15-mile widen.
    var widened: Bool
    /// "No lodging found between 5 and 7 PM" when this evening has no
    /// options. Every evening the ride reaches is published with either
    /// options or this message.
    var emptyMessage: String?
    var id: Int { dayNumber }
}
