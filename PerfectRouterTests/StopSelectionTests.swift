import XCTest
import Contacts
import CoreLocation
@testable import PerfectRouter

/// Unit tests for waypoint order: search/contact `addWaypoint`, long-press
/// `addStart`, and the shared stop-selection path `addStop(from:)`.
@MainActor
final class StopSelectionTests: XCTestCase {

    private func suggestion(_ name: String,
                            category: StopCategory,
                            lat: Double,
                            lon: Double) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            category: category,
            distanceAlongRoute: 0
        )
    }

    private func waypoint(_ name: String, lat: Double, lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    func testAddStopInsertsFoodBeforeDestination() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        viewModel.addStop(from: suggestion("Diner", category: .food, lat: 33.5, lon: -81.5))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Diner", "End"])
        XCTAssertFalse(viewModel.waypoints[1].isGasFill)
    }

    func testAddStopBuffersFuelUntilApply() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]
        let pump = suggestion("Gas-N-Go", category: .gas, lat: 33.4, lon: -81.6)

        viewModel.addStop(from: pump)

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])
        XCTAssertTrue(viewModel.isGasBuffered(pump))
        XCTAssertEqual(viewModel.bufferedGasStops.count, 1)

        viewModel.clearBufferedGasStops()
        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])

        viewModel.addStop(from: pump)
        viewModel.applyBufferedGasStops()
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Gas-N-Go", "End"])
        XCTAssertTrue(viewModel.waypoints[1].isGasFill)
        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)
    }

    func testApplyBufferedGasStopsKeepsRideOrder() {
        let start = waypoint("Start", lat: 33.0, lon: -82.0)
        let end = waypoint("End", lat: 35.0, lon: -80.0)
        let early = SuggestedStop(
            name: "Early",
            coordinate: CLLocationCoordinate2D(latitude: 33.4, longitude: -81.6),
            category: .gas,
            distanceAlongRoute: 50_000
        )
        let late = SuggestedStop(
            name: "Late",
            coordinate: CLLocationCoordinate2D(latitude: 34.2, longitude: -81.0),
            category: .gas,
            distanceAlongRoute: 180_000
        )
        let line = [
            start.coordinate,
            CLLocationCoordinate2D(latitude: 34.0, longitude: -81.0),
            end.coordinate,
        ]
        let merged = RoutePlannerViewModel.waypoints(
            [start, end],
            inserting: [late, early],
            along: [line],
            totalDistance: 300_000
        )
        XCTAssertEqual(merged.map(\.name), ["Start", "Early", "Late", "End"])
        XCTAssertEqual(merged.map(\.isGasFill), [false, true, true, false])
    }

    func testAddWaypointInsertsBeforeDestination() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        viewModel.addWaypoint(waypoint("Café", lat: 33.5, lon: -81.5))
        viewModel.addWaypoint(waypoint("Overlook", lat: 33.8, lon: -81.2))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Café", "Overlook", "End"])
    }

    func testAddWaypointWhenOnlyStartAppendsDestination() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [waypoint("Start", lat: 33.0, lon: -82.0)]

        viewModel.addWaypoint(waypoint("End", lat: 34.0, lon: -81.0))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])
    }

    func testAddStartReplacesExistingOrigin() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Current Location", lat: 33.47, lon: -82.01),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        viewModel.addStart(waypoint("New Start", lat: 33.6, lon: -82.2))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["New Start", "End"])
    }

    func testAddStartWhenEmptySetsOrigin() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = []

        viewModel.addStart(waypoint("Start", lat: 33.0, lon: -82.0))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start"])
    }

    func testImportRoutePreservesGasFill() {
        let shared = SharedRoute(waypoints: [
            waypoint("Start", lat: 33.0, lon: -82.0),
            Waypoint(
                name: "Pump",
                coordinate: CLLocationCoordinate2D(latitude: 33.5, longitude: -81.5),
                isGasFill: true
            ),
            waypoint("End", lat: 34.0, lon: -81.0),
        ])
        guard let url = shared.shareURL else {
            return XCTFail("shareURL should encode a fill")
        }

        let viewModel = RoutePlannerViewModel()
        XCTAssertTrue(viewModel.importRoute(from: url))
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Pump", "End"])
        XCTAssertEqual(viewModel.waypoints.map(\.isGasFill), [false, true, false])
    }

    func testAddContactWaypointRejectsEmptyAddress() async {
        let viewModel = RoutePlannerViewModel()
        let result = await viewModel.addWaypoint(named: "Nobody", at: CNMutablePostalAddress())
        XCTAssertNil(result)
        XCTAssertEqual(viewModel.errorMessage, "That contact has no usable address.")
        XCTAssertTrue(viewModel.waypoints.isEmpty)
    }

    func testAddStopRejectsInvalidCoordinate() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        viewModel.addStop(from: SuggestedStop(
            name: "Nowhere",
            coordinate: kCLLocationCoordinate2DInvalid,
            category: .food,
            distanceAlongRoute: 0
        ))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])
    }

    func testStopsCountIntermediateOnly() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("One", lat: 33.2, lon: -81.8),
            waypoint("Two", lat: 33.4, lon: -81.6),
            waypoint("Three", lat: 33.6, lon: -81.4),
            waypoint("Four", lat: 33.8, lon: -81.2),
            waypoint("Five", lat: 34.0, lon: -81.0),
            waypoint("End", lat: 34.2, lon: -80.8),
        ]

        XCTAssertEqual(viewModel.intermediateStopCount, 5)
        XCTAssertEqual(viewModel.routeStopsTitle, "Route (5 stops)")
    }

    func testApplyingAStopAlreadyOnTheRouteDoesNotDuplicateIt() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]
        let pump = suggestion("Gas-N-Go", category: .gas, lat: 33.4, lon: -81.6)

        viewModel.addStop(from: pump)
        viewModel.applyBufferedGasStops()
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Gas-N-Go", "End"])

        // A later search returns the same pump under another name.
        let again = suggestion("Shell", category: .gas, lat: 33.4, lon: -81.6)
        viewModel.addStop(from: again)
        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)
        viewModel.applyBufferedGasStops()
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Gas-N-Go", "End"])
    }

    func testSuggestionsOmitAStopAlreadyOnTheRoute() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Gas-N-Go", lat: 33.4, lon: -81.6),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]
        viewModel.suggestedStops = [
            suggestion("Shell", category: .gas, lat: 33.4, lon: -81.6),
            suggestion("Pilot", category: .gas, lat: 33.8, lon: -81.2),
        ]

        XCTAssertEqual(viewModel.addableSuggestions.map(\.name), ["Pilot"])
    }

    func testAddStopAlreadyOnRouteIsANoOp() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Diner", lat: 33.5, lon: -81.5),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        viewModel.addStop(from: suggestion("Cafe", category: .food, lat: 33.5004, lon: -81.5004))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Diner", "End"])
    }

    func testWaypointsInsertingSkipsACoordinateAlreadyOnTheRoute() {
        let start = waypoint("Start", lat: 33.0, lon: -82.0)
        let existing = Waypoint(
            name: "Gas-N-Go",
            coordinate: CLLocationCoordinate2D(latitude: 33.4, longitude: -81.6),
            isGasFill: true
        )
        let end = waypoint("End", lat: 35.0, lon: -80.0)
        let duplicate = SuggestedStop(
            name: "Shell",
            coordinate: CLLocationCoordinate2D(latitude: 33.4004, longitude: -81.6004),
            category: .gas,
            distanceAlongRoute: 50_000
        )
        let fresh = SuggestedStop(
            name: "Pilot",
            coordinate: CLLocationCoordinate2D(latitude: 34.2, longitude: -81.0),
            category: .gas,
            distanceAlongRoute: 180_000
        )

        let merged = RoutePlannerViewModel.waypoints(
            [start, existing, end],
            inserting: [duplicate, fresh, duplicate],
            along: [],
            totalDistance: 300_000
        )

        XCTAssertEqual(merged.map(\.name), ["Start", "Gas-N-Go", "Pilot", "End"])
        XCTAssertEqual(merged.filter(\.isGasFill).count, 2)
    }

    func testUntrustedCoverageHidesTheNamedGap() {
        let viewModel = RoutePlannerViewModel()
        let plan = RoutePlannerViewModel.fuelPlan(
            from: [
                SuggestedStop(
                    name: "Far",
                    coordinate: CLLocationCoordinate2D(latitude: 34, longitude: -81),
                    category: .gas,
                    distanceAlongRoute: 200_000
                ),
            ],
            totalDistance: 400_000,
            range: 100_000
        )
        viewModel.fuelPlanEntries = plan.entries
        viewModel.hasFuelGap = true

        XCTAssertTrue(plan.hasGap)
        XCTAssertFalse(viewModel.showsFuelGapWarning)
        XCTAssertTrue(viewModel.visibleFuelPlanEntries.isEmpty)
    }

    func testStopsTitleOmitsZeroAndSingularizesOne() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]
        XCTAssertEqual(viewModel.intermediateStopCount, 0)
        XCTAssertEqual(viewModel.routeStopsTitle, "Route")

        viewModel.waypoints.insert(waypoint("Café", lat: 33.5, lon: -81.5), at: 1)
        XCTAssertEqual(viewModel.intermediateStopCount, 1)
        XCTAssertEqual(viewModel.routeStopsTitle, "Route (1 stop)")
    }
}
