import CoreLocation
import Foundation

/// How the Suggested Gas list is cut into riding days and fuel legs.
///
/// A fuel leg is the stretch from one recommended fill to the next. The
/// recommended stop is the end of that leg. A leg that runs past an overnight
/// stays on the day where it starts. One leg has no day or leg chrome: the
/// stations stay one list, the way a short ride already showed them.
///
/// This is a value, not a namespace: the grouped days are stored on it.
struct GasListGrouping: Equatable {

    /// The two alternates kept beside the recommended stop before Show more.
    static let nearestAlternateCount = 2

    struct Station: Equatable, Identifiable {
        var id: UUID
        var name: String
        var distance: CLLocationDistance
        var isRecommended: Bool
        var pastRange: Bool
    }

    /// Planned evening, in meters along the route. The arrival day is included.
    struct DaySpan: Equatable {
        var dayNumber: Int
        var start: CLLocationDistance
        var end: CLLocationDistance
    }

    struct Leg: Equatable, Identifiable {
        var number: Int
        var dayNumber: Int
        /// Where this tank window opens. The day is chosen from this mile.
        var startDistance: CLLocationDistance
        /// Recommended fill, or the leg start when the window has no pick.
        var markerDistance: CLLocationDistance
        var title: String
        /// Recommended stop, then up to two nearest alternates.
        var preview: [Station]
        /// The rest of the leg, in ride order. Shown after Show more.
        var overflow: [Station]
        var pastRange: Bool

        var id: Int { number }

        var stationCount: Int { preview.count + overflow.count }
    }

    struct Day: Equatable, Identifiable {
        var dayNumber: Int
        var legs: [Leg]

        var id: Int { dayNumber }

        var pastRange: Bool { legs.contains(where: \.pastRange) }
    }

    enum Row: Equatable, Identifiable {
        case dayHeader(Day)
        case legHeader(Leg)
        case station(Station)
        case showMore(legNumber: Int, expanded: Bool)

        var id: String {
            switch self {
            case .dayHeader(let day):
                return "day-\(day.dayNumber)"
            case .legHeader(let leg):
                return "leg-\(leg.number)"
            case .station(let station):
                return "station-\(station.id.uuidString)"
            case .showMore(let legNumber, _):
                return "more-\(legNumber)"
            }
        }
    }

    var days: [Day]
    /// Two or more riding days. A one-day ride has no Day rows.
    var showsDayHeaders: Bool
    /// Two or more fuel legs. A single leg is the plain station list.
    var showsLegHeaders: Bool
    var stationCount: Int
    var pastRange: Bool

    /// "Leg 3 · ~498 mi". The mile is the recommended fill. A leg with no
    /// pick uses the end of its window, so it does not repeat the previous fill.
    static func legTitle(
        number: Int,
        markerMeters: CLLocationDistance,
        usesMetric: Bool
    ) -> String {
        let distance = FuelStopRidingTime.formatDistance(markerMeters, usesMetric: usesMetric)
        return "Leg \(number) · ~\(distance)"
    }

    static func legAccessibilityLabel(title: String, pastRange: Bool) -> String {
        guard pastRange else { return title }
        return "\(title), Past your range"
    }

    /// Rows under the gas header. A collapsed list, day, or Show more omits
    /// the stations it is hiding and does not drop the header those stations
    /// belong to.
    func visibleRows(
        listExpanded: Bool,
        collapsedDays: Set<Int>,
        overflowLegs: Set<Int>
    ) -> [Row] {
        guard listExpanded else { return [] }
        var rows: [Row] = []
        for day in days {
            if showsDayHeaders {
                rows.append(.dayHeader(day))
            }
            let dayOpen = !showsDayHeaders || !collapsedDays.contains(day.dayNumber)
            guard dayOpen else { continue }
            for leg in day.legs {
                if showsLegHeaders {
                    rows.append(.legHeader(leg))
                }
                let showOverflow = showsLegHeaders
                    && !leg.overflow.isEmpty
                    && overflowLegs.contains(leg.number)
                let stations = showOverflow ? leg.preview + leg.overflow : leg.preview
                for station in stations {
                    rows.append(.station(station))
                }
                if showsLegHeaders, !leg.overflow.isEmpty {
                    rows.append(.showMore(legNumber: leg.number, expanded: showOverflow))
                }
            }
        }
        return rows
    }

