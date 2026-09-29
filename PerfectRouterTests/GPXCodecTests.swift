import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for GPX encode/decode: waypoints, optional track, filename, and
/// XML escaping. Import maps `<wpt>` into plan waypoints.
@MainActor
final class GPXCodecTests: XCTestCase {

    private func waypoint(_ name: String, lat: Double, lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    func testSuggestedFilenameFormat() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = cal.date(from: DateComponents(
            timeZone: TimeZone(secondsFromGMT: 0),
            year: 2026, month: 9, day: 29, hour: 16, minute: 5
        ))!
        let name = GPXCodec.suggestedFilename(
            date: date,
            calendar: cal,
            timeZone: TimeZone(secondsFromGMT: 0)!
        )
        XCTAssertEqual(name, "PerfectRouter-20260929-1605.gpx")
    }

    func testEncodeDecodeRoundTripWaypointsOnly() throws {
        let waypoints = [
            waypoint("Home", lat: 33.4735, lon: -82.0105),
            waypoint("Blue Ridge Café", lat: 34.87, lon: -83.4),
            waypoint("Overlook", lat: 35.05, lon: -83.19),
        ]
        let data = GPXCodec.encode(
            waypoints: waypoints,
            trackCoordinates: [],
            name: "Home → Overlook",
            date: Date(timeIntervalSince1970: 1_000_000)
        )
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<gpx "))
        XCTAssertTrue(xml.contains("<wpt lat=\"33.4735\" lon=\"-82.0105\">"))
        XCTAssertTrue(xml.contains("<name>Blue Ridge Café</name>") || xml.contains("Blue Ridge"))
        XCTAssertFalse(xml.contains("<trk>"), "waypoints-only export must omit track")

        let decoded = try GPXCodec.decode(data)
        XCTAssertEqual(decoded.waypoints.count, 3)
        XCTAssertEqual(decoded.waypoints[0].name, "Home")
        XCTAssertEqual(decoded.waypoints[0].coordinate.latitude, 33.4735, accuracy: 0.0001)
        XCTAssertEqual(decoded.waypoints[0].coordinate.longitude, -82.0105, accuracy: 0.0001)
        XCTAssertEqual(decoded.waypoints[1].name, "Blue Ridge Café")
        XCTAssertEqual(decoded.waypoints[2].name, "Overlook")
        XCTAssertTrue(decoded.trackCoordinates.isEmpty)
        XCTAssertEqual(decoded.name, "Home → Overlook")
    }

    func testEncodeIncludesTrackWhenProvided() throws {
        let waypoints = [
            waypoint("A", lat: 33.0, lon: -82.0),
            waypoint("B", lat: 34.0, lon: -81.0),
        ]
        let track = [
            CLLocationCoordinate2D(latitude: 33.0, longitude: -82.0),
            CLLocationCoordinate2D(latitude: 33.5, longitude: -81.5),
            CLLocationCoordinate2D(latitude: 34.0, longitude: -81.0),
        ]
        let data = GPXCodec.encode(waypoints: waypoints, trackCoordinates: track, name: "Ride")
        let xml = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(xml.contains("<trk>"))
        XCTAssertTrue(xml.contains("<trkpt lat=\"33.5\" lon=\"-81.5\">"))

        let decoded = try GPXCodec.decode(data)
        XCTAssertEqual(decoded.waypoints.count, 2)
        XCTAssertEqual(decoded.trackCoordinates.count, 3)
        XCTAssertEqual(decoded.trackCoordinates[1].latitude, 33.5, accuracy: 0.0001)
    }

    func testEncodeEscapesXMLSpecialCharacters() {
        let waypoints = [
            waypoint("A & B <top>", lat: 33, lon: -82),
            waypoint("End", lat: 34, lon: -81),
        ]
        let xml = String(decoding: GPXCodec.encode(waypoints: waypoints), as: UTF8.self)
        XCTAssertTrue(xml.contains("A &amp; B &lt;top&gt;"))
        XCTAssertFalse(xml.contains("A & B <top>"))
    }

    func testDecodeTrackOnlyUsesStartAndEnd() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Other" xmlns="http://www.topografix.com/GPX/1/1">
          <trk>
            <trkseg>
              <trkpt lat="40.0" lon="-74.0"></trkpt>
              <trkpt lat="40.5" lon="-73.5"></trkpt>
              <trkpt lat="41.0" lon="-73.0"></trkpt>
            </trkseg>
          </trk>
        </gpx>
        """
        let decoded = try GPXCodec.decode(Data(xml.utf8))
        XCTAssertEqual(decoded.waypoints.count, 2)
        XCTAssertEqual(decoded.waypoints[0].name, "Start")
        XCTAssertEqual(decoded.waypoints[0].coordinate.latitude, 40.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.waypoints[1].name, "End")
        XCTAssertEqual(decoded.waypoints[1].coordinate.latitude, 41.0, accuracy: 0.0001)
        XCTAssertEqual(decoded.trackCoordinates.count, 3)
    }

    func testDecodeRejectsEmptyAndNonGPX() {
        XCTAssertThrowsError(try GPXCodec.decode(Data())) { error in
            XCTAssertEqual(error as? GPXCodec.DecodeError, .empty)
        }
        XCTAssertThrowsError(try GPXCodec.decode(Data("<html></html>".utf8))) { error in
            XCTAssertEqual(error as? GPXCodec.DecodeError, .notGPX)
        }
        let bare = Data("<gpx version=\"1.1\"></gpx>".utf8)
        XCTAssertThrowsError(try GPXCodec.decode(bare)) { error in
            XCTAssertEqual(error as? GPXCodec.DecodeError, .noCoordinates)
        }
    }

    func testViewModelImportGPXReplacesWaypoints() {
        let viewModel = RoutePlannerViewModel()
        viewModel.addWaypoint(waypoint("Old", lat: 10, lon: 10))
        let data = GPXCodec.encode(waypoints: [
            waypoint("Start", lat: 33.4735, lon: -82.0105),
            waypoint("End", lat: 34.87, lon: -83.4),
        ])
        XCTAssertTrue(viewModel.importGPX(data: data))
        XCTAssertEqual(viewModel.waypoints.count, 2)
        XCTAssertEqual(viewModel.waypoints[0].name, "Start")
        XCTAssertEqual(viewModel.waypoints[1].name, "End")
    }
}
