import Foundation

/// Loads and saves a small `Codable` array as a JSON file in the app's
/// Documents directory. Shared by all the local stores (saved rides, ride
/// history, rider groups).
///
/// Every store holds personal data — location history or contacts' phone
/// numbers — so files are written with complete file protection and excluded
/// from unencrypted backups. Payloads are small, so reads and writes are done
/// synchronously.
struct JSONFileStore<Element: Codable> {
    private let fileURL: URL

    init(filename: String) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent(filename)
    }

    /// Loads the stored elements, or an empty list if none are stored yet
    /// (or the file is unreadable/corrupt).
    func load() -> [Element] {
        guard let data = try? Data(contentsOf: fileURL),
              let items = try? JSONDecoder().decode([Element].self, from: data) else {
            return []
        }
        return items
    }

    /// Overwrites the stored elements with `items`.
    func save(_ items: [Element]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        excludeFromBackup(fileURL)
    }
}

/// Marks a file so it is omitted from iCloud / iTunes backups. Used by the
/// local stores to keep personal data (location history, contacts' phone
/// numbers) from leaving the device in a backup.
func excludeFromBackup(_ url: URL) {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? url.setResourceValues(values)
}
