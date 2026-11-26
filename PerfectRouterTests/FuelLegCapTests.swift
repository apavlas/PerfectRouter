import XCTest
import CoreLocation
@testable import PerfectRouter

/// FUEL-10: after Select recommended inserts a fuel stop, the replanned
/// leg into it stays inside the reserve the planner chose it in. Build 15:
/// Twisty, Asheville to Damascus to Blowing Rock, 100 mi tank. The stop at
/// mile 85 came back at mile 102, "Past your range", because the leg to it
/// took a longer curvy alternate.
final class FuelLegCapTests: XCTestCase {
    private let mile = AppSettings.metersPerMile

    func testLegIntoFuelStopIsHeldToTheReserve() {
        let tank = 100 * mile
        let cap = RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 0,
            endsAtFill: true,
            startedAtPlacedFill: false,
            tank: tank
        )
        XCTAssertEqual(cap ?? 0, 85 * mile, accuracy: 1)
        // The build 15 line: 102 mi to the stop does not fit.
        XCTAssertFalse(102 * mile <= (cap ?? .infinity))
    }

    func testEarlierLegsInTheHopShrinkTheCap() {
        let cap = RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 40 * mile,
            endsAtFill: true,
            startedAtPlacedFill: false,
            tank: 100 * mile
        )
        XCTAssertEqual(cap ?? 0, 45 * mile, accuracy: 1)
    }

    func testSpentReserveForcesTheTopRouteIntoAFuelStop() {
        let cap = RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 90 * mile,
            endsAtFill: true,
            startedAtPlacedFill: false,
            tank: 100 * mile
        )
        XCTAssertEqual(cap, 0)
    }

    func testLegAfterAFuelStopIsHeldToWhatIsLeft() {
        let cap = RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 10 * mile,
            endsAtFill: false,
            startedAtPlacedFill: true,
            tank: 100 * mile
        )
        XCTAssertEqual(cap ?? 0, 75 * mile, accuracy: 1)
        XCTAssertNil(RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 90 * mile,
            endsAtFill: false,
            startedAtPlacedFill: true,
            tank: 100 * mile
        ))
    }

    func testRideWithNoFuelStopsIsNotCapped() {
        XCTAssertNil(RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 0,
            endsAtFill: false,
            startedAtPlacedFill: false,
            tank: 100 * mile
        ))
        XCTAssertNil(RoutePlannerViewModel.fuelLegDistanceCap(
            ridden: 0,
            endsAtFill: true,
            startedAtPlacedFill: false,
            tank: 0
        ))
    }

    func testCachedLegOverTheCapIsRoutedAgain() {
        XCTAssertTrue(RoutePlannerViewModel.cachedLegFits(distance: 102 * mile, usedFastestFallback: false, cap: nil))
        XCTAssertFalse(RoutePlannerViewModel.cachedLegFits(distance: 102 * mile, usedFastestFallback: false, cap: 85 * mile))
        XCTAssertTrue(RoutePlannerViewModel.cachedLegFits(distance: 84 * mile, usedFastestFallback: false, cap: 85 * mile))
        XCTAssertTrue(RoutePlannerViewModel.cachedLegFits(distance: 102 * mile, usedFastestFallback: true, cap: 85 * mile))
    }
}
