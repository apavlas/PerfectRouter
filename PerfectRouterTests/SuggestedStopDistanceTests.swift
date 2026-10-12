import CoreLocation
import XCTest
@testable import PerfectRouter

/// Suggested gas rows used to label every stop "~0 ft from start" because
/// the stored distance was 0. The mile mark is the projection of the stop
/// onto the route polyline.
@MainActor
final class SuggestedStopDistanceTests: XCTestCase {

    func testSuggestedStopsShowDistinctIncreasingMilesFromStart() {
        let line = northboundPolyline(stepMiles: 10, steps: 16)
        // Vertices at about 40, 80, and 150 miles. Stored distances are 0,
        // which is what the list was rendering as "~0 ft from start".
        let marks = [4, 8, 15]
        let stops = marks.reversed().map { index in
            let onRoute = line[index]
            return SuggestedStop(
                name: "Gas \(index)",
                coordinate: CLLocationCoordinate2D(
                    latitude: onRoute.latitude,
                    longitude: onRoute.longitude + 0.002
                ),
                category: .gas,
                distanceAlongRoute: 0
            )
        }
        XCTAssertTrue(stops.allSatisfy { $0.distanceAlongRoute == 0 })

        let projected = RoutePlannerViewModel.projectingDistancesFromStart(
            stops,
            alongPolylines: [line]
        )
        let miles = projected.map { $0.distanceAlongRoute / AppSettings.metersPerMile }

        XCTAssertEqual(miles.count, 3)
        XCTAssertGreaterThan(miles[0], 1)
        XCTAssertGreaterThan(miles[1], miles[0])
        XCTAssertGreaterThan(miles[2], miles[1])
        XCTAssertEqual(Set(projected.map(\.id)), Set(stops.map(\.id)))

        let expectedMiles = marks.map { index in
            RouteGeometry.length(of: Array(line.prefix(index + 1))) / AppSettings.metersPerMile
        }
        for (actual, expected) in zip(miles, expectedMiles) {
            XCTAssertEqual(actual, expected, accuracy: 1)
        }

        let viewModel = RoutePlannerViewModel()
        viewModel.plannedCorridor = [line]
        for stop in projected {
            let shown = viewModel.distanceFromStart(of: stop) / AppSettings.metersPerMile
            XCTAssertEqual(shown, stop.distanceAlongRoute / AppSettings.metersPerMile, accuracy: 0.05)
            XCTAssertGreaterThan(shown, 1)
        }
    }

    /// Northbound line. Vertices are about `stepMiles` apart; the test
    /// compares against the polyline's own length, not the approximation.
    private func northboundPolyline(stepMiles: Double, steps: Int) -> [CLLocationCoordinate2D] {
        let originLatitude = 36.0
        let originLongitude = -84.0
        let degrees = stepMiles * AppSettings.metersPerMile / 111_320
        return (0...steps).map { index in
            CLLocationCoordinate2D(
                latitude: originLatitude + Double(index) * degrees,
                longitude: originLongitude
            )
        }
    }
}
