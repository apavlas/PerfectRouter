import XCTest
import CoreLocation
@testable import PerfectRouter

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

    // MARK: - Side of travel

    /// A west-to-east line along the equator: north of it is the traveler's
    /// left, south of it their right.
    private let eastboundLine = [
        CLLocationCoordinate2D(latitude: 0, longitude: 0),
        CLLocationCoordinate2D(latitude: 0, longitude: 1)
    ]

    func testPointSouthOfEastboundRouteIsRight() {
        let side = RouteGeometry.side(
            of: CLLocationCoordinate2D(latitude: -0.01, longitude: 0.5),
            alongPolylines: [eastboundLine]
        )
        XCTAssertEqual(side, .right)
    }

    func testPointNorthOfEastboundRouteIsLeft() {
        let side = RouteGeometry.side(
            of: CLLocationCoordinate2D(latitude: 0.01, longitude: 0.5),
            alongPolylines: [eastboundLine]
        )
        XCTAssertEqual(side, .left)
    }

    func testSideFlipsWithDirectionOfTravel() {
        // The same point relative to the same road, ridden the other way.
        let westboundLine = Array(eastboundLine.reversed())
        let side = RouteGeometry.side(
            of: CLLocationCoordinate2D(latitude: -0.01, longitude: 0.5),
            alongPolylines: [westboundLine]
        )
        XCTAssertEqual(side, .left)
    }

    func testPointOnRouteLineIsUnknown() {
        let side = RouteGeometry.side(
            of: CLLocationCoordinate2D(latitude: 0, longitude: 0.5),
            alongPolylines: [eastboundLine]
        )
        XCTAssertEqual(side, .unknown)
    }

    func testEmptyRouteSideIsUnknown() {
        let side = RouteGeometry.side(
            of: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            alongPolylines: []
        )
        XCTAssertEqual(side, .unknown)
    }

    func testTravelSideRespectsDrivingHand() {
        let south = CLLocationCoordinate2D(latitude: -0.01, longitude: 0.5)   // rider's right
        let north = CLLocationCoordinate2D(latitude: 0.01, longitude: 0.5)    // rider's left

        // Right-hand traffic (US): right-side stops reachable, left-side not.
        XCTAssertTrue(RouteGeometry.isOnTravelSide(south, alongPolylines: [eastboundLine], drivesOnRight: true))
        XCTAssertFalse(RouteGeometry.isOnTravelSide(north, alongPolylines: [eastboundLine], drivesOnRight: true))

        // Left-hand traffic (UK, Japan, Australia): flipped.
        XCTAssertFalse(RouteGeometry.isOnTravelSide(south, alongPolylines: [eastboundLine], drivesOnRight: false))
        XCTAssertTrue(RouteGeometry.isOnTravelSide(north, alongPolylines: [eastboundLine], drivesOnRight: false))
    }

    func testPointOnRouteLineIsAlwaysReachable() {
        let onLine = CLLocationCoordinate2D(latitude: 0, longitude: 0.5)
        XCTAssertTrue(RouteGeometry.isOnTravelSide(onLine, alongPolylines: [eastboundLine], drivesOnRight: true))
        XCTAssertTrue(RouteGeometry.isOnTravelSide(onLine, alongPolylines: [eastboundLine], drivesOnRight: false))
    }

    // MARK: - Coordinates at route distances

    func testCoordinatesAtDistancesOnEquator() {
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let total = meters(from: start, to: end)
        let coords = RouteGeometry.coordinates(
            alongPolylines: [[start, end]],
            atDistances: [0, total / 2, total]
        )
        XCTAssertEqual(coords.count, 3)
        XCTAssertEqual(coords[0].longitude, 0, accuracy: 0.001)
        XCTAssertEqual(coords[1].longitude, 0.5, accuracy: 0.02)
        XCTAssertEqual(coords[2].longitude, 1, accuracy: 0.02)
    }

    func testCoordinatesAtDistancesDropPastEnd() {
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let total = meters(from: start, to: end)
        let coords = RouteGeometry.coordinates(
            alongPolylines: [[start, end]],
            atDistances: [total * 2]
        )
        XCTAssertTrue(coords.isEmpty)
    }
}
