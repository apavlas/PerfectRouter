import Foundation

/// A single rider you ride with: a display name plus the phone number used to
/// message them a shared route. Built from a contact the rider picks.
struct Rider: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var phoneNumber: String

    init(id: UUID = UUID(), name: String, phoneNumber: String) {
        self.id = id
        self.name = name
        self.phoneNumber = phoneNumber
    }
}

/// A named group of riders (e.g. "Sunday Crew") so a ride can be shared with a
/// whole group in one tap rather than re-picking people every time.
struct RiderGroup: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var riders: [Rider]
    var createdAt: Date

    init(id: UUID = UUID(), name: String, riders: [Rider] = [], createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.riders = riders
        self.createdAt = createdAt
    }

    /// The recipients used to pre-address a Messages composer.
    var phoneNumbers: [String] { riders.map(\.phoneNumber) }

    /// A short "Alice, Bob & 2 more" style summary for list rows.
    var memberSummary: String {
        switch riders.count {
        case 0:
            return "No riders yet"
        case 1:
            return riders[0].name
        case 2:
            return "\(riders[0].name) & \(riders[1].name)"
        default:
            return "\(riders[0].name), \(riders[1].name) & \(riders.count - 2) more"
        }
    }
}

/// Persists rider groups to a JSON file in the app's Documents directory.
/// The payload is small (names and phone numbers), so reads and writes are
/// done synchronously, mirroring `SavedRouteStore`.
struct RiderGroupStore {
    private let fileURL: URL

    init(filename: String = "rider_groups.json") {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent(filename)
    }

    /// Loads the saved rider groups, or an empty list if none are stored yet.
    func load() -> [RiderGroup] {
        guard let data = try? Data(contentsOf: fileURL),
              let groups = try? JSONDecoder().decode([RiderGroup].self, from: data) else {
            return []
        }
        return groups
    }

    /// Overwrites the stored rider groups with `groups`.
    func save(_ groups: [RiderGroup]) {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        // Groups hold contacts' phone numbers, so protect the file at rest and
        // keep it out of unencrypted device backups.
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        excludeFromBackup(fileURL)
    }
}
