import SwiftUI
import MapKit
import Contacts

/// Always-visible search field for adding a destination or stop (replaces
/// `.searchable`, which was hidden when the sheet sat at its smallest detent),
/// plus the Contacts entry point and the live result list.
struct SearchSection: View {
    let viewModel: RoutePlannerViewModel
    /// The visible map region, used to bias place search toward what the
    /// rider is looking at.
    let currentRegion: MKCoordinateRegion
    /// Called with each added waypoint so the map can frame it.
    let onWaypointAdded: (Waypoint) -> Void

    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showingContactPicker = false

    var body: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Add a destination or stop", text: $searchText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Live search, debounced: re-fires 0.4s after the user stops typing.
            .task(id: searchText) {
                guard !searchText.isEmpty else {
                    searchResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                searchResults = await viewModel.searchPlaces(query: searchText, near: currentRegion)
                    .filter { $0.placemark.coordinate.isValidLocation }
            }

            Button {
                showingContactPicker = true
            } label: {
                Label("Choose from Contacts", systemImage: "person.crop.circle")
            }

            ForEach(searchResults.prefix(6), id: \.self) { item in
                Button {
                    addSearchResult(item)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unknown")
                            if let locality = item.placemark.locality {
                                Text(locality)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        // The contact picker presents itself modally, so it lives invisibly in
        // the background rather than as a `.sheet` (which made it flash and
        // dismiss on the first tap).
        .background {
            ContactAddressPicker(isPresented: $showingContactPicker) { name, address in
                addContactAddress(named: name, at: address)
            }
        }
    }

    private func addSearchResult(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        // Ignore results with no usable coordinate (invalid / NaN) — adding one
        // would crash MapKit when routing or recentering the map on it.
        guard coordinate.isValidLocation else { return }
        let waypoint = Waypoint(name: item.name ?? "Stop", coordinate: coordinate)
        viewModel.addWaypoint(waypoint)
        searchResults = []
        searchText = ""
        onWaypointAdded(waypoint)
    }

    /// Geocodes a postal address chosen from Contacts and adds it as a waypoint,
    /// framing it on the map once it resolves.
    private func addContactAddress(named name: String, at address: CNPostalAddress) {
        Task {
            if let waypoint = await viewModel.addWaypoint(named: name, at: address) {
                onWaypointAdded(waypoint)
            }
        }
    }
}
