import XCTest
import MapKit
@testable import PerfectRouter

/// Mid-plan fuel-range changes must cancel the in-flight plan and let only
/// a search that actually returned decide that a route has no gas.
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

    func testNoGasCopyOnlyAfterACompletedEmptySearch() {
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .pending,
            isCalculating: true,
            isSearchingGas: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .pending,
            isCalculating: false,
            isSearchingGas: true,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .failed,
            isCalculating: false,
            isSearchingGas: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .loaded,
            isCalculating: false,
            isSearchingGas: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertTrue(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .empty,
            isCalculating: false,
            isSearchingGas: false,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .empty,
            isCalculating: false,
            isSearchingGas: true,
            gasStationCount: 0,
            fuelStopCount: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowNoGasStations(
            loadState: .empty,
            isCalculating: false,
            isSearchingGas: false,
            gasStationCount: 2,
            fuelStopCount: 0
        ))
    }

    func testFailedLoadShowsRetryNotEmptyCopy() {
        XCTAssertEqual(
            RoutePlannerViewModel.gasLoadFailedCopy,
            "Couldn't load gas — tap to retry"
        )
        XCTAssertTrue(RoutePlannerViewModel.shouldShowGasLoadFailed(
            loadState: .failed,
            isCalculating: false,
            isSearchingGas: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowGasLoadFailed(
            loadState: .failed,
            isCalculating: true,
            isSearchingGas: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowGasLoadFailed(
            loadState: .empty,
            isCalculating: false,
            isSearchingGas: false
        ))
    }

    func testAllThrottledOrAllFailedIsNotAnEmptyCorridor() {
        XCTAssertEqual(
            GasSearchStatus.resolve(
                GasSampleTally(succeeded: 0, failed: 0, throttled: 12, cancelled: false),
                stopCount: 0
            ),
            .failed
        )
        XCTAssertEqual(
            GasSearchStatus.resolve(
                GasSampleTally(succeeded: 0, failed: 4, throttled: 0, cancelled: false),
                stopCount: 0
            ),
            .failed
        )
        XCTAssertEqual(
            GasSearchStatus.resolve(
                GasSampleTally(succeeded: 0, failed: 0, throttled: 0, cancelled: false),
                stopCount: 0
            ),
            .failed
        )
        // Every sample returned and none had a station. That is the empty corridor.
        XCTAssertEqual(
            GasSearchStatus.resolve(
                GasSampleTally(succeeded: 32, failed: 0, throttled: 0, cancelled: false),
                stopCount: 0
            ),
            .completed
        )
    }

    /// The same owner check that passed on 628dbf0. One empty MKLocalSearch
    /// response does not make the other throttled samples a finished corridor.
    func testOneEmptyHitAmongThrottlesIsFailedNotEmpty() {
        let status = GasSearchStatus.resolve(
            GasSampleTally(succeeded: 1, failed: 0, throttled: 31, cancelled: false),
            stopCount: 0
        )
        XCTAssertEqual(status, .failed)
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 4,
                taskCancelled: false,
                status: status,
                stopCount: 0
            ),
            .failed
        )
        XCTAssertEqual(
            GasSearchStatus.resolve(
                GasSampleTally(succeeded: 1, failed: 0, throttled: 31, cancelled: false),
                stopCount: 4
            ),
            .completed
        )
    }

    func testCancelledTallyIsNotPublishedEvenIfSamplesHadSucceeded() {
        XCTAssertEqual(
            GasSearchStatus.resolve(
                GasSampleTally(succeeded: 3, failed: 0, throttled: 0, cancelled: true),
                stopCount: 6
            ),
            .cancelled
        )
    }

    func testMapThrottleCodeIsNotANormalFailure() {
        let throttled = NSError(
            domain: MKErrorDomain,
            code: Int(MKError.Code.loadingThrottled.rawValue)
        )
        let other = NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue))
        XCTAssertTrue(StopSuggestionService.isMapSearchThrottled(throttled))
        XCTAssertFalse(StopSuggestionService.isMapSearchThrottled(other))
        XCTAssertFalse(StopSuggestionService.isMapSearchThrottled(
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        ))
    }

    /// The hole on 628dbf0: an empty array from the current, non-cancelled
    /// owner was published as "no gas". A throttled run is that empty array.
    func testThrottledRunPublishesFailedNotEmpty() {
        let status = GasSearchStatus.resolve(
            GasSampleTally(succeeded: 0, failed: 0, throttled: 32, cancelled: false),
            stopCount: 0
        )
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 4,
                taskCancelled: false,
                status: status,
                stopCount: 0
            ),
            .failed
        )
    }

    func testCompletedSearchWithZeroStopsIsTheOnlyEmptyPublish() {
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 4,
                taskCancelled: false,
                status: .completed,
                stopCount: 0
            ),
            .empty
        )
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 4,
                taskCancelled: false,
                status: .completed,
                stopCount: 3
            ),
            .loaded
        )
    }

    func testCancelledOrSupersededOwnerPublishesNothing() {
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 4,
                taskCancelled: true,
                status: .completed,
                stopCount: 0
            ),
            .drop
        )
        XCTAssertEqual(
            GasPublish.decide(
                generation: 3,
                currentGeneration: 4,
                taskCancelled: false,
                status: .completed,
                stopCount: 0
            ),
            .drop
        )
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 4,
                taskCancelled: false,
                status: .cancelled,
                stopCount: 0
            ),
            .drop
        )
        XCTAssertEqual(
            GasPublish.decide(
                generation: 4,
                currentGeneration: 5,
                taskCancelled: true,
                status: .failed,
                stopCount: 8
            ),
            .drop
        )
    }

    func testDepartureChangeDuringPlanRestartsTheRoute() {
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForDepartureChange(
                isCalculating: true,
                isSearchingGas: false,
                hasLegs: false,
                loadState: .pending
            ),
            .route
        )
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForDepartureChange(
                isCalculating: true,
                isSearchingGas: true,
                hasLegs: true,
                loadState: .pending
            ),
            .route
        )
    }

    func testDepartureChangeDuringGasSearchRestartsGas() {
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForDepartureChange(
                isCalculating: false,
                isSearchingGas: true,
                hasLegs: true,
                loadState: .pending
            ),
            .gas
        )
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForDepartureChange(
                isCalculating: false,
                isSearchingGas: false,
                hasLegs: true,
                loadState: .pending
            ),
            .gas
        )
    }

    func testRapidDepartureTicksProduceOneRestart() {
        let latest = 8
        let commits = (1...latest).filter { tick in
            RoutePlannerViewModel.shouldCommitDeparture(
                tick: tick,
                latestTick: latest,
                cancelled: tick != latest
            )
        }
        XCTAssertEqual(commits, [latest])
        XCTAssertFalse(RoutePlannerViewModel.shouldCommitDeparture(
            tick: latest,
            latestTick: latest,
            cancelled: true
        ))
        XCTAssertEqual(RoutePlannerViewModel.departureSettleDelay, .milliseconds(400))
    }

    func testIdleDepartureChangeDoesNotRestartTheSearch() {
        XCTAssertEqual(
            RoutePlannerViewModel.planRestartForDepartureChange(
                isCalculating: false,
                isSearchingGas: false,
                hasLegs: true,
                loadState: .loaded
            ),
            .local
        )
    }

    func testFuelGapWarningRequiresACleanFinishedSearch() {
        XCTAssertTrue(RoutePlannerViewModel.gasCoverageIsTrusted(
            status: .completed,
            failed: 0,
            throttled: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.gasCoverageIsTrusted(
            status: .completed,
            failed: 0,
            throttled: 2
        ))
        XCTAssertFalse(RoutePlannerViewModel.gasCoverageIsTrusted(
            status: .failed,
            failed: 0,
            throttled: 32
        ))
        XCTAssertFalse(RoutePlannerViewModel.gasCoverageIsTrusted(
            status: .cancelled,
            failed: 0,
            throttled: 0
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowFuelGapWarning(
            hasFuelGap: true,
            coverageTrusted: false,
            loadState: .loaded,
            isCalculating: false,
            isSearchingGas: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowFuelGapWarning(
            hasFuelGap: true,
            coverageTrusted: true,
            loadState: .failed,
            isCalculating: false,
            isSearchingGas: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowFuelGapWarning(
            hasFuelGap: true,
            coverageTrusted: true,
            loadState: .loaded,
            isCalculating: true,
            isSearchingGas: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowFuelGapWarning(
            hasFuelGap: true,
            coverageTrusted: true,
            loadState: .empty,
            isCalculating: false,
            isSearchingGas: true
        ))
        XCTAssertTrue(RoutePlannerViewModel.shouldShowFuelGapWarning(
            hasFuelGap: true,
            coverageTrusted: true,
            loadState: .loaded,
            isCalculating: false,
            isSearchingGas: false
        ))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowFuelGapWarning(
            hasFuelGap: false,
            coverageTrusted: true,
            loadState: .loaded,
            isCalculating: false,
            isSearchingGas: false
        ))
    }
}