    static func make(
        stations: [Station],
        fillDistances: [CLLocationDistance],
        daySpans: [DaySpan],
        totalDistance: CLLocationDistance,
        usesMetric: Bool
    ) -> GasListGrouping {
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        let finite = stations.filter { $0.distance.isFinite }
        let farthest = finite.map(\.distance).max() ?? 0
        let routeEnd = max(totalDistance.isFinite ? totalDistance : 0, farthest)
        var edges: [CLLocationDistance] = [0]
        for fill in fillDistances.sorted() where fill.isFinite {
            guard fill > tolerance, fill + tolerance < routeEnd || fill <= routeEnd else { continue }
            guard let last = edges.last, fill > last + tolerance else { continue }
            guard fill + tolerance < routeEnd else { continue }
            edges.append(fill)
        }
        if routeEnd > (edges.last ?? 0) + tolerance {
            edges.append(routeEnd)
        }

        var buckets = Array(repeating: [Station](), count: max(edges.count - 1, 0))
        for station in finite.sorted(by: { $0.distance < $1.distance }) {
            guard let index = bucketIndex(for: station.distance, edges: edges, tolerance: tolerance) else {
                continue
            }
            buckets[index].append(station)
        }

        var legs: [Leg] = []
        for index in buckets.indices where !buckets[index].isEmpty {
            let start = edges[index]
            let end = edges[index + 1]
            let number = legs.count + 1
            let built = leg(
                number: number,
                start: start,
                end: end,
                stations: buckets[index],
                dayNumber: dayNumber(for: start, spans: daySpans, tolerance: tolerance),
                usesMetric: usesMetric
            )
            legs.append(built)
        }

        let multipleLegs = legs.count >= 2
        if !multipleLegs, let only = legs.first {
            let ordered = (only.preview + only.overflow).sorted { $0.distance < $1.distance }
            legs = [
                Leg(
                    number: only.number,
                    dayNumber: only.dayNumber,
                    startDistance: only.startDistance,
                    markerDistance: only.markerDistance,
                    title: only.title,
                    preview: ordered,
                    overflow: [],
                    pastRange: only.pastRange
                )
            ]
        }

        var days: [Day] = []
        for leg in legs {
            if let last = days.indices.last, days[last].dayNumber == leg.dayNumber {
                days[last].legs.append(leg)
            } else {
                days.append(Day(dayNumber: leg.dayNumber, legs: [leg]))
            }
        }

        let placed = legs.reduce(0) { $0 + $1.stationCount }
        return GasListGrouping(
            days: days,
            showsDayHeaders: daySpans.count >= 2 && !days.isEmpty,
            showsLegHeaders: multipleLegs,
            stationCount: placed,
            pastRange: legs.contains(where: \.pastRange)
        )
    }

    private static func leg(
        number: Int,
        start: CLLocationDistance,
        end: CLLocationDistance,
        stations: [Station],
        dayNumber: Int,
        usesMetric: Bool
    ) -> Leg {
        let recommended = stations
            .filter(\.isRecommended)
            .min { abs($0.distance - end) < abs($1.distance - end) }
        let anchor = recommended?.distance ?? end
        let alternates = stations.filter { station in
            guard let recommended else { return true }
            return station.id != recommended.id
        }
        let nearest = alternates.sorted { lhs, rhs in
            let left = abs(lhs.distance - anchor)
            let right = abs(rhs.distance - anchor)
            if abs(left - right) > 1 { return left < right }
            return lhs.distance < rhs.distance
        }
        let kept = Array(nearest.prefix(nearestAlternateCount))
        let keptIDs = Set(kept.map(\.id))
        var preview: [Station] = []
        if let recommended {
            preview.append(recommended)
        }
        preview.append(contentsOf: kept.sorted { $0.distance < $1.distance })
        let overflow = alternates
            .filter { !keptIDs.contains($0.id) }
            .sorted { $0.distance < $1.distance }
        let marker = recommended?.distance ?? end
        return Leg(
            number: number,
            dayNumber: dayNumber,
            startDistance: start,
            markerDistance: marker,
            title: legTitle(number: number, markerMeters: marker, usesMetric: usesMetric),
            preview: preview,
            overflow: overflow,
            pastRange: stations.contains(where: \.pastRange)
        )
    }

