import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for Maps handoff URLs. These check the query string only —
/// they do not open Maps.
final class NavigationLauncherTests: XCTestCase {

    private func waypoint(_ name: String, lat: Double, lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    func testAppleMapsMultiStopURLUsesOfficialWaypointParameters() {
        let waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Pump", lat: 33.5, lon: -81.5),
            waypoint("Café", lat: 33.8, lon: -81.2),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        guard let url = NavigationLauncher.appleMapsMultiStopURL(waypoints) else {
            return XCTFail("should build a multi-stop Apple Maps URL")
        }

        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "maps.apple.com")
        XCTAssertEqual(url.path, "/directions")

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "source" })?.value, "33.0,-82.0")
        XCTAssertEqual(items.first(where: { $0.name == "destination" })?.value, "34.0,-81.0")
        XCTAssertEqual(items.filter { $0.name == "waypoint" }.compactMap(\.value), ["33.5,-81.5", "33.8,-81.2"])
        XCTAssertEqual(items.first(where: { $0.name == "mode" })?.value, "driving")

        let absolute = url.absoluteString
        XCTAssertFalse(absolute.contains("+to:"), "must not use the unofficial +to: chain")
        XCTAssertFalse(absolute.contains("%2Bto"), "must not percent-encode a leftover +to: separator")
        XCTAssertTrue(absolute.contains("waypoint=33.5,-81.5"))
        XCTAssertTrue(absolute.contains("waypoint=33.8,-81.2"))
    }

    func testAppleMapsURLOmitsWaypointWhenOnlyOriginAndDestination() {
        let waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]

        guard let url = NavigationLauncher.appleMapsMultiStopURL(waypoints) else {
            return XCTFail("two-stop rides should still encode a directions URL")
        }

        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(items.contains(where: { $0.name == "waypoint" }))
        XCTAssertEqual(items.first(where: { $0.name == "source" })?.value, "33.0,-82.0")
        XCTAssertEqual(items.first(where: { $0.name == "destination" })?.value, "34.0,-81.0")
    }

    func testAppleMapsURLRequiresTwoWaypoints() {
        XCTAssertNil(NavigationLauncher.appleMapsMultiStopURL([]))
        XCTAssertNil(NavigationLauncher.appleMapsMultiStopURL([
            waypoint("Only", lat: 33.0, lon: -82.0),
        ]))
    }
}
