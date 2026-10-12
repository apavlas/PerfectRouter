import CoreLocation
import XCTest
@testable import PerfectRouter

/// Locks the canned ride used by `PerfectRouterUITests` to the fuel planner.
/// The simulator suite projects these same places onto a stub polyline.
final class UITestFixtureTests: XCTestCase {

    func testUITestLaunchResetsPersistedStyleAndTank() {
        let styleKey = AppSettings.Keys.routeStyle
        let milesKey = AppSettings.Keys.defaultFuelRangeMiles
        let storedStyle = UserDefaults.standard.string(forKey: styleKey)
        let storedMiles = UserDefaults.standard.object(forKey: milesKey)
        defer {
            if let storedStyle {
                UserDefaults.standard.set(storedStyle, forKey: styleKey)
            } else {
                UserDefaults.standard.removeObject(forKey: styleKey)
            }
            if let storedMiles {
                UserDefaults.standard.set(storedMiles, forKey: milesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: milesKey)
            }
        }
        UserDefaults.standard.set(RouteStyle.scenic.rawValue, forKey: styleKey)
        UserDefaults.standard.set(50.0, forKey: milesKey)
        UITestStubLaunch.resetPersistedRidePreferences()
        XCTAssertEqual(AppSettings.defaultRouteStyle, .fastest)
        XCTAssertEqual(
            AppSettings.defaultFuelRangeMeters,
            AppSettings.defaultFuelRangeMilesDefault * AppSettings.metersPerMile,
            accuracy: 1
        )
    }

    @MainActor
    func testSuggestionsDoNotRepeatFuelPlanRows() {
        let viewModel = RoutePlannerViewModel()
        let pilot = SuggestedStop(
            name: "Pilot Madison",
            coordinate: UITestFixture.coordinate(milesNorth: 80, eastMeters: 800),
            category: .gas,
            distanceAlongRoute: 80 * UITestFixture.metersPerMile
        )
        let suggestionPilot = SuggestedStop(
            name: "Pilot Madison",
            coordinate: UITestFixture.coordinate(milesNorth: 80, eastMeters: 800),
            category: .gas,
            distanceAlongRoute: 80 * UITestFixture.metersPerMile
        )
        let quick = SuggestedStop(
            name: "Quick Stop",
            coordinate: UITestFixture.coordinate(milesNorth: 40, eastMeters: 800),
            category: .gas,
            distanceAlongRoute: 40 * UITestFixture.metersPerMile
        )
        viewModel.fuelPlanEntries = [.recommended(pilot)]
        viewModel.suggestedStops = [suggestionPilot, quick]
        XCTAssertEqual(viewModel.addableSuggestions.map(\.name), ["Quick Stop"])
        XCTAssertTrue(viewModel.recommendedFuelPlanAccessibilityID.contains("Pilot Madison"))
        XCTAssertFalse(viewModel.recommendedFuelPlanAccessibilityID.contains("Quick Stop"))
    }

    func testLaunchArgumentIsStable() {
        XCTAssertEqual(UITestStubLaunch.argument, "-UITestStubServices")
        XCTAssertFalse(UITestStubLaunch.isEnabled)
        // The stub delays the directions request itself. There is no second
        // timer that pins the banner after the line is ready.
        XCTAssertGreaterThanOrEqual(UITestStubServices.responseDelay, .seconds(1))
        XCTAssertLessThan(UITestStubServices.responseDelay, .seconds(8))
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

    /// The UI stub projects pumps onto the polyline, then plans. Canned miles
    /// and that projection have to name the same stops, or the ride test
    /// waits for a station that is only a pin.
    func testProjectedStubRouteRecommendsTheFixturePumps() throws {
        let destination = UITestFixture.coordinate(
            milesNorth: UITestFixture.routeMiles,
            eastMeters: 0
        )
        let route = try XCTUnwrap(
            StubRouteBuilder.routes(
                from: UITestFixture.origin,
                to: destination,
                avoidsHighways: false,
                alternates: false
            ).first
        )
        let polyline = [RouteGeometry.coordinates(of: route.polyline)]
        let stops = UITestFixture.places.filter(\.gasStation).compactMap { place -> SuggestedStop? in
            let coordinate = UITestFixture.coordinate(for: place)
            let detour = RouteGeometry.distanceFromRoute(of: coordinate, alongPolylines: polyline)
            guard detour <= RoutePlannerViewModel.fuelSearchCorridorMeters else { return nil }
            guard RouteGeometry.isOnTravelSide(
                coordinate,
                alongPolylines: polyline,
                drivesOnRight: true
            ) else { return nil }
            let projected = RouteGeometry.distanceAlongRoute(of: coordinate, alongPolylines: polyline)
            let canned = place.milesNorth * UITestFixture.metersPerMile
            let distance = projected > 50 ? projected : canned
            return SuggestedStop(
                name: place.name,
                coordinate: coordinate,
                category: .gas,
                distanceAlongRoute: distance,
                detourMeters: detour
            )
        }

        let plan = RoutePlannerViewModel.planFuelStops(
            from: stops,
            totalDistance: route.distance,
            range: 100 * UITestFixture.metersPerMile
        )

        XCTAssertEqual(plan.stops.map(\.name), UITestFixture.recommendedFuelNames)
        XCTAssertFalse(plan.hasGap)
    }

    @MainActor
    func testRecommendedFuelRowExposesFuelStopIdentity() {
        let viewModel = RoutePlannerViewModel()
        let pilot = SuggestedStop(
            name: "Pilot Madison",
            coordinate: UITestFixture.coordinate(milesNorth: 80, eastMeters: 800),
            category: .gas,
            distanceAlongRoute: 80 * UITestFixture.metersPerMile
        )
        viewModel.fuelPlanEntries = [.recommended(pilot)]

        let row = viewModel.recommendedFuelAccessibility(for: pilot)
        XCTAssertEqual(row?.identifier, "fuelStop.Pilot Madison.unchecked")
        XCTAssertTrue(row?.label.contains("Fuel stop 1: Pilot Madison") == true)

        viewModel.toggleBufferedGasStop(pilot)
        let checked = viewModel.recommendedFuelAccessibility(for: pilot)
        XCTAssertEqual(checked?.identifier, "fuelStop.Pilot Madison.checked")

        let quick = SuggestedStop(
            name: "Quick Stop",
            coordinate: UITestFixture.coordinate(milesNorth: 40, eastMeters: 800),
            category: .gas,
            distanceAlongRoute: 40 * UITestFixture.metersPerMile
        )
        XCTAssertNil(viewModel.recommendedFuelAccessibility(for: quick))
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
