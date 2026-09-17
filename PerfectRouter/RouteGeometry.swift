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
    private static func nearestProjection(
        of coordinate: CLLocationCoordinate2D,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> NearestProjection? {
        var best: NearestProjection?
        var cumulative: CLLocationDistance = 0

        for coords in polylines {
            guard coords.count > 1 else { continue }

            for i in 1..<coords.count {
                let a = coords[i - 1]
                let b = coords[i]
                let segmentMeters = CLLocation(latitude: a.latitude, longitude: a.longitude)
                    .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))

                // Local planar projection centered on this segment.
                let latRef = ((a.latitude + b.latitude) / 2) * .pi / 180
                let kx = cos(latRef)
                let ax = a.longitude * kx, ay = a.latitude
                let bx = b.longitude * kx, by = b.latitude
                let px = coordinate.longitude * kx, py = coordinate.latitude

                let dx = bx - ax, dy = by - ay
                let segLengthSquared = dx * dx + dy * dy

                // Closest point on segment a→b to the coordinate (clamped).
                var t = 0.0
                if segLengthSquared > 0 {
                    t = ((px - ax) * dx + (py - ay) * dy) / segLengthSquared
                    t = max(0, min(1, t))
                }
                let cx = ax + t * dx, cy = ay + t * dy
                let distanceSquared = (px - cx) * (px - cx) + (py - cy) * (py - cy)

                if best == nil || distanceSquared < best!.distanceSquared {
                    // Cross product of travel direction (d) and vector to point (v).
                    let vx = px - ax, vy = py - ay
                    best = NearestProjection(
                        distanceSquared: distanceSquared,
                        distanceAlong: cumulative + t * segmentMeters,
                        cross: dx * vy - dy * vx,
                        point: CLLocationCoordinate2D(
                            latitude: cy,
                            longitude: kx != 0 ? cx / kx : a.longitude
                        )
                    )
                }

                cumulative += segmentMeters
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
