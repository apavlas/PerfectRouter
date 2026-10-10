import CoreLocation
import Foundation

/// One drivable shape Twisty can choose from. `distance` is the road
/// distance (from MapKit when a real route is available), used only as a
/// detour cap. Curvature is measured from `coordinates`.
struct TwistyRouteCandidate {
    var id: Int
    var coordinates: [CLLocationCoordinate2D]
    var distance: CLLocationDistance
}

/// A candidate that beat Fastest on curves and left its corridor.
struct TwistySelection: Equatable {
    var candidateID: Int
    var curvatureRadiansPerKilometer: Double
    var fastestCurvatureRadiansPerKilometer: Double
    var corridorSeparationMeters: CLLocationDistance
}

/// Shaping points between a leg's endpoints. These are routing hints, not
/// rider stops, and they are never written into the waypoint list.
struct TwistyCorridor {
    var vias: [CLLocationCoordinate2D]
}

/// Identity of a routed waypoint pair. Same key means the geometry can be
/// reused instead of calling MapKit again.
struct TwistyLegCacheKey: Hashable {
    var startLatitudeE4: Int
    var startLongitudeE4: Int
    var endLatitudeE4: Int
    var endLongitudeE4: Int
    var style: String
    var departureSlot: Int
}

/// Picks a twistier driving line than Fastest.
///
/// MapKit has no motorcycle-curvature preference. Twisty therefore scores
/// polylines it can actually obtain — fastest alternates, non-highway
/// alternates, and routes steered through a point off the fast corridor —
/// and keeps one only when it has more significant turning *and* rides a
/// different corridor, within a distance cap. A longer straight detour
/// (what Scenic prefers) does not qualify.
enum TwistyRouting {

    /// Extra absolute heading change, in radians per kilometer, required
    /// before a line counts as curvier than Fastest. About 4.6° per km.
    static let minimumCurvatureGainPerKilometer = 0.08

    /// Median distance from the Fastest polyline. Below this, the rider
    /// is still looking at the same corridor.
    static let minimumCorridorSeparationMeters: CLLocationDistance = 700

    /// Longest acceptable road distance as a multiple of the fast route.
    static let maximumDistanceFactor = 1.75

    /// Straight-line length below which an offset corridor isn't worth a
    /// routing probe — the endpoints are already in the same neighborhood.
    static let minimumBiasLegMeters: CLLocationDistance = 8_000

    /// Above this, offset-via probes are skipped. A ~22 km bulge does not
    /// move the median of a multi-hundred-mile line, and each via is another
    /// continental `MKDirections` round trip. Alternates can still win.
    static let maximumViaProbeMeters: CLLocationDistance = 400_000

    /// How far a new endpoint may sit from the already-planned line and still
    /// count as a split of that corridor (fuel stops along the ride).
    static let plannedCorridorSlackMeters: CLLocationDistance = 8_000

    /// Returns the curviest candidate that meaningfully beats `fastestID`.
    /// Nil means nothing qualified — callers must not relabel Fastest.
    static func select(
        candidates: [TwistyRouteCandidate],
        fastestID: Int
    ) -> TwistySelection? {
        guard let fastest = candidates.first(where: { $0.id == fastestID }),
              fastest.distance > 100,
              fastest.coordinates.count >= 2 else { return nil }

        let fastestCurvature = curvatureRadiansPerKilometer(fastest.coordinates)
        let distanceLimit = fastest.distance * maximumDistanceFactor
        var best: (candidate: TwistyRouteCandidate, curvature: Double, separation: CLLocationDistance)?

        for candidate in candidates where candidate.id != fastestID {
            guard candidate.coordinates.count >= 2,
                  candidate.distance.isFinite,
                  candidate.distance <= distanceLimit else { continue }

            let curvature = curvatureRadiansPerKilometer(candidate.coordinates)
            let separation = corridorSeparationMeters(
                of: candidate.coordinates,
                from: fastest.coordinates
            )
            guard curvature - fastestCurvature >= minimumCurvatureGainPerKilometer,
                  separation >= minimumCorridorSeparationMeters else { continue }

            if let current = best {
                let curvier = curvature > current.curvature + 1e-6
                let tiedAndShorter = abs(curvature - current.curvature) <= 1e-6
                    && candidate.distance < current.candidate.distance
                if curvier || tiedAndShorter {
                    best = (candidate, curvature, separation)
                }
            } else {
                best = (candidate, curvature, separation)
            }
        }

        guard let best else { return nil }
        return TwistySelection(
            candidateID: best.candidate.id,
            curvatureRadiansPerKilometer: best.curvature,
            fastestCurvatureRadiansPerKilometer: fastestCurvature,
            corridorSeparationMeters: best.separation
        )
    }

