import CoreLocation
import XCTest
@testable import PerfectRouter

/// fuel-v2: leg alternates stay inside the tank from the previous fill,
/// early pumps are dropped unless they are the only option, and an
/// opposite-side gap filler is tagged.
@MainActor
final class FuelAlternatesTests: XCTestCase {

    private let mile = UITestFixture.metersPerMile
    private var tank: CLLocationDistance { 100 * mile }

    private func station(_ name: String, _ miles: Double, recommended: Bool = false) -> GasListGrouping.Station {
        GasListGrouping.Station(id: UUID(), name: name, distance: miles * mile,
                                isRecommended: recommended, pastRange: false)
    }

    private func names(_ grouping: GasListGrouping) -> [[String]] {
        grouping.days.flatMap(\.legs).map { ($0.preview + $0.overflow).map(\.name) }
    }

    // (1) Reach from the previous stop, with margin.
    func testAlternateAt99MilesFromThePreviousFillIsDroppedOnA100MileTank() {
        let kept = GasListGrouping.eligibleAlternates(
            [station("In reach", 170), station("Edge 99", 179)],
            legStart: 80 * mile, hasRecommended: true, rangeMeters: tank)
        XCTAssertEqual(kept.map(\.name), ["In reach"])
    }

    func testGroupedLegListsOnlyReachableAlternates() {
        let grouping = GasListGrouping.make(
            stations: [station("A 50", 50), station("Fill 80", 80, recommended: true),
                       station("Fill 160", 160, recommended: true), station("B 120", 120),
                       station("Far 178", 178)],
            fillDistances: [80 * mile, 160 * mile], daySpans: [], totalDistance: 200 * mile,
            usesMetric: false, rangeMeters: tank)
        let all = names(grouping).flatMap { $0 }
        XCTAssertTrue(all.contains("B 120"))
        XCTAssertFalse(all.contains("Far 178"), "98 mi past the 80 mi fill is beyond 90% of the tank")
    }

    func testPastRangeLegKeepsItsOnlyPumps() {
        let kept = GasListGrouping.eligibleAlternates(
            [station("Dry", 400)], legStart: 230 * mile, hasRecommended: false, rangeMeters: tank)
        XCTAssertEqual(kept.map(\.name), ["Dry"])
    }

    // (2) Early alternates.
    func testAlternatesInTheFirstFifthOfTheTankAreDropped() {
        let kept = GasListGrouping.eligibleAlternates(
            [station("Home", 2), station("Mile 15", 15), station("Mile 40", 40)],
            legStart: 0, hasRecommended: true, rangeMeters: tank)
        XCTAssertEqual(kept.map(\.name), ["Mile 40"])
    }

    func testEarlyPumpStaysWhenItIsTheOnlyOption() {
        let kept = GasListGrouping.eligibleAlternates(
            [station("Only pump", 10)], legStart: 0, hasRecommended: false, rangeMeters: tank)
        XCTAssertEqual(kept.map(\.name), ["Only pump"])
    }

    func testNoRangeLeavesAlternatesUntouched() {
        let input = [station("Home", 2), station("Far", 300)]
        XCTAssertEqual(GasListGrouping.eligibleAlternates(input, legStart: 0, hasRecommended: true,
                                                          rangeMeters: 0), input)
    }

    // (3) Across divided highway.
    private func pump(_ name: String, _ miles: Double) -> SuggestedStop {
        SuggestedStop(name: name, coordinate: UITestFixture.coordinate(milesNorth: miles, eastMeters: 300),
                      category: .gas, distanceAlongRoute: miles * mile)
    }

    func testOppositeSideGapFillerIsTaggedAcrossDividedHighway() {
        let near = pump("Near", 60), across = pump("Across", 130), far = pump("Far", 200)
        let travelSide = [near, far]
        let pool = RoutePlannerViewModel.preferredFuelPool(
            from: [near, across, far], travelSide: travelSide,
            totalDistance: 250 * mile, limit: tank * RoutePlannerViewModel.fuelSafetyFactor)
        let ids = RoutePlannerViewModel.acrossDividedHighwayIDs(pool: pool, travelSide: travelSide)
        XCTAssertEqual(ids, [across.id])
        XCTAssertEqual(GasListGrouping.acrossDividedHighwayTag, "Across divided highway")
    }

    func testNoTagWhenTheTravelSideIsEmptyOrHasNoGap() {
        let a = pump("A", 50), b = pump("B", 120)
        XCTAssertTrue(RoutePlannerViewModel.acrossDividedHighwayIDs(pool: [a, b], travelSide: []).isEmpty)
        let pool = RoutePlannerViewModel.preferredFuelPool(
            from: [a, b, pump("C", 100)], travelSide: [a, b],
            totalDistance: 180 * mile, limit: tank * RoutePlannerViewModel.fuelSafetyFactor)
        XCTAssertTrue(RoutePlannerViewModel.acrossDividedHighwayIDs(pool: pool, travelSide: [a, b]).isEmpty)
    }
}
