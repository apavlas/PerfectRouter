import Foundation
import MapKit

/// Which side of the direction of travel a point lies on.
enum RoadSide {
    case right
    case left
    /// Effectively on the route line itself (or no route to compare against).
    case unknown
}

/// Geometry helpers for reasoning about points relative to a planned route.
enum RouteGeometry {

    /// Left-hand-traffic regions (ISO codes). A rider there pulls off to the
    /// *left* to reach a stop without crossing oncoming lanes.
    static let leftHandTrafficRegions: Set<String> = [
        "AG", "AU", "BB", "BD", "BN", "BS", "BT", "BW", "CY", "DM", "FJ", "GB",
        "GD", "GY", "HK", "ID", "IE", "IN", "JM", "JP", "KE", "KN", "LC", "LK",
        "LS", "MO", "MT", "MU", "MV", "MW", "MY", "MZ", "NA", "NP", "NZ", "PG",
        "PK", "SC", "SG", "SR", "SZ", "TH", "TL", "TT", "TZ", "UG", "VC", "ZA",
        "ZM", "ZW",
    ]

    /// Which side of the road the rider's region drives on. Right-hand traffic
    /// means pulling off to the *right* to reach a stop without crossing
    /// oncoming lanes; left-hand regions (UK, Japan, Australia, …) flip this.
    static let drivesOnRight: Bool = {
        guard let region = Locale.current.region?.identifier else { return true }
        return !leftHandTrafficRegions.contains(region)
    }()

    /// The side of travel a rider must turn toward to reach `coordinate`.
    ///
    /// Finds the nearest segment of the route, then uses the signed cross
    /// product of the segment's travel direction and the vector to the point.
    /// Distances are compared in a local equirectangular projection (longitude
    /// scaled by cos(latitude)), which is accurate at the scale of a road
    /// corridor.
    static func side(of coordinate: CLLocationCoordinate2D, along legs: [MKRoute]) -> RoadSide {
        side(of: coordinate, alongPolylines: legs.map { coordinates(of: $0.polyline) })
    }

