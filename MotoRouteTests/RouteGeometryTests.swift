import XCTest
import CoreLocation
@testable import MotoRoute

/// Unit tests for the pure distance-along-route projection. Uses simple
/// equatorial west-to-east lines so expected distances are easy to reason about.
final class RouteGeometryTests: XCTestCase {

    private func meters(from a: CLLocationCoordinate2D, to b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    func testStartOfRouteIsZero() {
        let line = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1)
        ]
        let d = RouteGeometry.distanceAlongRoute(
            of: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            alongPolylines: [line]
        )
        XCTAssertEqual(d, 0, accuracy: 1)
    }

    func testMidpointIsHalfTheRoute() {
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let total = meters(from: start, to: end)
        let d = RouteGeometry.distanceAlongRoute(
            of: CLLocationCoordinate2D(latitude: 0, longitude: 0.5),
            alongPolylines: [[start, end]]
        )
        XCTAssertEqual(d, total / 2, accuracy: total * 0.01)
    }

    func testOffRouteProjectsOntoNearestPoint() {
        // A point slightly north of the midpoint still maps to ~half the route.
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let total = meters(from: start, to: end)
        let d = RouteGeometry.distanceAlongRoute(
            of: CLLocationCoordinate2D(latitude: 0.01, longitude: 0.5),
            alongPolylines: [[start, end]]
        )
        XCTAssertEqual(d, total / 2, accuracy: total * 0.02)
    }

    func testMultiLegDistanceAccumulates() {
        let leg1 = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1)
        ]
        let leg2 = [
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 0, longitude: 2)
        ]
        let oneDegree = meters(from: leg1[0], to: leg1[1])
        let d = RouteGeometry.distanceAlongRoute(
            of: CLLocationCoordinate2D(latitude: 0, longitude: 1.5),
            alongPolylines: [leg1, leg2]
        )
        XCTAssertEqual(d, oneDegree * 1.5, accuracy: oneDegree * 0.02)
    }

    func testEmptyRouteReturnsZero() {
        let d = RouteGeometry.distanceAlongRoute(
            of: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            alongPolylines: []
        )
        XCTAssertEqual(d, 0, accuracy: 0.0001)
    }
}
