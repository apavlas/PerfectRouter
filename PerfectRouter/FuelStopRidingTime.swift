import CoreLocation
import Foundation

/// Drive time along a planned route, for the fuel-stop rows.
///
/// Each leg contributes its own `MKRoute.expectedTravelTime`, spread in
/// proportion to distance along that leg's polyline. A highway leg and a
/// mountain leg keep different paces — this is not total time times
/// distance over total distance.
///
/// Time the rider spends stopped is not part of the result. Leg times are
/// driving time only, and a leg with no length (a point where the rider
/// is sitting still) adds nothing.
enum FuelStopRidingTime {

    /// One planned leg: polyline length, and that leg's drive time.
    struct Leg: Equatable, Sendable {
        var distanceMeters: CLLocationDistance
        var expectedTravelTime: TimeInterval
    }

    /// Cumulative drive time to a stop, and drive time since the previous one.
    struct Reading: Equatable, Sendable {
        var cumulative: TimeInterval
        /// Drive time since the previous fuel stop, or since departure when
        /// this is the first.
        var sincePrevious: TimeInterval
        /// True when no earlier stop anchors this reading.
        var sinceDeparture: Bool
    }

    /// Two anchors closer than this are the same stop, so one does not
    /// count as "since last" for the other. Projection noise after a replan
    /// is well under this; real fuel stops are miles apart.
    static let sameStopToleranceMeters: CLLocationDistance = 50

    /// Builds a leg from the polyline the router drew and that leg's
    /// `expectedTravelTime`. Length is polyline length, not a separate
    /// road-distance field, so it lines up with `distanceAlongRoute`.
    static func leg(
        polyline: [CLLocationCoordinate2D],
        expectedTravelTime: TimeInterval
    ) -> Leg {
        Leg(
            distanceMeters: RouteGeometry.length(of: polyline),
            expectedTravelTime: finite(expectedTravelTime)
        )
    }

    /// Drive time from the start to `distance`, walking each leg in order.
    static func ridingTime(atDistance distance: CLLocationDistance, legs: [Leg]) -> TimeInterval {
        guard distance.isFinite else { return 0 }
        let target = max(0, distance)
        var traveled: CLLocationDistance = 0
        var elapsed: TimeInterval = 0

        for leg in legs {
            let length = finite(leg.distanceMeters)
            let legTime = finite(leg.expectedTravelTime)
            // No road to ride. Whatever time is attached here is time at a
            // point — a stop — and does not count as riding.
            guard length > 0 else { continue }
            if target <= traveled {
                return elapsed
            }
            let legEnd = traveled + length
            if target >= legEnd {
                elapsed += legTime
                traveled = legEnd
                continue
            }
            elapsed += legTime * ((target - traveled) / length)
            return elapsed
        }
        return elapsed
    }

    /// `anchors` are fuel-stop and applied-fill distances along the route.
    /// The previous stop is the farthest anchor still before `distance`.
    static func clock(
        at distance: CLLocationDistance,
        anchors: [CLLocationDistance],
        legs: [Leg]
    ) -> Reading {
        let distance = distance.isFinite ? max(0, distance) : 0
        let cumulative = ridingTime(atDistance: distance, legs: legs)
        let previous = anchors
            .filter { $0.isFinite && $0 < distance - sameStopToleranceMeters }
            .max()
        guard let previous else {
            return Reading(
                cumulative: cumulative,
                sincePrevious: cumulative,
                sinceDeparture: true
            )
        }
        let since = max(0, cumulative - ridingTime(atDistance: previous, legs: legs))
        return Reading(
            cumulative: cumulative,
            sincePrevious: since,
            sinceDeparture: false
        )
    }

    /// "6h 05m", "40m" under an hour, "25h 05m" past a day. Nearest minute.
    /// Hours are not rolled into days.
    static func formatDuration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0m" }
        let totalMinutes = max(0, Int((seconds / 60).rounded()))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "\(hours)h \(String(format: "%02d", minutes))m"
        }
        return "\(minutes)m"
    }

    /// Whole miles or kilometers, matching the short unit the rest of the
    /// ride uses ("212 mi", "341 km").
    static func formatDistance(_ meters: CLLocationDistance, usesMetric: Bool) -> String {
        guard meters.isFinite else { return usesMetric ? "0 km" : "0 mi" }
        let unitMeters: CLLocationDistance = usesMetric ? 1_000 : AppSettings.metersPerMile
        let value = max(0, Int((max(0, meters) / unitMeters).rounded()))
        return usesMetric ? "\(value) km" : "\(value) mi"
    }

    /// "212 mi · 6h 05m riding (1h 40m since last)". The first stop says
    /// "since departure". Distance is always first.
    static func caption(
        distanceMeters: CLLocationDistance,
        anchors: [CLLocationDistance],
        legs: [Leg],
        usesMetric: Bool = AppSettings.usesMetricUnits
    ) -> String {
        let reading = clock(at: distanceMeters, anchors: anchors, legs: legs)
        let distance = formatDistance(distanceMeters, usesMetric: usesMetric)
        let riding = formatDuration(reading.cumulative)
        let since = formatDuration(reading.sincePrevious)
        let relation = reading.sinceDeparture ? "since departure" : "since last"
        return "\(distance) · \(riding) riding (\(since) \(relation))"
    }

    private static func finite(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, value)
    }
}
