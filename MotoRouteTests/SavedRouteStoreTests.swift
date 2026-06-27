import XCTest
import CoreLocation
@testable import MotoRoute

/// Unit tests for `SavedRouteStore`, the JSON-file persistence for saved rides.
/// Each test uses a unique on-disk filename so runs don't clobber each other or
/// the rider's real data, and cleans the file up afterwards.
final class SavedRouteStoreTests: XCTestCase {

    private var filename = ""
    private var store = SavedRouteStore()

    override func setUp() {
        super.setUp()
        // A fresh, unique store file per test (UUID avoids cross-test bleed).
        filename = "test_saved_routes_\(UUID().uuidString).json"
        store = SavedRouteStore(filename: filename)
    }

    override func tearDown() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: documents.appendingPathComponent(filename))
        super.tearDown()
    }

    /// Builds a saved route with a single start→end pair.
    private func route(named name: String, savedAt: Date = Date()) -> SavedRoute {
        let waypoints = [
            Waypoint(name: "Start", coordinate: CLLocationCoordinate2D(latitude: 33.0, longitude: -82.0)),
            Waypoint(name: "End", coordinate: CLLocationCoordinate2D(latitude: 34.0, longitude: -81.0)),
        ]
        return SavedRoute(name: name, savedAt: savedAt, route: SharedRoute(waypoints: waypoints))
    }

    func testLoadReturnsEmptyWhenNothingSaved() {
        XCTAssertTrue(store.load().isEmpty)
    }

    func testSaveLoadRoundTripPreservesOrderAndContent() {
        let routes = [route(named: "First"), route(named: "Second"), route(named: "Third")]
        store.save(routes)

        let loaded = store.load()
        XCTAssertEqual(loaded, routes)
        // Order is preserved exactly as written (the view model keeps most-recent first).
        XCTAssertEqual(loaded.map(\.name), ["First", "Second", "Third"])
    }

    func testSaveOverwritesPreviousContents() {
        store.save([route(named: "Old A"), route(named: "Old B")])
        store.save([route(named: "New")])

        let loaded = store.load()
        XCTAssertEqual(loaded.map(\.name), ["New"])
    }

    func testRoundTripPreservesWaypointCoordinates() {
        let original = route(named: "Coast Run")
        store.save([original])

        let loaded = store.load().first
        let waypoints = loaded?.route.waypoints ?? []
        XCTAssertEqual(waypoints.count, 2)
        XCTAssertEqual(waypoints.first?.coordinate.latitude ?? 0, 33.0, accuracy: 0.0001)
        XCTAssertEqual(waypoints.last?.coordinate.longitude ?? 0, -81.0, accuracy: 0.0001)
    }

    func testSavingEmptyListClearsStore() {
        store.save([route(named: "Temp")])
        store.save([])
        XCTAssertTrue(store.load().isEmpty)
    }
}
