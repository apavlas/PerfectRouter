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
/// The payload is small (a list of coordinates), so reads and writes are done
/// synchronously.
struct SavedRouteStore {
    private let fileURL: URL

    init(filename: String = "saved_routes.json") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent(filename)
    }

    /// Loads the saved rides, or an empty list if none are stored yet.
    func load() -> [SavedRoute] {
        guard let data = try? Data(contentsOf: fileURL),
              let routes = try? JSONDecoder().decode([SavedRoute].self, from: data) else {
            return []
        }
        return routes
    }

    /// Overwrites the stored rides with `routes`.
    func save(_ routes: [SavedRoute]) {
        guard let data = try? JSONEncoder().encode(routes) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
