import CoreLocation
import Foundation

/// The ride the rider already planned, locked for in-app guidance.
///
/// Vertices are the planned polyline, including selected stops and any via
/// geometry the planner baked into the legs. Navigation projects the rider
/// onto this line. It does not ask for a faster road, and it does not replace
/// these vertices unless the rider explicitly chooses "Reroute from here"
/// and the replacement still passes through the remaining selected stops.
struct PlannedNavigationLine {
    var coordinates: [CLLocationCoordinate2D]
    var stops: [PlannedRouteStop]
    var routeStyleName: String

    var lengthMeters: CLLocationDistance {
        RouteGeometry.length(of: coordinates)
    }
}

/// A named point on the locked line. Selected stops and the destination are
/// required on any explicit reroute. Recommended fuel that was never added
/// as a stop is not.
struct PlannedRouteStop: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case start
        case stop
        case destination
        case fuel
    }

    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    /// Filled in by `PlannedRouteNavigation.makeLine` from the locked polyline.
    var distanceAlongRoute: CLLocationDistance
    var kind: Kind
    /// True for a gas waypoint or a recommended fuel stop. Drives the
    /// always-visible next-fuel distance.
    var isFuel: Bool

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// Selected intermediate stops and the destination. An explicit reroute
    /// has to keep these. Dropping one to straighten the ride is rejected.
    var isRequiredOnReroute: Bool {
        kind == .stop || kind == .destination
    }
}

/// Where the rider is relative to the locked line.
struct NavigationFix: Equatable {
    var latitude: Double
    var longitude: Double
    /// Meters from the start of the locked line to the projected point.
    var distanceAlong: CLLocationDistance
    /// Meters from the rider to that projected point.
    var distanceFromLine: CLLocationDistance
    var isOffRoute: Bool
    /// Progress along the line that guidance is willing to keep. Does not
    /// jump backward when a stray fix is closer to an earlier vertex.
    var progressedDistance: CLLocationDistance
    var returnLatitude: Double
    var returnLongitude: Double
    /// How far the rider is from `returnLatitude` / `returnLongitude`.
    var returnDistance: CLLocationDistance

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var returnCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: returnLatitude, longitude: returnLongitude)
    }
}

/// The rider's off-route choice. Nothing in navigation picks this for them.
enum OffRouteDecision: String, Equatable, Sendable {
    /// Default offer. Point back at the locked line. Leave the line alone.
    case backToMyRoute
    /// Explicit. A replacement line may be built from here, and only kept
    /// when the remaining selected stops still sit on it.
    case rerouteFromHere
}

/// Pure helpers for following a planned line. No location hardware, no speech.
enum PlannedRouteNavigation {

    /// Sideways GPS wander still counts as on the planned line. Beyond this,
    /// the rider is off route and has to choose what happens next.
    static let onRouteToleranceMeters: CLLocationDistance = 45

    /// How far a required stop may sit from a replacement line.
    static let rerouteStopToleranceMeters: CLLocationDistance = 80

    /// A fix this close to the end of the line, while on the line, has arrived.
    static let arrivalToleranceMeters: CLLocationDistance = 40

    /// Builds a locked line. Consecutive vertices closer than a meter are
    /// dropped so a duplicated join doesn't look like a turn later. The shape
    /// is otherwise kept: a scenic bulge stays a scenic bulge.
    static func makeLine(
        coordinates: [CLLocationCoordinate2D],
        stops: [PlannedRouteStop],
        routeStyleName: String
    ) -> PlannedNavigationLine? {
        var cleaned: [CLLocationCoordinate2D] = []
        for coordinate in coordinates where coordinate.isValidLocation {
            if let last = cleaned.last, meters(from: last, to: coordinate) < 1 {
                continue
            }
            cleaned.append(coordinate)
        }
        guard cleaned.count >= 2 else { return nil }

        let polylines = [cleaned]
        let placed = stops
            .filter { $0.coordinate.isValidLocation }
            .map { stop -> PlannedRouteStop in
                var copy = stop
                copy.distanceAlongRoute = RouteGeometry.distanceAlongRoute(
                    of: stop.coordinate,
                    alongPolylines: polylines
                )
                return copy
            }
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }

