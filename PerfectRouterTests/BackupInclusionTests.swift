import XCTest
@testable import PerfectRouter

/// Saved rides, ride history, its route images, and rider groups go into
/// the phone's backup, so a new phone keeps them (audit item 7). Files from
/// builds 1–15 were excluded; the flag is cleared on them.
final class BackupInclusionTests: XCTestCase {

    private var filename = ""
    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    private var fileURL: URL { documents.appendingPathComponent(filename) }
    private var extraFiles: [URL] = []

    override func setUp() {
        super.setUp()
        filename = "test_backup_\(UUID().uuidString).json"
    }

    override func tearDown() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: documents.path)) ?? []
        for name in names where name.hasPrefix(filename) {
            try? FileManager.default.removeItem(at: documents.appendingPathComponent(name))
        }
        extraFiles.forEach { try? FileManager.default.removeItem(at: $0) }
        super.tearDown()
    }

    private func entry() -> RideLogEntry {
        RideLogEntry(id: UUID(), name: "Coast Run", date: Date(), distanceMeters: 1_000, durationSeconds: 60, stopCount: 0)
    }

    func testSavedFileIsIncludedInBackup() {
        let store = JSONFileStore<RideLogEntry>(filename: filename)
        store.save([entry()])
        XCTAssertEqual(isIncludedInBackup(fileURL), true)
    }

    /// A file an earlier build wrote with the exclude flag is included as
    /// soon as its store is opened, before any save.
    func testExcludedFileFromAnEarlierBuildIsIncludedWhenOpened() throws {
        try Data("[]".utf8).write(to: fileURL)
        setIncludedInBackup(fileURL, false)
        XCTAssertEqual(isIncludedInBackup(fileURL), false)

        _ = JSONFileStore<RideLogEntry>(filename: filename)
        XCTAssertEqual(isIncludedInBackup(fileURL), true)
    }

    /// The `.unreadable-*` copies are diagnostics, not ride data.
    func testUnreadableCopyStaysOutOfBackup() throws {
        try Data("not json".utf8).write(to: fileURL)
        let store = JSONFileStore<RideLogEntry>(filename: filename)
        XCTAssertTrue(store.load().isEmpty)
        let copy = try XCTUnwrap(store.unreadableBackups().last)
        XCTAssertEqual(isIncludedInBackup(copy), false)
    }

    func testEarlierSnapshotsAreIncluded() throws {
        let url = RouteSnapshotter.snapshotsDirectory().appendingPathComponent("test-\(UUID().uuidString).png")
        extraFiles.append(url)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        setIncludedInBackup(url, false)

        RouteSnapshotter.includeAllSnapshotsInBackup()
        XCTAssertEqual(isIncludedInBackup(url), true)
    }
}
