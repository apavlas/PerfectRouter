import XCTest
@testable import PerfectRouter

/// A file the app can't fully read must never be wiped by the next save.
/// Saved rides, ride history, and rider groups all go through this store.
final class JSONFileStoreSafetyTests: XCTestCase {

    private var filename = ""
    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var fileURL: URL { documents.appendingPathComponent(filename) }

    override func setUp() {
        super.setUp()
        filename = "test_store_safety_\(UUID().uuidString).json"
    }

    override func tearDown() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        for name in names where name.hasPrefix(filename) {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
        }
        super.tearDown()
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: fileURL)
    }

    /// Saved rides as builds 1–15 write them: default `JSONEncoder` dates
    /// (seconds since 2001) and a stop from before `isGasFill`/`isOvernight`.
    private let versionOneSavedRides = """
    [{"id":"6F1C2B8E-1D2A-4B53-9C7E-2A1F0E3D4C5B","name":"Coast Run","savedAt":785000000,
      "route":{"stops":[
        {"name":"Start","latitude":33.0,"longitude":-82.0},
        {"name":"Pump","latitude":33.5,"longitude":-81.5,"isGasFill":true,"isOvernight":false},
        {"name":"End","latitude":34.0,"longitude":-81.0,"isGasFill":false,"isOvernight":true}],
       "suggestions":[{"name":"Joe's Diner","latitude":33.4,"longitude":-81.6,"category":"Food","distanceAlongRoute":52000}]}}]
    """

    func testVersionOneSavedRidesStillDecode() throws {
        try write(versionOneSavedRides)
        let loaded = JSONFileStore<SavedRoute>(filename: filename).load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.name, "Coast Run")
        XCTAssertEqual(loaded.first?.route.stops.map(\.isGasFill), [false, true, false])
        XCTAssertEqual(loaded.first?.route.stops.map(\.isOvernight), [false, false, true])
        XCTAssertEqual(loaded.first?.route.suggestions.first?.category, "Food")
        XCTAssertTrue(JSONFileStore<SavedRoute>(filename: filename).unreadableBackups().isEmpty)
    }

    func testMissingFileLoadsEmptyWithoutBackup() {
        let store = JSONFileStore<SavedRoute>(filename: filename)
        XCTAssertTrue(store.load().isEmpty)
        XCTAssertTrue(store.unreadableBackups().isEmpty)
    }

    /// The bug this guards: corrupt file -> load returns [] -> next save
    /// overwrote the rider's only copy.
    func testCorruptFileIsKeptBeforeNextSaveOverwritesIt() throws {
        let corrupt = "this is not json"
        try write(corrupt)
        let store = JSONFileStore<SavedRoute>(filename: filename)

        XCTAssertTrue(store.load().isEmpty)
        store.save([SavedRoute(name: "New", savedAt: Date(), route: SharedRoute(waypoints: []))])

        let backups = store.unreadableBackups()
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try String(contentsOf: backups[0], encoding: .utf8), corrupt)
        XCTAssertEqual(store.load().map(\.name), ["New"])
    }

    /// One element a future model can't read drops only that element.
    func testOneUnreadableElementKeepsTheRest() throws {
        let mixed = "[" + versionOneSavedRides.dropFirst().dropLast() + ",{\"unexpected\":true}]"
        try write(String(mixed))
        let store = JSONFileStore<SavedRoute>(filename: filename)

        XCTAssertEqual(store.load().map(\.name), ["Coast Run"])
        XCTAssertEqual(store.unreadableBackups().count, 1)
    }

    func testRepeatedLoadsOfSameBadFileKeepOneBackup() throws {
        try write("{ broken")
        let store = JSONFileStore<SavedRoute>(filename: filename)
        _ = store.load()
        _ = store.load()
        _ = store.load()
        XCTAssertEqual(store.unreadableBackups().count, 1)
    }
}
