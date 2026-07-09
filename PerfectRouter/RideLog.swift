import Foundation

/// A record of a ride the rider sent to navigation, kept for history and stats.
struct RideLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var date: Date
    var distanceMeters: Double
    var durationSeconds: Double
    var stopCount: Int
    /// Filename of an offline route snapshot in the snapshots directory.
    var snapshotFilename: String?

    init(id: UUID = UUID(),
         name: String,
         date: Date,
         distanceMeters: Double,
         durationSeconds: Double,
         stopCount: Int,
         snapshotFilename: String? = nil) {
        self.id = id
        self.name = name
        self.date = date
        self.distanceMeters = distanceMeters
        self.durationSeconds = durationSeconds
        self.stopCount = stopCount
        self.snapshotFilename = snapshotFilename
    }
}

/// Persists the ride history to a JSON file in the app's Documents directory,
/// mirroring the lightweight approach used by `SavedRouteStore`.
struct RideLogStore {
    private let store: JSONFileStore<RideLogEntry>

    init(filename: String = "ride_log.json") {
        store = JSONFileStore(filename: filename)
    }

    /// All logged rides, most recent first.
    func load() -> [RideLogEntry] {
        store.load().sorted { $0.date > $1.date }
    }

    /// Appends a ride to the log.
    func append(_ entry: RideLogEntry) {
        var all = load()
        all.insert(entry, at: 0)
        store.save(all)
    }

    /// Removes a ride from the log (its snapshot file is cleaned up by the caller).
    func delete(_ entry: RideLogEntry) {
        var all = load()
        all.removeAll { $0.id == entry.id }
        store.save(all)
    }

    /// Attaches a snapshot filename to a previously logged ride.
    func updateSnapshot(id: UUID, filename: String) {
        var all = load()
        guard let index = all.firstIndex(where: { $0.id == id }) else {
            // The ride was deleted while its snapshot was still rendering —
            // remove the freshly written file so it isn't orphaned on disk.
            RouteSnapshotter.deleteSnapshot(named: filename)
            return
        }
        all[index].snapshotFilename = filename
        store.save(all)
    }
}
