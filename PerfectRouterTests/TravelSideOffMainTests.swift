import XCTest
import CoreLocation
@testable import PerfectRouter

/// Audit item 2: the travel-side scan must not hold the main thread on a
/// long line. A short line is still filtered on the caller; a long one
/// falls back to every station, then the pool is rebuilt when the scan lands.
@MainActor
final class TravelSideOffMainTests: XCTestCase {
    private let mile = UITestFixture.metersPerMile
    private let totalMiles = 300.0

    /// Eastbound line at 35° N, 300 mi long, with `points` vertices.
    private func line(points: Int) -> [CLLocationCoordinate2D] {
        let degreesPerMile = 1.0 / 56.6 // longitude degrees per mile at 35° N
        return (0..<points).map { i in
            let miles = totalMiles * Double(i) / Double(points - 1)
            return CLLocationCoordinate2D(latitude: 35, longitude: -100 + miles * degreesPerMile)
        }
    }

    private func pump(_ name: String, atMiles miles: Double, offsetLatitude: Double) -> SuggestedStop {
        let degreesPerMile = 1.0 / 56.6
        return SuggestedStop(
            name: name,
            coordinate: CLLocationCoordinate2D(
                latitude: 35 + offsetLatitude,
                longitude: -100 + miles * degreesPerMile
            ),
            category: .gas,
            distanceAlongRoute: miles * mile,
            detourMeters: 0
        )
    }

    /// Pumps every 40 mi on one side of the road, and one on the other side
    /// at mile 100. The near side alone never leaves a gap, so the far pump
    /// must not be in the pool once the scan has run.
    private func makeViewModel(points: Int) -> (RoutePlannerViewModel, near: [SuggestedStop], far: SuggestedStop) {
        let coords = line(points: points)
        let south = stride(from: 40.0, through: 280.0, by: 40.0).map {
            pump("South \(Int($0))", atMiles: $0, offsetLatitude: -0.002)
        }
        let north = pump("North 100", atMiles: 100, offsetLatitude: 0.002)
        let stations = south + [north]

        // Which side is "near" depends on the region's driving side; ask the
        // geometry instead of assuming.
        let queries = stations.enumerated().map {
            RouteGeometry.StationProjectionQuery(
                index: $0.offset,
                latitude: $0.element.coordinate.latitude,
                longitude: $0.element.coordinate.longitude
            )
        }
        let keep = Set(RouteGeometry.travelSideIndices(queries: queries, polylines: [coords]))
        let northIsNear = keep.contains(stations.count - 1)
        let near = northIsNear ? [north] : south
        let far = northIsNear ? south[2] : north

        let route = StubMKRoute(
            name: "Eastbound",
            coordinates: coords,
            distance: totalMiles * mile,
            expectedTravelTime: (totalMiles / 55) * 3_600,
            hasHighways: true
        )
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 100 * mile
        viewModel.waypoints = [
            Waypoint(name: "West", coordinate: coords[0]),
            Waypoint(name: "East", coordinate: coords[coords.count - 1]),
        ]
        viewModel.plannedCorridor = [coords]
        viewModel.legs = [route]
        viewModel.gasStations = stations
        viewModel.selectedCategory = .gas
        return (viewModel, near, far)
    }

    func testShortLineFiltersThePoolOnTheCaller() {
        let (viewModel, _, far) = makeViewModel(points: 1_000)
        viewModel.applyFuelCandidatePool()
        XCTAssertFalse(viewModel.travelSideGasStations.contains { $0.id == far.id })
    }

    func testLongLineFallsBackThenDropsTheFarPumpWhenTheScanLands() async throws {
        let (viewModel, _, far) = makeViewModel(points: 20_000)
        viewModel.applyFuelCandidatePool()
        // The call returns before the scan finishes, with every station.
        XCTAssertTrue(viewModel.travelSideGasStations.contains { $0.id == far.id })

        let deadline = Date().addingTimeInterval(10)
        while viewModel.travelSideGasStations.contains(where: { $0.id == far.id }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(viewModel.travelSideGasStations.contains { $0.id == far.id })
    }

    func testLongLineResultIsDroppedWhenTheRouteChangesMidScan() async throws {
        let (viewModel, _, _) = makeViewModel(points: 20_000)
        viewModel.applyFuelCandidatePool()
        let replacement = Array(viewModel.gasStations.prefix(3))
        viewModel.gasStations = replacement
        viewModel.legs = []
        viewModel.applyFuelCandidatePool()
        try await Task.sleep(for: .milliseconds(1_500))
        // The stale scan must not rebuild the pool from the old stations.
        XCTAssertTrue(viewModel.travelSideGasStations.allSatisfy { stop in
            replacement.contains { $0.id == stop.id }
        })
    }
}
