import XCTest
@testable import PerfectRouter

/// Mid-plan fuel-range changes must cancel the in-flight plan and let only
/// the replacement search decide that a route has no gas.
final class PlanRestartTests: XCTestCase {

    func testFuelRangeChangeRestartsTheRouteWhileItIsCalculating() {
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForFuelRangeChange(isCalculating: true),
            .route
        )
    }

    func testFuelRangeChangeRestartsGasOnceTheLineExists() {
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForFuelRangeChange(isCalculating: false),
            .gas
        )
    }

    func testNoGasCopyStaysHiddenWhileCalculatingSearchingOrCancelled() {
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            isCalculating: true,
            isSearchingGas: false,
            searchDidFinish: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            isCalculating: false,
            isSearchingGas: true,
            searchDidFinish: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        // Cancelled work never marks the search finished, so an empty list
        // is not an answer yet.
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            isCalculating: false,
            isSearchingGas: false,
            searchDidFinish: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
    }

    func testNoGasCopyShowsOnlyAfterAFinishedSearchFoundNothing() {
        XCTAssertTrue(RoutePlannerViewModel.shouldShowNoGasStations(
            isCalculating: false,
            isSearchingGas: false,
            searchDidFinish: true,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            isCalculating: false,
            isSearchingGas: false,
            searchDidFinish: true,
            gasStationCount: 2,
            fuelStopCount: 0
        ))
    }

    func testStaleOrCancelledGasSearchDoesNotCommit() {
        XCTAssertFalse(RoutePlannerViewModel.shouldCommitGasSearch(
            generation: 1,
            currentGeneration: 2,
            wasCancelled: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldCommitGasSearch(
            generation: 2,
            currentGeneration: 2,
            wasCancelled: true
        ))
        XCTAssertTrue(RoutePlannerViewModel.shouldCommitGasSearch(
            generation: 2,
            currentGeneration: 2,
            wasCancelled: false
        ))
    }
}