    /// Pure-geometry core of `side(of:along:)`, taking raw polyline coordinate
    /// arrays (one per leg) instead of `MKRoute`s so it can be unit-tested
    /// without constructing routes.
    static func side(
        of coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> RoadSide {
        guard let nearest = nearestProjection(of: coordinate, alongPolylines: polylines),
              abs(nearest.cross) > 1e-12 else { return .unknown }
        return nearest.cross < 0 ? .right : .left
    }

    /// How far along the route (meters from the ride start) the point nearest
    /// to `coordinate` sits.
    ///
    /// Finds the closest segment of the route, projects the point onto it, and
    /// returns the cumulative distance to that projected position. Unlike
    /// snapping to a coarse sample point, this gives the stop's true position
    /// along the route, so fuel-stop spacing and "X mi from start" labels are
    /// accurate. Returns 0 if there's no usable route geometry.
    static func distanceAlongRoute(of coordinate: CLLocationCoordinate2D, along legs: [MKRoute]) -> CLLocationDistance {
        distanceAlongRoute(of: coordinate, alongPolylines: legs.map { coordinates(of: $0.polyline) })
    }

    /// Pure-geometry core of `distanceAlongRoute(of:along:)`, taking raw
    /// polyline coordinate arrays (one per leg) instead of `MKRoute`s so it can
    /// be unit-tested without constructing routes.
    static func distanceAlongRoute(
        of coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> CLLocationDistance {
        nearestProjection(of: coordinate, alongPolylines: polylines)?.distanceAlong ?? 0
    }

    /// A projection of a few hundred feet is the route origin, or a polyline
    /// read that collapsed. `known` is a mile mark already measured along the
    /// route (the search sample, or the distance stored on the stop). Prefer
    /// that over labeling a distant station "~400 ft from start".
    static func preferredDistanceAlongRoute(
        projected: CLLocationDistance,
        known: CLLocationDistance
    ) -> CLLocationDistance {
        let footScale: CLLocationDistance = 250
        if projected < footScale, known >= AppSettings.metersPerMile {
            return known
        }
        return projected
    }

    /// The straight-line distance (meters) from `coordinate` to the nearest
    /// point on the route — i.e. how far off-route a stop sits, the detour a
    /// rider takes to reach it. Returns 0 when there's no usable route geometry.
    static func distanceFromRoute(
        of coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> CLLocationDistance {
        guard let nearest = nearestProjection(of: coordinate, alongPolylines: polylines) else {
            return 0
        }
        return CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            .distance(from: CLLocation(latitude: nearest.point.latitude,
                                       longitude: nearest.point.longitude))
    }

    /// Polyline length in meters, summing the same segment distances
    /// `distanceAlongRoute` uses. A stop's `distanceAlongRoute` and a leg's
    /// length therefore share one ruler, which riding-time interpolation needs.
    static func length(of coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count > 1 else { return 0 }
        var total: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            let start = coordinates[index - 1]
            let end = coordinates[index]
            total += CLLocation(latitude: start.latitude, longitude: start.longitude)
                .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
        }
        return total
    }

    /// The coordinate `distance` meters along `polylines`, using the same
    /// segment lengths as `length(of:)`. The hotel search centers on this
    /// point. Nil only when the route has no coordinate at all.
    static func coordinate(
        atDistance distance: CLLocationDistance,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> CLLocationCoordinate2D? {
        guard distance.isFinite else { return nil }
        var remaining = max(0, distance)
        var fallback: CLLocationCoordinate2D?
        for line in polylines {
            guard let first = line.first else { continue }
            fallback = first
            guard line.count > 1 else { continue }
            for index in 1..<line.count {
                let start = line[index - 1]
                let end = line[index]
                fallback = end
                let span = CLLocation(latitude: start.latitude, longitude: start.longitude)
                    .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
                if span <= 0 { continue }
                if remaining <= span {
                    let fraction = remaining / span
                    return CLLocationCoordinate2D(
                        latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                        longitude: start.longitude + (end.longitude - start.longitude) * fraction
                    )
                }
                remaining -= span
            }
        }
        return fallback
    }

    // MARK: - Nearest-segment scan (shared core)

    /// Everything about the route point nearest to a coordinate. Produced by
    /// one scan and consumed by `side`, `distanceAlongRoute`, and
    /// `distanceFromRoute`, so the projection logic lives in exactly one place.
    private struct NearestProjection {
        /// Squared distance in projected degree-space — for comparison only.
        var distanceSquared: Double
        /// Cumulative route distance (meters) to the projected point.
        var distanceAlong: CLLocationDistance
        /// Cross product of travel direction and vector to the coordinate.
        /// Positive => coordinate is left of travel; negative => right.
        var cross: Double
        /// The projected point, back in geographic coordinates.
        var point: CLLocationCoordinate2D
    }

    /// Finds the point on the route nearest to `coordinate` by scanning every
    /// polyline segment. Distances are compared in a local equirectangular
    /// projection (longitude scaled by cos(latitude)), which is accurate at
    /// the scale of a road corridor. Returns `nil` if there's no usable
    /// route geometry.
    /// One route, measured once. Select recommended asks which side of the
    /// road hundreds of stations are on. Building this per station copied
    /// the coast-to-coast polyline and allocated a `CLLocation` per vertex
    /// every time, which kept the main thread busy for more than a minute.
    struct MeasuredRoute: Sendable {
        fileprivate var segments: [MeasuredSegment]

        init(polylines: [[CLLocationCoordinate2D]]) {
            segments = RouteGeometry.measuredSegments(of: polylines)
        }
    }

    /// A station reduced to the fields the side check needs, so the scan
    /// can leave the main thread without touching `MKMapItem`.
    struct StationProjectionQuery: Sendable {
        var index: Int
        var latitude: Double
        var longitude: Double
    }

    /// Indices of `queries` that sit on the rider's side of `polylines`.
    /// The polyline is measured once for the whole set.
    static func travelSideIndices(
        queries: [StationProjectionQuery],
        polylines: [[CLLocationCoordinate2D]],
        drivesOnRight: Bool = drivesOnRight
    ) -> [Int] {
        let route = MeasuredRoute(polylines: polylines)
        return queries.compactMap { query in
            let coordinate = CLLocationCoordinate2D(latitude: query.latitude, longitude: query.longitude)
            guard isOnTravelSide(coordinate, on: route, drivesOnRight: drivesOnRight) else { return nil }
            return query.index
        }
    }

    static func isOnTravelSide(
        _ coordinate: CLLocationCoordinate2D,
        on route: MeasuredRoute,
        drivesOnRight: Bool = drivesOnRight
    ) -> Bool {
        switch side(of: coordinate, on: route) {
        case .unknown:
            return true
        case .right:
            return drivesOnRight
        case .left:
            return !drivesOnRight
        }
    }

    static func side(
        of coordinate: CLLocationCoordinate2D,
        on route: MeasuredRoute
    ) -> RoadSide {
        guard let nearest = nearestProjection(of: coordinate, on: route),
              abs(nearest.cross) > 1e-12 else { return .unknown }
        return nearest.cross < 0 ? .right : .left
    }

    static func distanceAlongRoute(
        of coordinate: CLLocationCoordinate2D,
        on route: MeasuredRoute
    ) -> CLLocationDistance {
        nearestProjection(of: coordinate, on: route)?.distanceAlong ?? 0
    }

    /// Same visibility as `MeasuredRoute.segments`. A private nested type
    /// cannot be the type of a fileprivate stored property.
    fileprivate struct MeasuredSegment: Sendable {
        var kx: Double
        var ax: Double
        var ay: Double
        var bx: Double
        var by: Double
        var dx: Double
        var dy: Double
        var lengthSquared: Double
        var lengthMeters: CLLocationDistance
        var cumulativeStart: CLLocationDistance
        var aLongitude: Double
    }

    /// Vertex distances are measured once per route. Later queries only do
    /// the planar projection.
    /// WGS-84 ellipsoidal distance (Vincenty inverse), pure Swift.
    /// `CLLocation.distance(from:)` returns different values when called
    /// from several threads at once, so the off-main mile-mark scan and the
    /// main-actor projection disagreed by tens of meters run to run.
    nonisolated static func geodesicMeters(
        _ p1: CLLocationCoordinate2D,
        _ p2: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let a = 6_378_137.0
        let f = 1 / 298.257223563
        let b = (1 - f) * a
        let rad = Double.pi / 180
        let L = (p2.longitude - p1.longitude) * rad
        let U1 = atan((1 - f) * tan(p1.latitude * rad))
        let U2 = atan((1 - f) * tan(p2.latitude * rad))
        let sinU1 = sin(U1), cosU1 = cos(U1), sinU2 = sin(U2), cosU2 = cos(U2)
        var lambda = L
        var sinSigma = 0.0, cosSigma = 0.0, sigma = 0.0, cosSqAlpha = 0.0, cos2SigmaM = 0.0
        for _ in 0..<200 {
            let sinLambda = sin(lambda), cosLambda = cos(lambda)
            let t1 = cosU2 * sinLambda
            let t2 = cosU1 * sinU2 - sinU1 * cosU2 * cosLambda
            sinSigma = (t1 * t1 + t2 * t2).squareRoot()
            if sinSigma == 0 { return 0 }
            cosSigma = sinU1 * sinU2 + cosU1 * cosU2 * cosLambda
            sigma = atan2(sinSigma, cosSigma)
            let sinAlpha = cosU1 * cosU2 * sinLambda / sinSigma
            cosSqAlpha = 1 - sinAlpha * sinAlpha
            cos2SigmaM = cosSqAlpha != 0 ? cosSigma - 2 * sinU1 * sinU2 / cosSqAlpha : 0
            let C = f / 16 * cosSqAlpha * (4 + f * (4 - 3 * cosSqAlpha))
            let previous = lambda
            lambda = L + (1 - C) * f * sinAlpha
                * (sigma + C * sinSigma * (cos2SigmaM + C * cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)))
            if abs(lambda - previous) < 1e-12 { break }
        }
        let uSq = cosSqAlpha * (a * a - b * b) / (b * b)
        let A = 1 + uSq / 16384 * (4096 + uSq * (-768 + uSq * (320 - 175 * uSq)))
        let B = uSq / 1024 * (256 + uSq * (-128 + uSq * (74 - 47 * uSq)))
        let deltaSigma = B * sinSigma * (cos2SigmaM + B / 4 * (cosSigma * (-1 + 2 * cos2SigmaM * cos2SigmaM)
            - B / 6 * cos2SigmaM * (-3 + 4 * sinSigma * sinSigma) * (-3 + 4 * cos2SigmaM * cos2SigmaM)))
        return b * A * (sigma - deltaSigma)
    }

    private static func measuredSegments(
        of polylines: [[CLLocationCoordinate2D]]
    ) -> [MeasuredSegment] {
        var segments: [MeasuredSegment] = []
        var cumulative: CLLocationDistance = 0
        for coords in polylines {
            guard coords.count > 1 else { continue }
            for index in 1..<coords.count {
                let a = coords[index - 1]
                let b = coords[index]
                let segmentMeters = geodesicMeters(a, b)
                let latRef = ((a.latitude + b.latitude) / 2) * .pi / 180
                let kx = cos(latRef)
                let ax = a.longitude * kx
                let ay = a.latitude
                let bx = b.longitude * kx
                let by = b.latitude
                let dx = bx - ax
                let dy = by - ay
                segments.append(MeasuredSegment(
                    kx: kx,
                    ax: ax,
                    ay: ay,
                    bx: bx,
                    by: by,
                    dx: dx,
                    dy: dy,
                    lengthSquared: dx * dx + dy * dy,
                    lengthMeters: segmentMeters,
                    cumulativeStart: cumulative,
                    aLongitude: a.longitude
                ))
                cumulative += segmentMeters
            }
        }
        return segments
    }

    private static func nearestProjection(
        of coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> NearestProjection? {
        nearestProjection(of: coordinate, on: MeasuredRoute(polylines: polylines))
    }

    private static func nearestProjection(
        of coordinate: CLLocationCoordinate2D,
        on route: MeasuredRoute
    ) -> NearestProjection? {
        var best: NearestProjection?
        for segment in route.segments {
            let px = coordinate.longitude * segment.kx
            let py = coordinate.latitude
            var t = 0.0
            if segment.lengthSquared > 0 {
                t = ((px - segment.ax) * segment.dx + (py - segment.ay) * segment.dy) / segment.lengthSquared
                t = max(0, min(1, t))
            }
            let cx = segment.ax + t * segment.dx
            let cy = segment.ay + t * segment.dy
            let distanceSquared = (px - cx) * (px - cx) + (py - cy) * (py - cy)
            if best == nil || distanceSquared < best!.distanceSquared {
                let vx = px - segment.ax
                let vy = py - segment.ay
                best = NearestProjection(
                    distanceSquared: distanceSquared,
                    distanceAlong: segment.cumulativeStart + t * segment.lengthMeters,
                    cross: segment.dx * vy - segment.dy * vx,
                    point: CLLocationCoordinate2D(
                        latitude: cy,
                        longitude: segment.kx != 0 ? cx / segment.kx : segment.aLongitude
                    )
                )
            }
        }
        return best
    }

    /// Coordinates on the route at each target distance from the start.
    /// Distances past the end of the route are dropped. Used to search for
    /// gas (and food) at tank-interval points instead of a fixed mile grid.
    static func coordinates(
        alongPolylines polylines: [[CLLocationCoordinate2D]],
        atDistances distances: [CLLocationDistance]
    ) -> [CLLocationCoordinate2D] {
        let targets = distances.filter { $0 >= 0 }.sorted()
        guard !targets.isEmpty else { return [] }

        var results: [CLLocationCoordinate2D] = []
        var targetIndex = 0
        var cumulative: CLLocationDistance = 0

        for coords in polylines {
            guard coords.count > 1 else { continue }
            for i in 1..<coords.count {
                let a = coords[i - 1]
                let b = coords[i]
                let segmentMeters = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
                let nextCumulative = cumulative + segmentMeters

                while targetIndex < targets.count && targets[targetIndex] <= nextCumulative {
                    let remaining = targets[targetIndex] - cumulative
                    let t = segmentMeters > 0 ? remaining / segmentMeters : 1
                    results.append(CLLocationCoordinate2D(
                        latitude: a.latitude + t * (b.latitude - a.latitude),
                        longitude: a.longitude + t * (b.longitude - a.longitude)
                    ))
                    targetIndex += 1
                }

                cumulative = nextCumulative
                if targetIndex >= targets.count { return results }
            }
        }
        return results
    }

    /// Extracts a polyline's coordinates into an array.
    static func coordinates(of polyline: MKPolyline) -> [CLLocationCoordinate2D] {
        let count = polyline.pointCount
        guard count > 0 else { return [] }
        var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
        polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))
        return coords
    }

    /// Whether `coordinate` is reachable on the rider's side of travel — i.e.
    /// the side they'd turn off toward, given the region's driving hand.
    /// Points sitting on the route line (`.unknown`) are treated as reachable.
    static func isOnTravelSide(_ coordinate: CLLocationCoordinate2D, along legs: [MKRoute]) -> Bool {
        isOnTravelSide(coordinate, alongPolylines: legs.map { coordinates(of: $0.polyline) })
    }

    /// Polyline-based core of `isOnTravelSide(_:along:)`. The driving hand is
    /// injectable so tests aren't coupled to the machine's region setting.
    static func isOnTravelSide(
        _ coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]],
        drivesOnRight: Bool = drivesOnRight
    ) -> Bool {
        switch side(of: coordinate, alongPolylines: polylines) {
        case .unknown:
            return true
        case .right:
            return drivesOnRight
        case .left:
            return !drivesOnRight
        }
    }
}

