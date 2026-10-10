import CoreLocation
import XCTest
@testable import PerfectRouter

/// Locks the canned ride used by `PerfectRouterUITests` to the fuel planner.
/// The simulator suite projects these same places onto a stub polyline.
final class UITestFixtureTests: XCTestCase {

    func testLaunchArgumentIsStable() {
        XCTAssertEqual(UITestStubLaunch.argument, "-UITestStubServices")
        XCTAssertFalse(UITestStubLaunch.isEnabled)
    }

    func testCannedPumpsMatchAHundredMileTank() {
        let range = 100 * UITestFixture.metersPerMile
        let stops = UITestFixture.places.filter(\.gasStation).map { place in
            SuggestedStop(
                name: place.name,
                coordinate: UITestFixture.coordinate(for: place),
                category: .gas,
                distanceAlongRoute: place.milesNorth * UITestFixture.metersPerMile
            )
        }

        let plan = RoutePlannerViewModel.planFuelStops(
            from: stops,
            totalDistance: UITestFixture.totalMeters,
            range: range
        )

        XCTAssertEqual(plan.stops.map(\.name), UITestFixture.recommendedFuelNames)
        XCTAssertFalse(plan.hasGap)
        XCTAssertGreaterThan(UITestFixture.totalMeters, range)
    }

    func testStubRouteExposesDistancePolylineAndTravelTime() throws {
        let destination = UITestFixture.coordinate(
            milesNorth: UITestFixture.routeMiles,
            eastMeters: 0
        )
        let routes = StubRouteBuilder.routes(
            from: UITestFixture.origin,
            to: destination,
            avoidsHighways: false,
            alternates: false
        )

        XCTAssertEqual(routes.count, 1)
        let route = try XCTUnwrap(routes.first)
        XCTAssertGreaterThan(route.distance, UITestFixture.totalMeters * 0.9)
        XCTAssertLessThan(route.distance, UITestFixture.totalMeters * 1.15)
        XCTAssertGreaterThan(route.polyline.pointCount, 2)
        XCTAssertGreaterThan(route.expectedTravelTime, 60)
        XCTAssertTrue(route.hasHighways)

        let coordinates = RouteGeometry.coordinates(of: route.polyline)
        XCTAssertEqual(coordinates.count, route.polyline.pointCount)
        XCTAssertEqual(coordinates.first?.latitude ?? -1, UITestFixture.origin.latitude, accuracy: 0.000_1)
        XCTAssertEqual(coordinates.last?.latitude ?? -1, destination.latitude, accuracy: 0.000_1)
    }

    func testStubAlternatesAreLongerAndLeaveTheHighway() {
        let destination = UITestFixture.coordinate(
            milesNorth: UITestFixture.routeMiles,
            eastMeters: 0
        )
        let routes = StubRouteBuilder.routes(
            from: UITestFixture.origin,
            to: destination,
            avoidsHighways: true,
            alternates: true
        )

        XCTAssertEqual(routes.count, 2)
        XCTAssertGreaterThan(routes[1].distance, routes[0].distance)
        XCTAssertFalse(routes[1].hasHighways)

        let scenic = RoutePlannerViewModel.preferredRoute(from: routes, style: .scenic)
        XCTAssertEqual(scenic?.distance, routes[1].distance)
        XCTAssertFalse(scenic?.hasHighways ?? true)
    }

    func testHomeFuelMatchesTheOriginSoSelectRecommendedSkipsIt() throws {
        let origin = try XCTUnwrap(UITestFixture.places.first { $0.name == "Test Origin" })
        let home = try XCTUnwrap(UITestFixture.places.first { $0.name == "Home Fuel" && $0.gasStation })
        let onRoute = try XCTUnwrap(UITestFixture.places.first { $0.name == "On Route Fuel" })
        XCTAssertTrue(onRoute.searchable)
        XCTAssertTrue(onRoute.gasStation)
        XCTAssertEqual(
            RoutePlannerViewModel.coordinateKey(UITestFixture.coordinate(for: origin)),
            RoutePlannerViewModel.coordinateKey(UITestFixture.coordinate(for: home))
        )
    }
}
