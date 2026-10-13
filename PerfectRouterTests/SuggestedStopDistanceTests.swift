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

        let mile = AppSettings.metersPerMile
        XCTAssertEqual(
            RouteGeometry.preferredDistanceAlongRoute(projected: 0, known: 80 * mile),
            80 * mile,
            accuracy: 1
        )
        XCTAssertEqual(
            RouteGeometry.preferredDistanceAlongRoute(projected: 18, known: 40 * mile),
            40 * mile,
            accuracy: 1,
            "about 60 ft must not replace the mile mark"
        )
        XCTAssertEqual(
            RouteGeometry.preferredDistanceAlongRoute(projected: 122, known: 150 * mile),
            150 * mile,
            accuracy: 1,
            "about 400 ft must not replace the mile mark"
        )
        XCTAssertEqual(
            RouteGeometry.preferredDistanceAlongRoute(projected: 80.4 * mile, known: 80 * mile),
            80.4 * mile,
            accuracy: 1
        )
        let caption = milesFromStartCaption(80 * mile)
        XCTAssertTrue(caption.hasPrefix("~"))
        XCTAssertTrue(caption.hasSuffix(" from start"))
        XCTAssertFalse(caption.contains("ft"))
        XCTAssertFalse(milesFromStartCaption(18).contains("ft"))
        XCTAssertFalse(milesFromStartCaption(122).contains("ft"))

        let viewModel = RoutePlannerViewModel()
        viewModel.plannedCorridor = [line]
        for stop in projected {
            let shown = viewModel.distanceFromStart(of: stop) / AppSettings.metersPerMile
            XCTAssertEqual(shown, stop.distanceAlongRoute / AppSettings.metersPerMile, accuracy: 0.05)
            XCTAssertGreaterThan(shown, 1)
        }
    }

    /// The Suggested Gas list used to keep the first handful of stations and
    /// label them "~0 mi from start". It now shows the fuel-corridor pool,
    /// including a station at the far end of the ride, with real mile marks.
    func testSuggestedGasListShowsCorridorStationsWithMileMarks() {
        let line = northboundPolyline(stepMiles: 10, steps: 200)
        let indexes = Array(1...16) + [200]
        let stops = indexes.map { index in
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
        XCTAssertGreaterThan(stops.count, 15)

        let viewModel = RoutePlannerViewModel()
        viewModel.selectedCategory = .gas
        viewModel.plannedCorridor = [line]
        viewModel.gasStations = stops
        viewModel.showFuelCorridorInSuggestedGasList()

        let listed = viewModel.suggestionListStops
        XCTAssertEqual(listed.count, stops.count)
        let miles = listed.map { viewModel.distanceFromStart(of: $0) / AppSettings.metersPerMile }
        XCTAssertGreaterThan(miles[0], 5)
        XCTAssertLessThan(miles[0], 20)
        XCTAssertGreaterThan(miles.last ?? 0, 1_900)
        for pair in zip(miles, miles.dropFirst()) {
            XCTAssertGreaterThan(pair.1, pair.0)
        }
        let farCaption = milesFromStartCaption(viewModel.distanceFromStart(of: listed[listed.count - 1]))
        XCTAssertTrue(farCaption.hasPrefix("~"))
        XCTAssertTrue(farCaption.hasSuffix(" from start"))
        XCTAssertFalse(farCaption.hasPrefix("~0"))
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
