import SwiftUI

/// Lists rides the rider has saved on this device. Tap to reload one,
/// swipe to delete.
struct SavedRoutesSection: View {
    let viewModel: RoutePlannerViewModel
    /// Called when the rider taps a saved ride, so the caller can load it and
    /// frame its start on the map.
    let onLoad: (SavedRoute) -> Void

    var body: some View {
        Section("Saved Routes") {
            if viewModel.savedRoutes.isEmpty {
                Text("Save a ride with the bookmark button to find it here later.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.savedRoutes) { saved in
                Button {
                    onLoad(saved)
                } label: {
                    HStack {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(saved.name)
                            Text(saved.savedAt, format: .dateTime.month().day().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { viewModel.deleteSavedRoutes(at: $0) }
        }
    }
}
