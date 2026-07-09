import Foundation

/// A ride the rider has saved on this device, so it can be reloaded later.
/// Wraps the same `SharedRoute` snapshot used for link sharing, plus a name
/// and the date it was saved.
struct SavedRoute: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var savedAt: Date
    var route: SharedRoute

    init(id: UUID = UUID(), name: String, savedAt: Date, route: SharedRoute) {
        self.id = id
        self.name = name
        self.savedAt = savedAt
        self.route = route
    }
}

/// Persists saved rides to a JSON file in the app's Documents directory.
struct SavedRouteStore {
    private let store: JSONFileStore<SavedRoute>

    init(filename: String = "saved_routes.json") {
        store = JSONFileStore(filename: filename)
    }

    /// Loads the saved rides, or an empty list if none are stored yet.
    func load() -> [SavedRoute] {
        store.load()
    }

    /// Overwrites the stored rides with `routes`.
    func save(_ routes: [SavedRoute]) {
        store.save(routes)
    }
}
