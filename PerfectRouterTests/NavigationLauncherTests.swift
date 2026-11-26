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

    // MARK: - Google Maps

    func testGoogleMapsURLKeepsMiddleStopsInOrder() {
        let waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Pump", lat: 33.5, lon: -81.5),
            waypoint("Café", lat: 33.8, lon: -81.2),
            waypoint("End", lat: 34.0, lon: -81.0),
        ]
        guard let url = NavigationLauncher.googleMapsURL(waypoints) else {
            return XCTFail("should build a Google Maps URL")
        }
        XCTAssertEqual(url.host, "www.google.com")
        XCTAssertEqual(url.path, "/maps/dir")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first(where: { $0.name == "api" })?.value, "1")
        XCTAssertEqual(items.first(where: { $0.name == "origin" })?.value, "33.0,-82.0")
        XCTAssertEqual(items.first(where: { $0.name == "destination" })?.value, "34.0,-81.0")
        XCTAssertEqual(items.first(where: { $0.name == "waypoints" })?.value, "33.5,-81.5|33.8,-81.2")
        XCTAssertEqual(items.first(where: { $0.name == "travelmode" })?.value, "driving")
    }

    func testGoogleMapsURLKeepsTheFirstNineMiddleStops() {
        var waypoints = [waypoint("Start", lat: 33.0, lon: -82.0)]
        for index in 1...11 {
            waypoints.append(waypoint("Stop \(index)", lat: 33.0 + Double(index) * 0.01, lon: -82.0))
        }
        waypoints.append(waypoint("End", lat: 34.0, lon: -81.0))
        let url = NavigationLauncher.googleMapsURL(waypoints)!
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let middle = items.first(where: { $0.name == "waypoints" })?.value?.split(separator: "|") ?? []
        XCTAssertEqual(middle.count, 9)
        XCTAssertTrue(NavigationLauncher.googleMapsDropsStops(waypoints))
        XCTAssertEqual(items.first(where: { $0.name == "destination" })?.value, "34.0,-81.0")
    }

    // MARK: - Keeping the planned line

    /// An L-shaped line from (0,0) north to (0.5,0) then east to (0.5,0.5):
    /// about 111 km. Fastest would cut the corner.
    private func elbow() -> [CLLocationCoordinate2D] {
        let north = (0...50).map { CLLocationCoordinate2D(latitude: Double($0) * 0.01, longitude: 0) }
        let east = (1...50).map { CLLocationCoordinate2D(latitude: 0.5, longitude: Double($0) * 0.01) }
        return north + east
    }

    func testFastestHandsOffOnlyTheRiderStops() {
        let stops = [waypoint("A", lat: 0, lon: 0), waypoint("B", lat: 0.5, lon: 0.5)]
        let handed = NavigationLauncher.handoffWaypoints(stops, line: elbow(), style: .fastest, maxTotal: 14)
        XCTAssertEqual(handed.map(\.name), ["A", "B"])
    }

    func testTwistyAddsShapingPointsOnThePlannedLine() {
        let stops = [waypoint("A", lat: 0, lon: 0), waypoint("B", lat: 0.5, lon: 0.5)]
        let line = elbow()
        let handed = NavigationLauncher.handoffWaypoints(stops, line: line, style: .twisty, maxTotal: 14)
        XCTAssertEqual(handed.first?.name, "A")
        XCTAssertEqual(handed.last?.name, "B")
        XCTAssertEqual(handed.count, 2 + NavigationLauncher.maxShapingPoints)
        for via in handed.dropFirst().dropLast() {
            XCTAssertTrue(line.contains { $0.latitude == via.coordinate.latitude && $0.longitude == via.coordinate.longitude },
                          "a shaping point must be a point of the planned line")
        }
    }

    func testRiderStopsAreKeptInOrderAndNeverDisplaced() {
        let stops = [
            waypoint("A", lat: 0, lon: 0),
            waypoint("Gas", lat: 0.5, lon: 0),
            waypoint("B", lat: 0.5, lon: 0.5),
        ]
        let handed = NavigationLauncher.handoffWaypoints(stops, line: elbow(), style: .twisty, maxTotal: 11)
        XCTAssertEqual(handed.filter { $0.name != "Via" }.map(\.name), ["A", "Gas", "B"])
        XCTAssertLessThanOrEqual(handed.count, 11)
        // Both legs are the same length, so they share the points evenly.
        let gasIndex = handed.firstIndex { $0.name == "Gas" }!
        XCTAssertEqual(gasIndex - 1, handed.count - 2 - gasIndex)
    }

    func testNoRoomLeavesTheStopsAlone() {
        let stops = (0..<11).map { waypoint("S\($0)", lat: Double($0) * 0.05, lon: 0) }
        let handed = NavigationLauncher.handoffWaypoints(stops, line: elbow(), style: .twisty, maxTotal: 11)
        XCTAssertEqual(handed.map(\.name), stops.map(\.name))
    }
}