    /// Absolute significant heading change per kilometer.
    ///
    /// Points are spaced to about 100 m so a dense MapKit trace doesn't
    /// turn coordinate noise into fake curves. Heading changes under 4°
    /// are ignored, which drops gentle freeway bends and keeps switchbacks
    /// and tight secondary roads.
    static func curvatureRadiansPerKilometer(_ coordinates: [CLLocationCoordinate2D]) -> Double {
        let points = spaced(coordinates, minimumMeters: 100)
        guard points.count >= 3 else { return 0 }

        let minimumTurn = 4.0 * Double.pi / 180
        var turn = 0.0
        var length = 0.0
        var previousBearing: Double?

        for index in 1..<points.count {
            let step = meters(from: points[index - 1], to: points[index])
            guard step >= 40 else { continue }
            let bearing = bearingRadians(from: points[index - 1], to: points[index])
            if let previousBearing {
                let delta = signedTurn(bearing - previousBearing)
                if abs(delta) >= minimumTurn {
                    turn += abs(delta)
                }
            }
            previousBearing = bearing
            length += step
        }

        let kilometers = length / 1_000
        guard kilometers >= 0.5 else { return 0 }
        return turn / kilometers
    }

    /// Median sample distance from `candidate` to `baseline`. Endpoints are
    /// skipped because every A→B route shares them.
    static func corridorSeparationMeters(
        of candidate: [CLLocationCoordinate2D],
        from baseline: [CLLocationCoordinate2D]
    ) -> CLLocationDistance {
        let length = pathLength(candidate)
        guard length > 100, baseline.count >= 2 else { return 0 }

        let fractions = [0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
        let samples = fractions.map { fraction in
            let point = coordinate(at: length * fraction, along: candidate)
            return RouteGeometry.distanceFromRoute(of: point, alongPolylines: [baseline])
        }
        return median(samples)
    }

    /// Offset corridors on either side of the A→B chord. On longer legs the
    /// two vias sit on the same side so the middle of the ride can leave
    /// the fast corridor instead of spiking out and back at one point.
    static func biasCorridors(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> [TwistyCorridor] {
        let straight = meters(from: start, to: end)
        guard straight >= minimumBiasLegMeters else { return [] }

        let offset = min(22_000, max(4_000, straight * 0.15))
        let fractions: [Double] = straight >= 40_000 ? [0.33, 0.67] : [0.5]
        return [1.0, -1.0].map { sign in
            let vias = fractions.map { fraction in
                let anchor = interpolate(from: start, to: end, fraction: fraction)
                return coordinate(
                    offsetMeters: offset * sign,
                    perpendicularTo: start,
                    end,
                    from: anchor
                )
            }
            return TwistyCorridor(vias: vias)
        }
    }

    /// What extra MapKit work a Twisty leg is worth.
    ///
    /// Splits of an already-planned corridor (a fuel stop on the line) get
    /// one alternate request and no via cascade. Very long fresh legs still
    /// compare highway and non-highway alternates, but skip offset vias.
    /// A fresh medium leg probes vias until one corridor qualifies.
    static func fetchPlan(
        straightMeters: CLLocationDistance,
        liesOnPlannedCorridor: Bool
    ) -> (avoidHighwayAlternates: Bool, offsetVias: Bool) {
        if liesOnPlannedCorridor {
            return (false, false)
        }
        if straightMeters > maximumViaProbeMeters {
            return (true, false)
        }
        return (true, true)
    }

    /// A leg split out of the route already on screen (a fuel stop on that
    /// line). The original A→B, whose ends are the corridor ends, is not a
    /// split — switching style must still run a real Twisty probe.
    static func liesOnPlannedCorridor(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        polylines: [[CLLocationCoordinate2D]],
        slackMeters: CLLocationDistance = plannedCorridorSlackMeters
    ) -> Bool {
        guard let corridorStart = polylines.first?.first,
              let corridorEnd = polylines.last?.last else { return false }
        let startGap = RouteGeometry.distanceFromRoute(of: start, alongPolylines: polylines)
        let endGap = RouteGeometry.distanceFromRoute(of: end, alongPolylines: polylines)
        guard startGap <= slackMeters, endGap <= slackMeters else { return false }
        let startIsEnd = meters(from: start, to: corridorStart) <= slackMeters
            || meters(from: start, to: corridorEnd) <= slackMeters
        let endIsEnd = meters(from: end, to: corridorStart) <= slackMeters
            || meters(from: end, to: corridorEnd) <= slackMeters
        return !(startIsEnd && endIsEnd)
    }

    /// Stable identity for a routed leg so an unchanged A→B pair is not
    /// probed again. Coordinates are rounded to about 11 m.
    static func legCacheKey(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        style: RouteStyle,
        departure: Date
    ) -> TwistyLegCacheKey {
        TwistyLegCacheKey(
            startLatitudeE4: roundedE4(start.latitude),
            startLongitudeE4: roundedE4(start.longitude),
            endLatitudeE4: roundedE4(end.latitude),
            endLongitudeE4: roundedE4(end.longitude),
            style: style.rawValue,
            departureSlot: Int(departure.timeIntervalSince1970 / 300)
        )
    }

    private static func roundedE4(_ degrees: CLLocationDegrees) -> Int {
        Int((degrees * 10_000).rounded())
    }

    // MARK: - Geometry

    static func pathLength(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            total += meters(from: coordinates[index - 1], to: coordinates[index])
        }
        return total
    }

    private static func spaced(
        _ coordinates: [CLLocationCoordinate2D],
        minimumMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        guard let first = coordinates.first else { return [] }
        var result = [first]
        for point in coordinates.dropFirst() {
            if meters(from: result[result.count - 1], to: point) >= minimumMeters {
                result.append(point)
            }
        }
        if let last = coordinates.last,
           meters(from: result[result.count - 1], to: last) >= 40,
           (last.latitude != result[result.count - 1].latitude
            || last.longitude != result[result.count - 1].longitude) {
            result.append(last)
        }
        return result
    }

    private static func median(_ values: [CLLocationDistance]) -> CLLocationDistance {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    private static func coordinate(
        at distance: CLLocationDistance,
        along coordinates: [CLLocationCoordinate2D]
    ) -> CLLocationCoordinate2D {
        guard let first = coordinates.first else {
            return CLLocationCoordinate2D(latitude: 0, longitude: 0)
        }
        guard distance > 0, coordinates.count >= 2 else { return first }

        var walked: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            let previous = coordinates[index - 1]
            let next = coordinates[index]
            let step = meters(from: previous, to: next)
            if step > 0, walked + step >= distance {
                let t = (distance - walked) / step
                return CLLocationCoordinate2D(
                    latitude: previous.latitude + t * (next.latitude - previous.latitude),
                    longitude: previous.longitude + t * (next.longitude - previous.longitude)
                )
            }
            walked += step
        }
        return coordinates[coordinates.count - 1]
    }

    private static func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        fraction: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    /// Positive `meters` is left of travel; negative is right.
    private static func coordinate(
        offsetMeters: CLLocationDistance,
        perpendicularTo start: CLLocationCoordinate2D,
        _ end: CLLocationCoordinate2D,
        from point: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let travel = bearingRadians(from: start, to: end)
        let side = travel + (offsetMeters >= 0 ? -.pi / 2 : .pi / 2)
        return destination(from: point, bearing: side, meters: abs(offsetMeters))
    }

    private static func destination(
        from start: CLLocationCoordinate2D,
        bearing: Double,
        meters: CLLocationDistance
    ) -> CLLocationCoordinate2D {
        let earth = 6_371_000.0
        let angular = meters / earth
        let lat1 = start.latitude * .pi / 180
        let lon1 = start.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(
            sin(bearing) * sin(angular) * cos(lat1),
            cos(angular) - sin(lat1) * sin(lat2)
        )
        return CLLocationCoordinate2D(
            latitude: lat2 * 180 / .pi,
            longitude: lon2 * 180 / .pi
        )
    }

    private static func bearingRadians(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLon)
        return atan2(y, x)
    }

    private static func signedTurn(_ delta: Double) -> Double {
        var turn = delta
        let circle = Double.pi * 2
        while turn > .pi { turn -= circle }
        while turn < -.pi { turn += circle }
        return turn
    }

    private static func meters(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }
}
