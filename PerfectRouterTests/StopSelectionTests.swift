import XCTest
import Contacts
import CoreLocation
@testable import PerfectRouter

/// Main-actor stand-in for `Task.isCompleted`, which Swift 5.10 and Swift 6
/// do not provide. The selection task sets it after the tap returns.
@MainActor
private final class FuelSelectionCompletion: Sendable {
    var isCompleted = false
}

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
        XCTAssertEqual(viewModel.scrollToWaypointID, viewModel.waypoints[1].id)
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

    private func alongStop(_ name: String,
                           category: StopCategory = .gas,
                           lat: Double,
                           lon: Double,
                           distance: CLLocationDistance) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            category: category,
            distanceAlongRoute: distance
        )
    }

    func testSelectRecommendedSelectsOnlyRecommendedFuelStops() async {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 0, lon: 0),
            waypoint("End", lat: 0, lon: 2),
        ]
        let early = alongStop("Early", lat: 0.05, lon: 0.4, distance: 40_000)
        let late = alongStop("Late", lat: 0.05, lon: 1.6, distance: 170_000)
        let past = alongStop("Too Far", lat: 0.05, lon: 2.8, distance: 300_000)
        let other = alongStop("Side Pump", lat: 0.2, lon: 0.8, distance: 90_000)
        let diner = alongStop("Diner", category: .food, lat: 0.05, lon: 0.42, distance: 42_000)
        // Late is listed first so selection order is not ride order.
        viewModel.fuelStops = [late, early, past, diner]
        viewModel.fuelPlanEntries = [
            .recommended(late),
            .recommended(early),
            .pastRange(past),
        ]
        viewModel.gasStations = [late, early, past, other]
        viewModel.fuelFoodStops = [FuelFoodStop(fuelStop: early, nearbyFood: [diner])]
        viewModel.plannedCorridor = [[
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
        ]]
        let plansBefore = viewModel.calculatingGeneration

        XCTAssertEqual(viewModel.selectRecommendedButtonTitle, "Select recommended")
        // One recommended row is already checked. The tap still adds both.
        viewModel.toggleBufferedGasStop(early)
        viewModel.toggleBufferedGasStop(other)
        // The list swaps in one assignment. `Task` has no `isCompleted`, so
        // the selection task sets this flag as its last step. Titles are read
        // only after that.
        let completion = FuelSelectionCompletion()
        let selection = Task { @MainActor in
            await viewModel.toggleRecommendedFuelSelection()
            completion.isCompleted = true
        }
        await selection.value
        XCTAssertTrue(completion.isCompleted)

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Early", "Late", "End"])
        let earlyLabel = viewModel.fuelRowLabel(for: early)
        XCTAssertNotNil(earlyLabel)
        XCTAssertTrue(earlyLabel?.title.hasPrefix("Fuel stop ") ?? false)
        XCTAssertTrue(earlyLabel?.title.contains("Early") ?? false)
        XCTAssertFalse(earlyLabel?.caption.contains("from start") ?? true)
        XCTAssertEqual(viewModel.waypoints.map(\.isGasFill), [false, true, true, false])
        XCTAssertEqual(viewModel.bufferedGasStops.map(\.name), ["Side Pump"])
        XCTAssertFalse(viewModel.waypoints.contains { $0.name == "Too Far" || $0.name == "Diner" || $0.name == "Side Pump" })
        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertEqual(viewModel.scrollToWaypointID, viewModel.waypoints[1].id)

        await viewModel.toggleRecommendedFuelSelection()
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Early", "Late", "End"])
    }

    func testSelectRecommendedSkipsStopsAlreadyOnTheRoute() async {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Gas-N-Go", lat: 33.4, lon: -81.6),
            waypoint("End", lat: 35.0, lon: -80.0),
        ]
        // Same pump, new name, within the ~111 m match. Already on the route.
        let again = alongStop("Shell", lat: 33.4004, lon: -81.6004, distance: 50_000)
        let fresh = alongStop("Pilot", lat: 34.2, lon: -81.0, distance: 180_000)
        let past = alongStop("Too Far", lat: 34.8, lon: -80.4, distance: 400_000)
        viewModel.fuelStops = [again, fresh, past]
        viewModel.fuelPlanEntries = [
            .recommended(again),
            .recommended(fresh),
            .pastRange(past),
        ]
        viewModel.plannedCorridor = [[
            viewModel.waypoints[0].coordinate,
            viewModel.waypoints[1].coordinate,
            viewModel.waypoints[2].coordinate,
        ]]
        let plansBefore = viewModel.calculatingGeneration

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)
        XCTAssertFalse(viewModel.isGasBuffered(again))
        XCTAssertFalse(viewModel.isGasBuffered(past))
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Gas-N-Go", "Pilot", "End"])
        XCTAssertEqual(viewModel.waypoints.filter { $0.name == "Gas-N-Go" }.count, 1)
        XCTAssertEqual(viewModel.waypoints.filter(\.isGasFill).map(\.name), ["Pilot"])
        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        await viewModel.toggleRecommendedFuelSelection()
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Gas-N-Go", "Pilot", "End"])
    }

    func testSelectRecommendedLeavesAManualCheckForApply() async {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 0, lon: 0),
            waypoint("End", lat: 0, lon: 2),
        ]
        let early = alongStop("Early", lat: 0.05, lon: 0.4, distance: 40_000)
        let late = alongStop("Late", lat: 0.05, lon: 1.6, distance: 170_000)
        let other = alongStop("Side Pump", lat: 0.2, lon: 0.8, distance: 90_000)
        viewModel.fuelStops = [early, late]
        viewModel.gasStations = [early, late, other]
        viewModel.plannedCorridor = [[
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
        ]]
        let plansBefore = viewModel.calculatingGeneration

        viewModel.toggleBufferedGasStop(other)
        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Early", "Late", "End"])
        XCTAssertEqual(viewModel.bufferedGasStops.map(\.name), ["Side Pump"])
        XCTAssertEqual(viewModel.selectRecommendedButtonTitle, "Select recommended")
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)
    }

    func testApplyRecommendedFuelStopsReplansOnceInRideOrder() async {
        let viewModel = RoutePlannerViewModel()
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let lunchAt = CLLocationCoordinate2D(latitude: 0, longitude: 1)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 2)
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: start),
            Waypoint(name: "Lunch", coordinate: lunchAt),
            Waypoint(name: "End", coordinate: end),
        ]
        viewModel.plannedCorridor = [[start, end]]
        let leg = CLLocation(latitude: start.latitude, longitude: start.longitude)
            .distance(from: CLLocation(latitude: lunchAt.latitude, longitude: lunchAt.longitude))
        let early = alongStop("Early", lat: 0.04, lon: 0.35, distance: leg * 0.4)
        let late = alongStop("Late", lat: 0.04, lon: 1.55, distance: leg * 1.5)
        let diner = alongStop("Diner", category: .food, lat: 0.04, lon: 0.36, distance: leg * 0.45)
        viewModel.fuelStops = [late, early, diner]
        viewModel.fuelFoodStops = [FuelFoodStop(fuelStop: early, nearbyFood: [diner])]
        let plansBefore = viewModel.calculatingGeneration

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Early", "Lunch", "Late", "End"])
        XCTAssertEqual(viewModel.waypoints.map(\.isGasFill), [false, true, false, true, false])
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)
        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)

        await viewModel.toggleRecommendedFuelSelection()
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Early", "Lunch", "Late", "End"])
    }

    func testSelectRecommendedAddsEveryStopPastAFiveStopCap() async {
        let viewModel = RoutePlannerViewModel()
        let start = CLLocationCoordinate2D(latitude: 0, longitude: 0)
        let end = CLLocationCoordinate2D(latitude: 0, longitude: 4)
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: start),
            Waypoint(name: "End", coordinate: end),
        ]
        viewModel.plannedCorridor = [[start, end]]
        let count = 12
        let recommended = (1...count).map { index in
            alongStop(
                "Pump \(index)",
                lat: 0.02 * Double(index),
                lon: 0.2 * Double(index),
                distance: CLLocationDistance(index) * 100_000
            )
        }
        let past = alongStop("Too Far", lat: 0.4, lon: 3.6, distance: 5_000_000)
        // Reverse the list so ride order is the planner's job, not the array's.
        viewModel.fuelStops = recommended.reversed() + [past]
        viewModel.fuelPlanEntries = recommended.map { .recommended($0) } + [.pastRange(past)]
        let plansBefore = viewModel.calculatingGeneration

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(
            viewModel.waypoints.map(\.name),
            ["Start"] + (1...count).map { "Pump \($0)" } + ["End"]
        )
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)
        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)
        XCTAssertFalse(viewModel.waypoints.contains { $0.name == "Too Far" })
        XCTAssertEqual(viewModel.scrollToWaypointID, viewModel.waypoints[1].id)

        await viewModel.toggleRecommendedFuelSelection()
        XCTAssertEqual(viewModel.calculatingGeneration, plansBefore + 1)
    }

    func testStopPastTheTankIsBeyondRemainingRange() {
        let viewModel = RoutePlannerViewModel()
        let mile = AppSettings.metersPerMile
        viewModel.fuelRangeMeters = 200 * mile
        let inRange = alongStop("In Range", lat: 0.1, lon: 0.2, distance: 150 * mile)
        viewModel.fuelStops = [inRange]
        XCTAssertFalse(viewModel.isBeyondRemainingRange(distanceAlongRoute: 150 * mile))
        XCTAssertFalse(viewModel.isBeyondRemainingRange(distanceAlongRoute: 250 * mile))
        XCTAssertTrue(viewModel.isBeyondRemainingRange(distanceAlongRoute: 400 * mile))
        viewModel.fuelStops = []
        XCTAssertFalse(viewModel.isBeyondRemainingRange(distanceAlongRoute: 180 * mile))
        XCTAssertTrue(viewModel.isBeyondRemainingRange(distanceAlongRoute: 250 * mile))
    }

    /// Charlotte → LA, 200 mi tank. Select recommended is the button's entry
    /// point: it replans, then inserts. A station whose along-route mile is
    /// inside 170 but whose detour pushes the ridden leg past the reserve is
    /// not the pick. A window with nothing inside 170 takes the nearest
    /// station still inside the tank. The station 348 mi later, and the
    /// recommendation after that gap, are not inserted.
    func testSelectRecommendedCapsSparseLegsAndDoesNotCrossTheGap() async {
        let mile = AppSettings.metersPerMile
        let totalMiles = 2_497.0
        // North from Charlotte. Stations sit on polyline vertices so the
        // travel-side check keeps every one of them.
        func coordinate(atMiles miles: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: 35.2271 + miles * mile / 111_320,
                longitude: -80.8431
            )
        }
        let start = coordinate(atMiles: 0)
        let end = coordinate(atMiles: totalMiles)
        let line = [0, 150, 168, 310, 488, 836, 926, totalMiles].map { coordinate(atMiles: $0) }
        func station(_ name: String, miles: Double, detourMiles: Double) -> SuggestedStop {
            SuggestedStop(
                name: name,
                coordinate: coordinate(atMiles: miles),
                category: .gas,
                distanceAlongRoute: miles * mile,
                detourMeters: detourMiles * mile
            )
        }

        let shelby = station("Shelby", miles: 150, detourMiles: 1)
        let bypass = station("Bypass", miles: 168, detourMiles: 10)
        let memphis = station("Memphis", miles: 310, detourMiles: 1)
        let amarillo = station("Amarillo", miles: 488, detourMiles: 0)
        let barstow = station("Barstow", miles: 836, detourMiles: 0)
        let needles = station("Needles", miles: 926, detourMiles: 0)
        let stations = [shelby, bypass, memphis, amarillo, barstow, needles]

        XCTAssertLessThanOrEqual(shelby.distanceAlongRoute + shelby.detourMeters, 170 * mile)
        XCTAssertLessThanOrEqual(bypass.distanceAlongRoute, 170 * mile)
        XCTAssertGreaterThan(bypass.distanceAlongRoute + bypass.detourMeters, 170 * mile)
        XCTAssertGreaterThan(amarillo.distanceAlongRoute - memphis.distanceAlongRoute, 170 * mile)
        XCTAssertLessThanOrEqual(amarillo.distanceAlongRoute - memphis.distanceAlongRoute, 200 * mile)
        XCTAssertGreaterThan(barstow.distanceAlongRoute - amarillo.distanceAlongRoute, 200 * mile)

        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 200 * mile
        viewModel.waypoints = [
            Waypoint(name: "Charlotte", coordinate: start),
            Waypoint(name: "Los Angeles", coordinate: end),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.legs = [
            StubMKRoute(
                name: "Charlotte to LA",
                coordinates: line,
                distance: totalMiles * mile,
                expectedTravelTime: (totalMiles / 55) * 3_600,
                hasHighways: true
            )
        ]
        viewModel.gasStations = stations

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(
            viewModel.waypoints.map(\.name),
            ["Charlotte", "Shelby", "Memphis", "Amarillo", "Los Angeles"]
        )
        XCTAssertEqual(viewModel.waypoints.map(\.isGasFill), [false, true, true, true, false])
        XCTAssertFalse(viewModel.waypoints.contains {
            ["Bypass", "Barstow", "Needles"].contains($0.name)
        })
        let summaryNames = viewModel.visibleFuelPlanEntries.compactMap { entry -> String? in
            if case .recommended(let stop) = entry { return stop.name }
            return nil
        }
        let onRoute = Set(viewModel.waypoints.map(\.name))
        XCTAssertTrue(summaryNames.allSatisfy { onRoute.contains($0) })
        XCTAssertFalse(summaryNames.contains("Needles"))
        XCTAssertFalse(summaryNames.contains("Barstow"))
    }

    /// The UI fixture's 100-mile tank. Search adds On Route Fuel at mile 150
    /// as a plain waypoint (`isGasFill` stays false). The destination is 130
    /// miles past that fill, so Shell Knoxville at mile 230 (80 miles after
    /// the fill, 50 miles before the destination, detour 800 m) is inside
    /// both the tank and the 0.85 reserve and has to be inserted. Pilot at
    /// mile 80 is what makes the fill reachable. Measuring Shell from the
    /// origin, or from Pilot, is a 150-mile hop and drops a stop the ride
    /// needs.
    func testSelectRecommendedKeepsShellAfterTheOnRouteFillSearchAdded() async {
        let mile = UITestFixture.metersPerMile
        let line = [0, 40, 80, 150, 230, UITestFixture.routeMiles].map {
            UITestFixture.coordinate(milesNorth: $0, eastMeters: 0)
        }
        func station(_ place: UITestFixture.Place) -> SuggestedStop {
            SuggestedStop(
                name: place.name,
                coordinate: UITestFixture.coordinate(milesNorth: place.milesNorth, eastMeters: 0),
                category: .gas,
                distanceAlongRoute: place.milesNorth * mile,
                detourMeters: place.eastMeters
            )
        }
        let onRoute = UITestFixture.places.first { $0.name == "On Route Fuel" }!
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 100 * mile
        viewModel.waypoints = [
            Waypoint(name: "Test Origin", coordinate: line[0]),
            Waypoint(
                name: "On Route Fuel",
                coordinate: UITestFixture.coordinate(milesNorth: onRoute.milesNorth, eastMeters: 0)
            ),
            Waypoint(name: "Test Destination", coordinate: line[line.count - 1]),
        ]
        XCTAssertFalse(viewModel.waypoints[1].isGasFill)
        viewModel.plannedCorridor = [line]
        viewModel.legs = [
            StubMKRoute(
                name: "Stub Fastest",
                coordinates: line,
                distance: UITestFixture.totalMeters,
                expectedTravelTime: (UITestFixture.routeMiles / 55) * 3_600,
                hasHighways: true
            )
        ]
        viewModel.gasStations = UITestFixture.places.filter(\.gasStation).map(station)

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(
            viewModel.waypoints.map(\.name),
            ["Test Origin", "Pilot Madison", "On Route Fuel", "Shell Knoxville", "Test Destination"]
        )
    }

    /// A pump already on the route that is itself past the tank does not
    /// unlock a recommendation beyond it. The rider cannot reach that fill,
    /// so the dry gap is still a gap.
    func testSelectRecommendedDoesNotUseAnUnreachableOnRoutePumpAsAFill() async {
        let mile = AppSettings.metersPerMile
        func coordinate(atMiles miles: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: 33.4735 + miles * mile / 111_320,
                longitude: -82.0105
            )
        }
        func station(_ name: String, miles: Double) -> SuggestedStop {
            SuggestedStop(
                name: name,
                coordinate: coordinate(atMiles: miles),
                category: .gas,
                distanceAlongRoute: miles * mile,
                detourMeters: 0
            )
        }
        let line = [0, 250, 320, 400].map { coordinate(atMiles: $0) }
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 100 * mile
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: line[0]),
            Waypoint(name: "Stranded", coordinate: coordinate(atMiles: 250)),
            Waypoint(name: "End", coordinate: line[line.count - 1]),
        ]
        XCTAssertFalse(viewModel.waypoints[1].isGasFill)
        viewModel.plannedCorridor = [line]
        viewModel.legs = [
            StubMKRoute(
                name: "Stub Fastest",
                coordinates: line,
                distance: 400 * mile,
                expectedTravelTime: (400 / 55) * 3_600,
                hasHighways: true
            )
        ]
        viewModel.gasStations = [station("Stranded", miles: 250), station("After", miles: 320)]

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Stranded", "End"])
    }

    /// 200 mi tank. Where nothing sits inside 170 mi, Select recommended
    /// inserts the nearest station still inside the tank and leaves a
    /// station past 200 mi off the route.
    func testSelectRecommendedInsertsTheNearestStationInEachReserveGap() async {
        let mile = AppSettings.metersPerMile
        let totalMiles = 1_000.0
        func coordinate(atMiles miles: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: 35.0 + miles * mile / 111_320,
                longitude: -80.0
            )
        }
        func station(_ name: String, miles: Double) -> SuggestedStop {
            SuggestedStop(
                name: name,
                coordinate: coordinate(atMiles: miles),
                category: .gas,
                distanceAlongRoute: miles * mile,
                detourMeters: 0
            )
        }
        func route(stations: [SuggestedStop]) -> RoutePlannerViewModel {
            let line = [0, 165, 196, totalMiles].map { coordinate(atMiles: $0) }
            let viewModel = RoutePlannerViewModel()
            viewModel.fuelRangeMeters = 200 * mile
            viewModel.waypoints = [
                Waypoint(name: "Start", coordinate: line[0]),
                Waypoint(name: "End", coordinate: line[line.count - 1]),
            ]
            viewModel.plannedCorridor = [line]
            viewModel.legs = [
                StubMKRoute(
                    name: "Start to End",
                    coordinates: line,
                    distance: totalMiles * mile,
                    expectedTravelTime: (totalMiles / 55) * 3_600,
                    hasHighways: true
                )
            ]
            viewModel.gasStations = stations
            return viewModel
        }

        let chosen = route(stations: [
            station("Near A", miles: 193),
            station("Far A", miles: 199),
            station("Near B", miles: 373),
            station("Far B", miles: 389),
            station("Past", miles: 603),
        ])
        await chosen.toggleRecommendedFuelSelection()
        XCTAssertEqual(chosen.waypoints.map(\.name), ["Start", "Near A", "Near B", "End"])
        XCTAssertFalse(chosen.waypoints.contains { ["Far A", "Far B", "Past"].contains($0.name) })
        XCTAssertFalse(
            chosen.waypointRangeNotices(at: 1).joined(separator: " ").contains("No fuel within range")
        )
        XCTAssertNil(RoutePlannerViewModel.pastFullTankNote(hopMeters: 193 * mile, tankMeters: 200 * mile))
        XCTAssertEqual(
            RoutePlannerViewModel.pastFullTankNote(hopMeters: 230 * mile, tankMeters: 200 * mile),
            "Past full tank"
        )
        let nearA = station("Near A", miles: 193)
        let past = station("Past", miles: 603)
        chosen.fuelPlanEntries = [
            .recommended(nearA),
            .pastRange(past),
        ]
        XCTAssertNil(chosen.fuelListNote(for: nearA))
        XCTAssertEqual(chosen.fuelListNote(for: past), "Past full tank")
        XCTAssertFalse(chosen.fuelStopRidingCaption(for: nearA).contains("Past full tank"))
        XCTAssertFalse(chosen.fuelStopRidingCaption(for: nearA).contains("No fuel within range"))
    }

    /// Amarillo → LA length. Ten thousand vertices, so a main-thread walk of
    /// the polyline is obvious.
    private func makeLongFuelRoute() -> (
        viewModel: RoutePlannerViewModel,
        stations: [SuggestedStop],
        suggestions: [SuggestedStop],
        line: [CLLocationCoordinate2D]
    ) {
        let mile = AppSettings.metersPerMile
        let totalMiles = 2_500.0
        let pointCount = 10_000
        func coordinate(atMiles miles: Double) -> CLLocationCoordinate2D {
            CLLocationCoordinate2D(
                latitude: 35.222 + miles * mile / 111_320,
                longitude: -101.8313
            )
        }
        let line = (0...pointCount).map { index in
            coordinate(atMiles: totalMiles * Double(index) / Double(pointCount))
        }
        let stationMiles = (0..<40).map { index in
            60.0 + Double(index) * (2_380.0 / 39.0)
        }
        let stations = stationMiles.map { miles in
            SuggestedStop(
                name: "Station \(Int(miles.rounded()))",
                coordinate: coordinate(atMiles: miles),
                category: .gas,
                distanceAlongRoute: miles * mile,
                detourMeters: 0
            )
        }
        let route = StubMKRoute(
            name: "Amarillo to LA",
            coordinates: line,
            distance: totalMiles * mile,
            expectedTravelTime: (totalMiles / 55) * 3_600,
            hasHighways: true
        )
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 200 * mile
        viewModel.waypoints = [
            Waypoint(name: "Amarillo", coordinate: line[0]),
            Waypoint(name: "Los Angeles", coordinate: line[line.count - 1]),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.legs = [route]
        viewModel.gasStations = stations
        viewModel.selectedCategory = .gas
        let suggestions = (0..<40).map { index in
            let miles = 70.0 + Double(index) * 60.0
            return SuggestedStop(
                name: "Suggestion \(index)",
                coordinate: coordinate(atMiles: miles),
                category: .gas,
                distanceAlongRoute: miles * mile,
                detourMeters: 0
            )
        }
        viewModel.suggestedStops = suggestions
        return (viewModel, stations, suggestions, line)
    }

    /// The spinner flag is up within half a second, and the main actor keeps
    /// getting turns for the whole scan. A few seconds of background work is
    /// fine. A blocked main thread would show up as a long gap between turns.
    func testSelectRecommendedDoesNotBlockTheMainActor() async {
        let made = makeLongFuelRoute()
        let viewModel = made.viewModel
        let started = Date()
        // `Task` has no `isCompleted` in Swift 5.10 or Swift 6. The task
        // sets this on the main actor as its last step.
        let completion = FuelSelectionCompletion()
        let selection = Task { @MainActor in
            await viewModel.toggleRecommendedFuelSelection()
            completion.isCompleted = true
        }
        var sawSpinner = false
        while Date().timeIntervalSince(started) < 0.5 {
            if viewModel.isSelectingRecommendedFuel {
                sawSpinner = true
                break
            }
            if completion.isCompleted { break }
            await Task.yield()
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertTrue(sawSpinner || completion.isCompleted)
        if !completion.isCompleted {
            XCTAssertTrue(viewModel.isSelectingRecommendedFuel)
        }

        var turns = 0
        var longestGap: TimeInterval = 0
        while !completion.isCompleted, Date().timeIntervalSince(started) < 5 {
            let began = Date()
            await Task.yield()
            longestGap = max(longestGap, Date().timeIntervalSince(began))
            turns += 1
        }
        await selection.value
        XCTAssertLessThan(longestGap, 0.5, "Select recommended blocked the main actor")
        if Date().timeIntervalSince(started) > 0.5 {
            XCTAssertGreaterThan(turns, 1)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        XCTAssertFalse(viewModel.isSelectingRecommendedFuel)
        XCTAssertGreaterThan(viewModel.waypoints.count, 2)
    }

    /// Reading the suggestion list and the fuel plan, which the sheet does
    /// once per row, stays under a tenth of a second for 40 stations and
    /// 40 suggestions. The scan itself may take a few seconds.
    func testSelectRecommendedAndFuelListFinishWithinTwoSecondsOnALongRoute() async {
        let made = makeLongFuelRoute()
        let viewModel = made.viewModel
        let stations = made.stations
        let suggestions = made.suggestions

        let mile = AppSettings.metersPerMile
        let started = Date()
        await viewModel.toggleRecommendedFuelSelection()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)

        let read = Date()
        for _ in 0..<40 {
            _ = viewModel.suggestionListStops
            _ = viewModel.addableSuggestions
            _ = viewModel.visibleFuelPlanEntries
            for stop in stations + suggestions {
                _ = viewModel.isStopOnRoute(stop)
                _ = viewModel.isShownAsFuelPlanRow(stop)
                _ = viewModel.recommendedFuelAccessibility(for: stop)
                _ = viewModel.distanceFromStart(of: stop)
                _ = viewModel.isBeyondRemainingRange(
                    distanceAlongRoute: viewModel.distanceFromStart(of: stop)
                )
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(read), 0.1)
        XCTAssertFalse(viewModel.isSelectingRecommendedFuel)
        XCTAssertEqual(AccessibilityID.fuelSelectingSpinner, "fuel.selecting.spinner")
        XCTAssertEqual(RoutePlannerViewModel.fuelSelectionStatus, "Finding fuel stops…")
        XCTAssertGreaterThan(viewModel.waypoints.count, 2)
        let sample = stations[20]
        // Stops are already on the route, so the cached mile mark follows the
        // published corridor (or the leg polylines once that corridor is gone),
        // not the straight line from before the insert.
        let routePolylines = viewModel.plannedCorridor.contains(where: { $0.count > 1 })
            ? viewModel.plannedCorridor
            : viewModel.legs.map { RouteGeometry.coordinates(of: $0.polyline) }
        let projected = RoutePlannerViewModel.distanceFromStart(
            of: sample,
            alongPolylines: routePolylines
        )
        XCTAssertEqual(viewModel.distanceFromStart(of: sample), projected, accuracy: 1)
        XCTAssertGreaterThan(projected, 1_000 * mile)
    }
}