/// Camera for one planned ride. Built from the polyline's coordinates so a
/// layout pass can frame the route without reading `MKMapRect` (that rect
/// does not move the camera off user tracking).
struct RouteMapFrame: Equatable {
    var centerLatitude: CLLocationDegrees
    var centerLongitude: CLLocationDegrees
    var latitudeDelta: CLLocationDegrees
    var longitudeDelta: CLLocationDegrees

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: centerLatitude, longitude: centerLongitude)
    }

    var span: MKCoordinateSpan {
        MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
    }

    /// Latitudes still on screen when a bottom sheet covers `fraction` of
    /// the map. The sheet hides the southern part of the camera.
    func visibleLatitudeBounds(bottomObscuredFraction: Double) -> (south: Double, north: Double) {
        let fraction = min(max(bottomObscuredFraction, 0), 0.85)
        let southEdge = centerLatitude - latitudeDelta / 2
        let northEdge = centerLatitude + latitudeDelta / 2
        return (southEdge + fraction * latitudeDelta, northEdge)
    }

    /// "lat,lon" with a fixed decimal point, so a UI test can read the
    /// camera without depending on the locale.
    var accessibilityLabel: String {
        "\(Self.token(centerLatitude)),\(Self.token(centerLongitude))"
    }

    private static func token(_ value: Double) -> String {
        let sign = value < 0 ? "-" : ""
        let scaled = Int((abs(value) * 10_000).rounded())
        let whole = scaled / 10_000
        let fraction = scaled % 10_000
        return "\(sign)\(whole).\(String(format: "%04d", fraction))"
    }
}

