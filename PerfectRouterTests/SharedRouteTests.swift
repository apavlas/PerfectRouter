import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for `SharedRoute`'s deep-link encoding: the URL round-trip
/// (including base64url padding edge cases) and the import hardening caps
/// that keep a crafted `perfectrouter://` link from carrying a huge payload.
final class SharedRouteTests: XCTestCase {

    private func waypoint(_ name: String, lat: Double, lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    func testURLRoundTripPreservesRoute() {
        let route = SharedRoute(waypoints: [
            waypoint("Home", lat: 33.4735, lon: -82.0105),
            waypoint("Blue Ridge Café", lat: 34.87, lon: -83.4),
            waypoint("Overlook", lat: 35.05, lon: -83.19),
        ])

        guard let url = route.shareURL else {
            return XCTFail("shareURL should encode a valid route")
        }
        XCTAssertEqual(url.scheme, SharedRoute.scheme)
        XCTAssertEqual(SharedRoute(url: url), route)
    }

    func testURLRoundTripPreservesSuggestions() {
        let suggestion = SuggestedStop(
            name: "Gas-N-Go",
            coordinate: CLLocationCoordinate2D(latitude: 34.0, longitude: -82.5),
            category: .gas,
            distanceAlongRoute: 42_000
        )
        let route = SharedRoute(
            waypoints: [waypoint("A", lat: 33, lon: -82), waypoint("B", lat: 35, lon: -83)],
            suggestedStops: [suggestion]
        )

        guard let url = route.shareURL, let decoded = SharedRoute(url: url) else {
            return XCTFail("route with suggestions should round-trip")
        }
        XCTAssertEqual(decoded.suggestions.count, 1)
        XCTAssertEqual(decoded.suggestionCategory, .gas)
        XCTAssertEqual(decoded.suggestions.first?.distanceAlongRoute ?? 0, 42_000, accuracy: 0.001)
    }

    /// Names of different lengths shift the JSON payload size, exercising all
    /// base64 padding remainders (0, 2, and 3) that the URL form strips.
    func testRoundTripSurvivesAllBase64PaddingLengths() {
        for padding in 0...3 {
            let name = String(repeating: "x", count: 5 + padding)
            let route = SharedRoute(waypoints: [
                waypoint(name, lat: 33, lon: -82),
                waypoint("End", lat: 34, lon: -81),
            ])
            guard let url = route.shareURL else {
                return XCTFail("shareURL should encode (name length \(name.count))")
            }
            XCTAssertEqual(SharedRoute(url: url), route, "round-trip failed for name length \(name.count)")
        }
    }

    func testRoundTripSurvivesNonASCIINames() {
        let route = SharedRoute(waypoints: [
            waypoint("Škofja Loka ⛰️", lat: 46.17, lon: 14.3),
            waypoint("Vršič — top", lat: 46.43, lon: 13.74),
        ])
        guard let url = route.shareURL else {
            return XCTFail("shareURL should encode non-ASCII names")
        }
        XCTAssertEqual(SharedRoute(url: url), route)
    }

    func testRejectsWrongSchemeOrHost() {
        let route = SharedRoute(waypoints: [
            waypoint("A", lat: 33, lon: -82), waypoint("B", lat: 34, lon: -81),
        ])
        guard let url = route.shareURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return XCTFail("shareURL should encode")
        }
        components.scheme = "https"
        XCTAssertNil(components.url.flatMap(SharedRoute.init(url:)))

        components.scheme = SharedRoute.scheme
        components.host = "not-a-route"
        XCTAssertNil(components.url.flatMap(SharedRoute.init(url:)))
    }

    func testRejectsGarbagePayload() {
        var components = URLComponents()
        components.scheme = SharedRoute.scheme
        components.host = SharedRoute.host
        components.queryItems = [URLQueryItem(name: "data", value: "not-valid-base64-json!!!")]
        XCTAssertNil(components.url.flatMap(SharedRoute.init(url:)))
    }

    func testRejectsTooManyStops() {
        let tooMany = (0...SharedRoute.maxElementCount).map {
            waypoint("Stop \($0)", lat: 33, lon: -82)
        }
        let route = SharedRoute(waypoints: tooMany)
        guard let url = route.shareURL else {
            return XCTFail("shareURL should still encode (the cap is enforced on import)")
        }
        XCTAssertNil(SharedRoute(url: url), "import should reject a link with more than \(SharedRoute.maxElementCount) stops")
    }
}
