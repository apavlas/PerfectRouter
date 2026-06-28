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

    /// Right-hand traffic: a rider travelling forward pulls off to the *right*
    /// to reach a stop without crossing oncoming lanes. Flip this for
    /// left-hand-traffic regions.
    static let drivesOnRight = true

    /// The side of travel a rider must turn toward to reach `coordinate`.
    ///
    /// Finds the nearest segment of the route, then uses the signed cross
    /// product of the segment's travel direction and the vector to the point.
    /// Distances are compared in a local equirectangular projection (longitude
    /// scaled by cos(latitude)), which is accurate at the scale of a road
    /// corridor.
    static func side(of coordinate: CLLocationCoordinate2D, along legs: [MKRoute]) -> RoadSide {
        var nearestDistanceSquared = Double.greatestFiniteMagnitude
        var nearestCross = 0.0
        var found = false

        for route in legs {
            let polyline = route.polyline
            let count = polyline.pointCount
            guard count > 1 else { continue }

            var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))

            for i in 1..<count {
                let a = coords[i - 1]
                let b = coords[i]

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

                if distanceSquared < nearestDistanceSquared {
                    nearestDistanceSquared = distanceSquared
                    // Cross product of travel direction (d) and vector to point (v).
                    // Positive => point is to the left of travel; negative => right.
                    let vx = px - ax, vy = py - ay
                    nearestCross = dx * vy - dy * vx
                    found = true
                }
            }
        }

        guard found, abs(nearestCross) > 1e-12 else { return .unknown }
        return nearestCross < 0 ? .right : .left
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
        var nearestDistanceSquared = Double.greatestFiniteMagnitude
        var bestDistanceAlong: CLLocationDistance = 0
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

                if distanceSquared < nearestDistanceSquared {
                    nearestDistanceSquared = distanceSquared
                    bestDistanceAlong = cumulative + t * segmentMeters
                }

                cumulative += segmentMeters
            }
        }

        return bestDistanceAlong
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
        switch side(of: coordinate, along: legs) {
        case .unknown:
            return true
        case .right:
            return drivesOnRight
        case .left:
            return !drivesOnRight
        }
    }
}
