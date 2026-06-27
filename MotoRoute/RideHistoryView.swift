import SwiftUI

/// Lists past rides (sent to navigation) with summary stats and an offline
/// snapshot for each.
struct RideHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [RideLogEntry] = []
    private let store = RideLogStore()

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Rides Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Rides you open in Maps will appear here with distance and an offline snapshot.")
                    )
                } else {
                    List {
                        Section("Summary") { summary }
                        Section("Rides") {
                            ForEach(entries) { entry in row(entry) }
                                .onDelete(perform: delete)
                        }
                    }
                }
            }
            .navigationTitle("Ride History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear { entries = store.load() }
        }
    }

    // MARK: - Summary stats

    private var totalDistance: Double { entries.reduce(0) { $0 + $1.distanceMeters } }

    private var thisMonthDistance: Double {
        let calendar = Calendar.current
        return entries
            .filter { calendar.isDate($0.date, equalTo: Date(), toGranularity: .month) }
            .reduce(0) { $0 + $1.distanceMeters }
    }

    private var longestRide: Double { entries.map(\.distanceMeters).max() ?? 0 }

    /// Deletes the rides at `offsets`, removing each one's snapshot file too.
    private func delete(at offsets: IndexSet) {
        for index in offsets {
            let entry = entries[index]
            if let filename = entry.snapshotFilename {
                RouteSnapshotter.deleteSnapshot(named: filename)
            }
            store.delete(entry)
        }
        entries.remove(atOffsets: offsets)
    }

    private var summary: some View {
        VStack(spacing: 12) {
            HStack {
                statTile(title: "Rides", value: "\(entries.count)")
                Divider()
                statTile(title: "Total", value: formattedRideDistance(totalDistance))
            }
            HStack {
                statTile(title: "This Month", value: formattedRideDistance(thisMonthDistance))
                Divider()
                statTile(title: "Longest", value: formattedRideDistance(longestRide))
            }
        }
        .padding(.vertical, 4)
    }

    private func statTile(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Row

    private func row(_ entry: RideLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let filename = entry.snapshotFilename, let image = RouteSnapshotter.image(named: filename) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 140)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text(entry.name).font(.headline)
            HStack(spacing: 12) {
                Label(formattedRideDistance(entry.distanceMeters), systemImage: "road.lanes")
                Label(entry.date.formatted(.dateTime.month().day().year()), systemImage: "calendar")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    RideHistoryView()
}
