import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for the pure ride-highlight selection: places of interest are
/// kept only when the detour is small, spread out along the ride, capped, and
/// returned in ride order — all without any networking.
final class RideHighlightsTests: XCTestCase {

    /// A 200 km ride, long enough that the end margins don't dominate.
    private let totalDistance: CLLocationDistance = 200_000

    private func sight(
        _ name: String,
        along: CLLocationDistance,
        detour: CLLocationDistance = 0
    ) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            category: .attraction,
            distanceAlongRoute: along,
            detourMeters: detour
        )
    }

    func testHighlightSamplesSpanACoastToCoastRide() {
        let mile = AppSettings.metersPerMile
        let total = 2_471 * mile
        let distances = RoutePlannerViewModel.highlightSearchDistances(totalDistance: total)
        XCTAssertLessThanOrEqual(distances.count, 12)
        XCTAssertGreaterThanOrEqual(distances.count, 8)
        XCTAssertLessThan(distances.first ?? total, total * 0.15)
        XCTAssertGreaterThan(distances.last ?? 0, total * 0.85)
        XCTAssertEqual(distances, distances.sorted())
    }

    func testNoCandidatesYieldsNoHighlights() {
        let picked = RoutePlannerViewModel.selectHighlights(from: [], totalDistance: totalDistance)
        XCTAssertTrue(picked.isEmpty)
    }

    func testDropsBigDetours() {
        let onRoute = sight("On Route", along: 100_000, detour: 500)
        let farOff = sight("Far Off", along: 60_000, detour: 10_000)

        let picked = RoutePlannerViewModel.selectHighlights(
            from: [onRoute, farOff], totalDistance: totalDistance
        )
        XCTAssertEqual(picked.map(\.name), ["On Route"])
    }

    func testDropsSightsAtStartAndEnd() {
        // Within 5 km of the origin or destination — the rider is already there.
        let atStart = sight("At Start", along: 2_000)
        let atEnd = sight("At End", along: totalDistance - 2_000)
        let midway = sight("Midway", along: 100_000)

        let picked = RoutePlannerViewModel.selectHighlights(
            from: [atStart, atEnd, midway], totalDistance: totalDistance
        )
        XCTAssertEqual(picked.map(\.name), ["Midway"])
    }

    func testCapsAtMaxCount() {
        // Six well-spread, on-route sights; only maxCount survive.
        let sights = (1...6).map { sight("S\($0)", along: Double($0) * 25_000) }
        let picked = RoutePlannerViewModel.selectHighlights(
            from: sights, totalDistance: totalDistance, maxCount: 3
        )
        XCTAssertEqual(picked.count, 3)
    }

    func testSpreadsPicksAlongTheRide() {
        // A cluster in one town plus one lone sight further on: the cluster
        // shouldn't crowd out the spread.
        let cluster = [
            sight("Cluster A", along: 50_000, detour: 100),
            sight("Cluster B", along: 52_000, detour: 200),
            sight("Cluster C", along: 54_000, detour: 300),
        ]
        let lone = sight("Lone", along: 150_000, detour: 2_000)

        let picked = RoutePlannerViewModel.selectHighlights(
            from: cluster + [lone], totalDistance: totalDistance
        )
        // One from the cluster (the smallest detour wins) plus the lone sight.
        XCTAssertEqual(picked.map(\.name), ["Cluster A", "Lone"])
    }

    func testPrefersSmallerDetourWhenTooCloseTogether() {
        let closeToRoute = sight("Close", along: 100_000, detour: 200)
        let furtherOff = sight("Further", along: 105_000, detour: 2_500)

        let picked = RoutePlannerViewModel.selectHighlights(
            from: [furtherOff, closeToRoute], totalDistance: totalDistance
        )
        XCTAssertEqual(picked.map(\.name), ["Close"])
    }

    func testReturnsPicksInRideOrder() {
        // Selection prefers small detours, but the result reads start→end.
        let late = sight("Late", along: 150_000, detour: 100)
        let early = sight("Early", along: 50_000, detour: 2_000)

        let picked = RoutePlannerViewModel.selectHighlights(
            from: [late, early], totalDistance: totalDistance
        )
        XCTAssertEqual(picked.map(\.name), ["Early", "Late"])
    }

    /// I-40 passes just north of Cadillac Ranch. The ranch is a highlight
    /// with its description already set. A Charlotte–Los Angeles chord
    /// misses it by tens of miles and does not invent the stop.
    func testCadillacRanchIsAHighlightBesideAmarillo() {
        let ranch = PlaceDescriptionReader.cadillacRanchCoordinate
        let interstate = [
            CLLocationCoordinate2D(latitude: 35.192, longitude: -101.70),
            CLLocationCoordinate2D(latitude: 35.192, longitude: -102.20),
        ]
        let total = RouteGeometry.length(of: interstate)
        let found = RoutePlannerViewModel.landmarkHighlights(
            alongPolylines: [interstate],
            totalDistance: total
        )
        XCTAssertEqual(found.map(\.name), ["Cadillac Ranch"])
        XCTAssertEqual(
            found.first?.placeDescription,
            "Ten vintage Cadillacs stand buried nose-down in a wheat field west of Amarillo."
        )
        XCTAssertFalse(found.first?.placeDescription?.localizedCaseInsensitiveContains("followers") ?? true)
        XCTAssertLessThanOrEqual(found.first?.detourMeters ?? 9_000, 8_000)

        let picked = RoutePlannerViewModel.selectHighlights(from: found, totalDistance: total)
        XCTAssertEqual(picked.map(\.name), ["Cadillac Ranch"])
        XCTAssertEqual(picked.first?.placeDescription, found.first?.placeDescription)

        let chord = [
            CLLocationCoordinate2D(latitude: 35.2271, longitude: -80.8431),
            CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
        ]
        let missed = RoutePlannerViewModel.landmarkHighlights(
            alongPolylines: [chord],
            totalDistance: RouteGeometry.length(of: chord)
        )
        XCTAssertTrue(missed.isEmpty)
    }

    func testZeroDistanceRouteYieldsNothing() {
        let picked = RoutePlannerViewModel.selectHighlights(
            from: [sight("Anything", along: 0)], totalDistance: 0
        )
        XCTAssertTrue(picked.isEmpty)
    }
}
