import CoreLocation
import XCTest
@testable import PerfectRouter

/// B12 fuel acceptance (FUEL-1..4) on canned, deterministic routes.
final class FuelCoverageTests: XCTestCase {
    private let mile = UITestFixture.metersPerMile
    private let tank = 100 * UITestFixture.metersPerMile

    private func pump(_ name: String, _ miles: Double, east: Double = 300) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: UITestFixture.coordinate(milesNorth: miles, eastMeters: east),
            category: .gas,
            distanceAlongRoute: miles * mile
        )
    }

    private func hops(_ plan: FuelPlan, total: CLLocationDistance) -> [CLLocationDistance] {
        let marks = [0] + plan.stops.map(\.distanceAlongRoute) + [total]
        return zip(marks.dropFirst(), marks).map { $0 - $1 }
    }

    private func pastRange(_ plan: FuelPlan) -> [SuggestedStop] {
        plan.entries.compactMap { if case .pastRange(let s) = $0 { return s } else { return nil } }
    }

    // FUEL-1, FUEL-2, FUEL-3 (no warning) on a normal route.
    func testNormalRoutePlansInsideTheTankWithNoWarning() {
        let total = 400 * mile
        let pumps = stride(from: 30.0, through: 390, by: 30).map { pump("P\(Int($0))", $0) }
        let plan = RoutePlannerViewModel.fuelPlan(from: pumps, totalDistance: total, range: tank)
        XCTAssertLessThanOrEqual(plan.stops.first?.distanceAlongRoute ?? .infinity, tank, "FUEL-1")
        XCTAssertTrue(hops(plan, total: total).allSatisfy { $0 <= tank }, "FUEL-2: \(hops(plan, total: total).map { $0 / mile })")
        XCTAssertFalse(plan.hasGap, "FUEL-3")
        XCTAssertTrue(pastRange(plan).isEmpty, "FUEL-3")
    }

    // FUEL-1: travel side has nothing until mile 154 (the Atlanta→I-20 case),
    // the opposite side does. The pool used by the planner must fill it.
    func testOppositeSidePumpsFillATravelSideGap() {
        let total = 400 * mile
        let travel = [154.0, 184, 264, 347].map { pump("T\(Int($0))", $0) }
        let opposite = [40.0, 84, 120].map { pump("O\(Int($0))", $0, east: -300) }
        let pool = RoutePlannerViewModel.preferredFuelPool(
            from: travel + opposite,
            travelSide: travel,
            totalDistance: total,
            limit: tank * RoutePlannerViewModel.fuelSafetyFactor
        )
        XCTAssertEqual(Set(pool.map(\.name)), Set((travel + opposite).map(\.name)))
        let plan = RoutePlannerViewModel.fuelPlan(from: pool, totalDistance: total, range: tank)
        XCTAssertLessThanOrEqual(plan.stops.first?.distanceAlongRoute ?? .infinity, tank, "FUEL-1")
        XCTAssertTrue(hops(plan, total: total).allSatisfy { $0 <= tank }, "FUEL-2")
        XCTAssertFalse(plan.hasGap)
    }

    func testTravelSidePoolIsKeptWhenItHasNoGap() {
        let travel = stride(from: 40.0, through: 360, by: 40).map { pump("T\(Int($0))", $0) }
        let opposite = [pump("O100", 100, east: -300)]
        let pool = RoutePlannerViewModel.preferredFuelPool(
            from: travel + opposite, travelSide: travel,
            totalDistance: 400 * mile, limit: tank * RoutePlannerViewModel.fuelSafetyFactor
        )
        XCTAssertEqual(pool.map(\.name), travel.map(\.name))
    }

    // FUEL-3: a real dry stretch (no pump on either side, 60→200 mi) is the
    // only time the finished plan warns, and the warning sits after the gap.
    func testRealGapWarnsOnTheFinishedPlanAndNamesThatStretch() {
        let total = 300 * mile
        let pumps = [30.0, 60, 200, 240, 280].map { pump("P\(Int($0))", $0) }
        let plan = RoutePlannerViewModel.fuelPlan(from: pumps, totalDistance: total, range: tank)
        XCTAssertTrue(plan.hasGap, "FUEL-3: 140 mi with no pump must warn")
        let flagged = pastRange(plan).map { $0.distanceAlongRoute / mile }
        XCTAssertFalse(flagged.isEmpty)
        XCTAssertTrue(flagged.allSatisfy { $0 >= 200 - 0.5 }, "warning names the leg after the gap: \(flagged)")
        XCTAssertTrue(plan.stops.allSatisfy { $0.distanceAlongRoute <= 60 * mile + 1 || $0.distanceAlongRoute >= 200 * mile - 1 })
    }

    // FUEL-1/2: the gap-fill search covers the stretch before the first pump
    // and after the last one, not only between two found pumps.
    func testDensifyCoversBeforeTheFirstAndAfterTheLastPump() {
        let total = 400 * mile
        let dense = RoutePlannerViewModel.fuelDensifySearchDistances(
            totalDistance: total,
            limit: tank * RoutePlannerViewModel.fuelSafetyFactor,
            stationDistances: [170 * mile, 250 * mile],
            alreadySearched: [85 * mile, 170 * mile, 255 * mile, 340 * mile]
        )
        XCTAssertTrue(dense.contains { $0 < 85 * mile }, "before first pump: \(dense.map { $0 / mile })")
        XCTAssertTrue(dense.contains { $0 > 255 * mile }, "after last pump: \(dense.map { $0 / mile })")
    }
}
