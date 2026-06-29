import XCTest
import CoreLocation
import MapKit
@testable import PerfectRouter

/// Unit tests for the pure food-ranking logic that pairs food to fuel stops.
/// These exercise the radius filter, de-duplication, nearest-first sort, and
/// result cap without any networking.
final class FuelFoodPairingTests: XCTestCase {

    /// Origin used as the "fuel stop" all food is measured against.
    private let origin = CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0)

    /// Builds a food stop offset from the origin by a north/south latitude delta.
    /// ~111 km per degree of latitude, so small deltas map to known distances.
    private func food(_ name: String, latitudeOffset: CLLocationDegrees) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: origin.latitude + latitudeOffset,
                                               longitude: origin.longitude),
            category: .food,
            distanceAlongRoute: 0
        )
    }

    func testKeepsOnlyFoodWithinRadius() {
        // ~0.009° ≈ 1 km (in), ~0.027° ≈ 3 km (out of a 1.5 km radius).
        let near = food("Near", latitudeOffset: 0.009)
        let far = food("Far", latitudeOffset: 0.027)

        let ranked = StopSuggestionService.rankFood(
            [near, far], near: origin, radiusMeters: 1_500, maxResults: 3
        )

        XCTAssertEqual(ranked.map(\.name), ["Near"])
    }

    func testSortsNearestFirst() {
        let mid = food("Mid", latitudeOffset: 0.006)
        let close = food("Close", latitudeOffset: 0.002)
        let edge = food("Edge", latitudeOffset: 0.010)

        let ranked = StopSuggestionService.rankFood(
            [mid, close, edge], near: origin, radiusMeters: 1_500, maxResults: 3
        )

        XCTAssertEqual(ranked.map(\.name), ["Close", "Mid", "Edge"])
    }

    func testCapsAtMaxResults() {
        let stops = (1...5).map { food("Food \($0)", latitudeOffset: Double($0) * 0.001) }

        let ranked = StopSuggestionService.rankFood(
            stops, near: origin, radiusMeters: 1_500, maxResults: 2
        )

        XCTAssertEqual(ranked.count, 2)
        XCTAssertEqual(ranked.map(\.name), ["Food 1", "Food 2"])
    }

    func testDeduplicatesByNameAndCoordinate() {
        let a = food("Diner", latitudeOffset: 0.003)
        let duplicate = food("Diner", latitudeOffset: 0.003)

        let ranked = StopSuggestionService.rankFood(
            [a, duplicate], near: origin, radiusMeters: 1_500, maxResults: 3
        )

        XCTAssertEqual(ranked.count, 1)
    }

    func testEmptyCandidatesYieldsNoFood() {
        let ranked = StopSuggestionService.rankFood(
            [], near: origin, radiusMeters: 1_500, maxResults: 3
        )

        XCTAssertTrue(ranked.isEmpty)
    }
}
