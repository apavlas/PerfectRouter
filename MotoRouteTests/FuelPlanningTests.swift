import XCTest
import CoreLocation
@testable import MotoRoute

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
}
