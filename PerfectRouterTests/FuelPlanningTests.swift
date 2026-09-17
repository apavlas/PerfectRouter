import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for the pure fuel-stop planner. These exercise the greedy
/// selection logic (comfort window, hard-range fallback, and fuel gaps)
/// without any networking.
final class FuelPlanningTests: XCTestCase {

    /// Builds a gas stop at a given distance along the route.
    private func gas(at meters: CLLocationDistance) -> SuggestedStop {
        SuggestedStop(
            name: "Gas @\(Int(meters))",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            category: .gas,
            distanceAlongRoute: meters
        )
    }

    func testShortRideNeedsNoFuelStops() {
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 50_000)],
            totalDistance: 100_000,
            range: 160_900
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertFalse(hasGap)
    }

    func testLongRidePicksFarthestWithinComfortWindow() {
        // Stations every 20 km; range 100 km, comfort window = 85 km.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000
        )
        XCTAssertFalse(hasGap)
        // From 0: farthest <= 85 km is 80 km. From 80: farthest <= 165 km is 160 km.
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])
    }

    func testFallsBackToHardRangeWhenComfortWindowEmpty() {
        // Only station sits beyond the comfort window (85 km) but within range (100 km).
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 95_000)],
            totalDistance: 150_000,
            range: 100_000
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [95_000])
    }

    func testFlagsFuelGapWhenNoReachableStation() {
        // Stations only near the start; a long dry stretch follows.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 20_000), gas(at: 40_000)],
            totalDistance: 300_000,
            range: 100_000
        )
        XCTAssertTrue(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [40_000])
    }

    func testNoStationsAtAllFlagsGap() {
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [],
            totalDistance: 300_000,
            range: 100_000
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertTrue(hasGap)
    }

    func testRiderAddedGasFillPlansLaterPumpsFromThatPoint() {
        // Same stations as the long-ride case. A fill at the first auto pick
        // (80 km) drops that recommendation; the next tank is planned from 80.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: [80_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [160_000])
    }

    func testMidPlanFillDropsEarlierAutoRecommendations() {
        // Unfilled: 80 then 160. A fill at 50 km replans from there — 80 is
        // no longer the pick; farthest in the 50+85 km comfort window is 120.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (withoutFill, _) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000
        )
        XCTAssertEqual(withoutFill.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])

        let (withFill, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: [50_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(withFill.map { Int($0.distanceAlongRoute) }, [120_000, 200_000])
        XCTAssertFalse(withFill.contains { Int($0.distanceAlongRoute) == 80_000 })
    }

    func testGapWarningUsesRemainingStretchAfterFill() {
        // Stations only near the start. A fill at 200 km leaves 100 km — one
        // tank — so the dry stretch behind the fill is not a gap.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 20_000), gas(at: 40_000)],
            totalDistance: 300_000,
            range: 100_000,
            filledAt: [200_000]
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertFalse(hasGap)
    }

    func testGapAfterFillWhenRemainingStretchIsDry() {
        // Fill at 40 km; nothing reachable in the remaining 260 km.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 20_000), gas(at: 40_000)],
            totalDistance: 300_000,
            range: 100_000,
            filledAt: [40_000]
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertTrue(hasGap)
    }

    func testNonGasFillDistancesAreIgnoredByCaller() {
        // Planner only sees distances in `filledAt`. An empty list (food /
        // scenic waypoints) keeps the start-of-ride tank, same as before.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: []
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])
    }

    func testComfortWindowUnchangedWithFill() {
        XCTAssertEqual(RoutePlannerViewModel.fuelSafetyFactor, 0.85, accuracy: 0.0001)
        // Only station sits beyond comfort (50+85=135) but within hard range
        // (50+100=150). Same 85% window, just measured from the fill.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 140_000)],
            totalDistance: 200_000,
            range: 100_000,
            filledAt: [50_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [140_000])
    }

    // MARK: - Food at the stop

    func testPrefersGasWithFoodOverFartherGasOnly() {
        // Both sit in the 85 km comfort window. Gas-only is farther; food wins.
        let withFood = gas(at: 60_000)
        let gasOnly = gas(at: 80_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [withFood, gasOnly],
            totalDistance: 150_000,
            range: 100_000,
            preferringFoodAt: [withFood.id]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [withFood.id])
    }

    func testPicksFarthestFoodStopInsideTheTankWindow() {
        let earlyFood = gas(at: 40_000)
        let laterFood = gas(at: 80_000)
        let gasOnly = gas(at: 84_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [earlyFood, laterFood, gasOnly],
            totalDistance: 150_000,
            range: 100_000,
            preferringFoodAt: [earlyFood.id, laterFood.id]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [laterFood.id])
    }

    func testFallsBackToGasOnlyWhenNoFoodInWindow() {
        let only = gas(at: 80_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [only],
            totalDistance: 150_000,
            range: 100_000,
            preferringFoodAt: [UUID()]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000])
    }

    func testHardRangeFallbackPrefersFood() {
        // Comfort window (85 km) is empty. Both candidates sit in hard range;
        // the farther one is gas-only, so food at 95 km wins.
        let withFood = gas(at: 95_000)
        let gasOnly = gas(at: 99_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [withFood, gasOnly],
            totalDistance: 150_000,
            range: 100_000,
            preferringFoodAt: [withFood.id]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [withFood.id])
    }

    func testEmptyPreferringFoodKeepsFarthestInWindow() {
        // Default / no food data: same pick as the original long-ride case.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            preferringFoodAt: []
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])
    }

    // MARK: - Tank-interval search grid

    func testFuelSearchDistancesAnchorToTankInterval() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 250_000,
            range: 100_000
        )
        let interval = 100_000 * RoutePlannerViewModel.fuelSafetyFactor
        XCTAssertTrue(distances.contains { abs($0 - interval) < 1 }, "missing comfort-edge \(interval)")
        XCTAssertTrue(distances.contains { abs($0 - interval * 2) < 1 }, "missing second tank \(interval * 2)")
        XCTAssertTrue(distances.allSatisfy { $0 < 250_000 })
    }

    func testFuelSearchDistancesAreNotATwentyFiveMileGrid() {
        let tankMeters = 100 * AppSettings.metersPerMile
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 400 * AppSettings.metersPerMile,
            range: tankMeters
        )
        let twentyFiveMiles = 25 * AppSettings.metersPerMile
        // First tank-interval point is ~85 mi, not 25.
        XCTAssertGreaterThan(distances.min() ?? 0, twentyFiveMiles)
        XCTAssertTrue(distances.contains { abs($0 - tankMeters * RoutePlannerViewModel.fuelSafetyFactor) < 1 })
    }

    func testFuelSearchDistancesCapAtMax() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 5_000_000,
            range: 100_000,
            maxCount: 16
        )
        XCTAssertEqual(distances.count, 16)
        XCTAssertEqual(distances, distances.sorted())
    }

    func testShortRideStillGetsASearchPoint() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 50_000,
            range: 100_000
        )
        XCTAssertEqual(distances.count, 1)
        XCTAssertEqual(distances[0], 25_000, accuracy: 1)
    }

    func testGasStopsWithNearbyFoodMarksInRadius() {
        let pump = SuggestedStop(
            name: "Pump",
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0),
            category: .gas,
            distanceAlongRoute: 80_000
        )
        // ~0.001° latitude ≈ 111 m — inside the 1.5 km food radius.
        let diner = SuggestedStop(
            name: "Diner",
            coordinate: CLLocationCoordinate2D(latitude: 40.001, longitude: -75.0),
            category: .food,
            distanceAlongRoute: 80_000
        )
        let ids = RoutePlannerViewModel.gasStopsWithNearbyFood([pump], food: [diner])
        XCTAssertEqual(ids, [pump.id])
    }

    func testGasStopsWithNearbyFoodIgnoresFarFood() {
        let pump = SuggestedStop(
            name: "Pump",
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0),
            category: .gas,
            distanceAlongRoute: 80_000
        )
        // ~0.05° latitude ≈ 5.5 km — outside the 1.5 km food radius.
        let diner = SuggestedStop(
            name: "Far Diner",
            coordinate: CLLocationCoordinate2D(latitude: 40.05, longitude: -75.0),
            category: .food,
            distanceAlongRoute: 80_000
        )
        let ids = RoutePlannerViewModel.gasStopsWithNearbyFood([pump], food: [diner])
        XCTAssertTrue(ids.isEmpty)
    }
}
