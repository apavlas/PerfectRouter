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

    func testAddStopInsertsFuelBeforeDestination() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        viewModel.addStop(from: suggestion("Gas-N-Go", category: .gas, lat: 33.4, lon: -81.6))

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Gas-N-Go", "End"])
        XCTAssertTrue(viewModel.waypoints[1].isGasFill)
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
}