        return PlannedNavigationLine(
            coordinates: cleaned,
            stops: placed,
            routeStyleName: routeStyleName
        )
    }

    /// Projects `coordinate` onto `line`. Off-route detection uses distance
    /// from the locked vertices, not distance from a faster corridor between
    /// the same endpoints.
    static func fix(
        at coordinate: CLLocationCoordinate2D,
        on line: PlannedNavigationLine,
        progressedDistance: CLLocationDistance
    ) -> NavigationFix {
        let polylines = [line.coordinates]
        let distanceAlong = RouteGeometry.distanceAlongRoute(of: coordinate, alongPolylines: polylines)
        let distanceFromLine = RouteGeometry.distanceFromRoute(of: coordinate, alongPolylines: polylines)
        let isOffRoute = distanceFromLine > onRouteToleranceMeters
        let progressed = isOffRoute
            ? max(0, progressedDistance)
            : max(progressedDistance, distanceAlong)
        let returnAlong = returnDistanceAlong(
            nearestAlong: distanceAlong,
            progressed: progressedDistance,
            length: line.lengthMeters
        )
        let returnPoint = point(along: line.coordinates, distance: returnAlong)
            ?? line.coordinates.last
            ?? coordinate
        return NavigationFix(
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            distanceAlong: distanceAlong,
            distanceFromLine: distanceFromLine,
            isOffRoute: isOffRoute,
            progressedDistance: progressed,
            returnLatitude: returnPoint.latitude,
            returnLongitude: returnPoint.longitude,
            returnDistance: meters(from: coordinate, to: returnPoint)
        )
    }

    /// Show the choice only while the rider is off the locked line and has
    /// not picked yet. Location updates never select a branch of this choice.
    static func shouldOfferOffRouteChoice(
        isOffRoute: Bool,
        decision: OffRouteDecision?
    ) -> Bool {
        isOffRoute && decision == nil
    }

    /// Stops an explicit reroute still has to pass through: selected stops
    /// and the destination at or beyond the last on-line progress.
    static func remainingRequiredStops(
        on line: PlannedNavigationLine,
        progressedDistance: CLLocationDistance
    ) -> [PlannedRouteStop] {
        line.stops.filter { stop in
            stop.isRequiredOnReroute
                && stop.distanceAlongRoute >= progressedDistance - onRouteToleranceMeters
        }
    }

    /// A replacement is acceptable only when every remaining selected stop
    /// still lies on it. A faster road that skips a stop, or a line offered
    /// before the rider asked to reroute, is not acceptable.
    static func reroutePreservesStops(
        _ stops: [PlannedRouteStop],
        on coordinates: [CLLocationCoordinate2D]
    ) -> Bool {
        let required = stops.filter(\.isRequiredOnReroute)
        guard !required.isEmpty, coordinates.count >= 2 else { return false }
        let polylines = [coordinates]
        return required.allSatisfy { stop in
            RouteGeometry.distanceFromRoute(of: stop.coordinate, alongPolylines: polylines)
                <= rerouteStopToleranceMeters
        }
    }

    /// True when an on-line fix has reached the end of the locked line.
    static func hasArrived(distanceAlong: CLLocationDistance, length: CLLocationDistance, isOffRoute: Bool) -> Bool {
        !isOffRoute && length > 0 && distanceAlong >= length - arrivalToleranceMeters
    }

    // MARK: - Geometry

    static func meters(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: end.latitude, longitude: end.longitude))
    }

    /// Point at `distance` meters along `coordinates`. Clamped to the ends.
    static func point(
        along coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance
    ) -> CLLocationCoordinate2D? {
        guard let first = coordinates.first else { return nil }
        if distance <= 0 { return first }
        let length = RouteGeometry.length(of: coordinates)
        if distance >= length { return coordinates.last }
        return RouteGeometry.coordinates(
            alongPolylines: [coordinates],
            atDistances: [distance]
        ).first
    }

    /// Compass bearing in degrees, 0 = north, clockwise.
    static func bearingDegrees(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let deltaLongitude = (end.longitude - start.longitude) * .pi / 180
        let y = sin(deltaLongitude) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(deltaLongitude)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Clockwise-positive turn from `incoming` to `outgoing`, in -180...180.
    /// Positive is a right turn.
    static func signedTurnDegrees(incoming: Double, outgoing: Double) -> Double {
        var delta = outgoing - incoming
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return delta
    }

    /// Prefer the nearby projection. If the nearest vertex is well behind
    /// where the rider had already ridden, aim at that progress instead of
    /// sending them back to the start.
    private static func returnDistanceAlong(
        nearestAlong: CLLocationDistance,
        progressed: CLLocationDistance,
        length: CLLocationDistance
    ) -> CLLocationDistance {
        let backtrackLimit: CLLocationDistance = 80
        let target = nearestAlong + backtrackLimit >= progressed ? nearestAlong : progressed
        return min(max(0, target), max(0, length))
    }
}