/// Fits a route in the map. `bottomObscuredFraction` is the planning sheet
/// (iPhone and iPad portrait). Sidebar layouts — iPad landscape and Mac —
/// pass 0 because the list is beside the map, not on top of it.
enum RouteMapFraming {
    static let marginFraction = 0.15
    /// Keeps a north-south road from collapsing to a hairline of longitude.
    static let minimumSpan: CLLocationDegrees = 0.02

    static func region(
        containing coordinates: [CLLocationCoordinate2D],
        bottomObscuredFraction: Double = 0,
        marginFraction: Double = RouteMapFraming.marginFraction
    ) -> RouteMapFrame? {
        let points = coordinates.filter(\.isValidLocation)
        guard let first = points.first else { return nil }
        var minLat = first.latitude
        var maxLat = first.latitude
        var minLon = first.longitude
        var maxLon = first.longitude
        for point in points.dropFirst() {
            minLat = min(minLat, point.latitude)
            maxLat = max(maxLat, point.latitude)
            minLon = min(minLon, point.longitude)
            maxLon = max(maxLon, point.longitude)
        }

        let margin = min(max(marginFraction, 0), 0.4)
        var latSpan = max(maxLat - minLat, minimumSpan)
        var lonSpan = max(maxLon - minLon, minimumSpan)
        let growth = 1 + margin * 2
        latSpan *= growth
        lonSpan *= growth
        var centerLat = (minLat + maxLat) / 2
        let centerLon = (minLon + maxLon) / 2

        let obscured = min(max(bottomObscuredFraction, 0), 0.85)
        if obscured > 0 {
            // The visible band is the top (1 - obscured) of the map. Widen
            // the latitude span so the padded route fits in that band, then
            // shift the camera south by half the covered fraction.
            latSpan /= (1 - obscured)
            centerLat -= (obscured / 2) * latSpan
        }
        guard centerLat.isFinite, centerLon.isFinite, latSpan > 0, lonSpan > 0 else { return nil }
        return RouteMapFrame(
            centerLatitude: centerLat,
            centerLongitude: centerLon,
            latitudeDelta: latSpan,
            longitudeDelta: lonSpan
        )
    }
}
