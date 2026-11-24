import Foundation
import os

/// Loads and saves a small `Codable` array as a JSON file in the app's
/// Documents directory. Shared by all the local stores (saved rides, ride
/// history, rider groups).
///
/// Every store holds personal data — location history or contacts' phone
/// numbers — so files are written with complete file protection. They are
/// included in the phone's iCloud or computer backup, so a rider who moves to
/// a new phone keeps their rides (audit item 7). Builds 1–15 excluded them;
/// opening a store clears that flag on the existing file. Payloads are small,
/// so reads and writes are done synchronously.
///
/// A file this build can't fully read is never overwritten. Before `load()`
/// returns anything less than the whole file, it copies the original bytes to
/// a timestamped `.unreadable-*` backup next to it. One element that no longer
/// decodes, for example after a model change, drops only that element. The
/// rest still load.
struct JSONFileStore<Element: Codable> {
    private let fileURL: URL
    private static var log: Logger { Logger(subsystem: "PerfectRouter", category: "JSONFileStore") }

    init(filename: String) {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = documents.appendingPathComponent(filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            setIncludedInBackup(fileURL, true)
        }
    }

    /// Loads the stored elements. Returns an empty list when nothing is
    /// stored yet. If the file is unreadable or some elements fail to decode,
    /// returns what could be read and keeps a backup of the original file.
    func load() -> [Element] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else {
            backUpUnreadableFile(reason: "read failed")
            return []
        }
        guard let wrapped = try? JSONDecoder().decode([Lossy].self, from: data) else {
            backUpUnreadableFile(reason: "not a JSON array of elements")
            return []
        }
        let items = wrapped.compactMap(\.value)
        if items.count < wrapped.count {
            backUpUnreadableFile(reason: "\(wrapped.count - items.count) of \(wrapped.count) elements failed to decode")
        }
        return items
    }

    /// Overwrites the stored elements with `items`.
    func save(_ items: [Element]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        setIncludedInBackup(fileURL, true)
    }

    /// Backups of files this store couldn't fully read, newest last.
    func unreadableBackups() -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        let prefix = fileURL.lastPathComponent + ".unreadable-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(prefix) }.sorted().map { directory.appendingPathComponent($0) }
    }

    /// Copies the current file aside so a later `save` can't destroy the
    /// only copy of data this build couldn't read.
    private func backUpUnreadableFile(reason: String) {
        // Same bytes as the newest backup: already kept, so every launch
        // doesn't add another copy of a file that hasn't changed.
        if let newest = unreadableBackups().last,
           let current = try? Data(contentsOf: fileURL),
           let kept = try? Data(contentsOf: newest),
           current == kept {
            return
        }
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let backup = fileURL.deletingLastPathComponent()
            .appendingPathComponent("\(fileURL.lastPathComponent).unreadable-\(stamp)-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.copyItem(at: fileURL, to: backup)
            // A diagnostic copy, not the rider's data: kept out of backups.
            setIncludedInBackup(backup, false)
            Self.log.error("Kept unreadable \(fileURL.lastPathComponent, privacy: .public) as \(backup.lastPathComponent, privacy: .public): \(reason, privacy: .public)")
        } catch {
            Self.log.error("Could not back up unreadable \(fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Decodes one element, or `nil` if that element alone is unreadable.
    private struct Lossy: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws {
            value = try? Element(from: decoder)
        }
    }
}

/// Includes a file in, or omits it from, the phone's iCloud or computer
/// backup.
func setIncludedInBackup(_ url: URL, _ included: Bool) {
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = !included
    try? url.setResourceValues(values)
}

/// Whether a file is included in backups. Nil when it can't be read.
func isIncludedInBackup(_ url: URL) -> Bool? {
    (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup).map { $0 == false }
}
