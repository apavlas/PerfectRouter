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
    private static func measuredSegments(
        of polylines: [[CLLocationCoordinate2D]]
    ) -> [MeasuredSegment] {
        var segments: [MeasuredSegment] = []
        var cumulative: CLLocationDistance = 0
        for coords in polylines {
            guard coords.count > 1 else { continue }
            let locations = coords.map {
                CLLocation(latitude: $0.latitude, longitude: $0.longitude)
            }
            for index in 1..<coords.count {
                let a = coords[index - 1]
                let b = coords[index]
                let segmentMeters = locations[index - 1].distance(from: locations[index])
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