    /// First window includes the origin. Later windows start after the fill
    /// that closed the previous one, so the recommended stop stays in the
    /// leg that ends on it.
    private static func bucketIndex(
        for distance: CLLocationDistance,
        edges: [CLLocationDistance],
        tolerance: CLLocationDistance
    ) -> Int? {
        guard edges.count >= 2 else { return nil }
        for index in 0..<(edges.count - 1) {
            let start = edges[index]
            let end = edges[index + 1]
            let opens = index == 0 ? distance >= start - tolerance : distance > start + tolerance
            if opens, distance <= end + tolerance {
                return index
            }
        }
        return nil
    }

    /// The day whose morning contains `distance`. A mile that lands on an
    /// overnight belongs to the day that starts there.
    private static func dayNumber(
        for distance: CLLocationDistance,
        spans: [DaySpan],
        tolerance: CLLocationDistance
    ) -> Int {
        let ordered = spans.sorted { $0.start < $1.start }
        guard let first = ordered.first else { return 1 }
        for span in ordered {
            let opens = distance >= span.start - tolerance
            let beforeEnd = distance < span.end - tolerance
            if opens, beforeEnd { return span.dayNumber }
        }
        return ordered.last?.dayNumber ?? first.dayNumber
    }
}

/// Open and closed sections for one ride. A nil override means "use the
/// default": gas and food start open until a stop of that kind is on the
/// route, highlights start open. Toggles replace the override so a replan
/// does not put a section back.
struct ListDisclosureMemory: Equatable {
    var gasOverride: Bool?
    var foodOverride: Bool?
    var highlightsOverride: Bool?
    var collapsedDays: Set<Int>
    var overflowLegs: Set<Int>

    init() {
        gasOverride = nil
        foodOverride = nil
        highlightsOverride = nil
        collapsedDays = []
        overflowLegs = []
    }

    func gasExpanded(fuelApplied: Bool) -> Bool {
        gasOverride ?? !fuelApplied
    }

    func foodExpanded(foodApplied: Bool) -> Bool {
        foodOverride ?? !foodApplied
    }

    func highlightsExpanded() -> Bool {
        highlightsOverride ?? true
    }

    mutating func toggleGas(fuelApplied: Bool) {
        gasOverride = !gasExpanded(fuelApplied: fuelApplied)
    }

    mutating func toggleFood(foodApplied: Bool) {
        foodOverride = !foodExpanded(foodApplied: foodApplied)
    }

    mutating func toggleHighlights() {
        highlightsOverride = !highlightsExpanded()
    }

    func dayExpanded(_ day: Int) -> Bool {
        !collapsedDays.contains(day)
    }

    mutating func toggleDay(_ day: Int) {
        if collapsedDays.contains(day) {
            collapsedDays.remove(day)
        } else {
            collapsedDays.insert(day)
        }
    }

    func overflowExpanded(_ leg: Int) -> Bool {
        overflowLegs.contains(leg)
    }

    mutating func toggleOverflow(_ leg: Int) {
        if overflowLegs.contains(leg) {
            overflowLegs.remove(leg)
        } else {
            overflowLegs.insert(leg)
        }
    }

    mutating func reset() {
        self = ListDisclosureMemory()
    }
}

/// Titles and VoiceOver labels shared by the gas, food, and highlights headers.
enum CollapsibleListCopy {
    static func gasTitle(count: Int) -> String { "Suggested Gas Stops (\(count))" }
    static func foodTitle(count: Int) -> String { "Food (\(count))" }
    static func highlightsTitle(count: Int) -> String { "Highlights (\(count))" }
    static func dayTitle(_ day: Int) -> String { "Day \(day)" }

    static func stateLabel(title: String, expanded: Bool, pastRange: Bool = false) -> String {
        var label = "\(title), \(expanded ? "expanded" : "collapsed")"
        if pastRange, !expanded {
            label += ", Past your range"
        }
        return label
    }

    static func showMoreTitle(expanded: Bool) -> String {
        expanded ? "Show less" : "Show more"
    }
}
