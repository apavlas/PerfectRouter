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
    /// Owned by ContentView so a SearchSection identity reset (iPad
    /// sheet / first-responder churn) does not drop the query or results.
    @Binding var searchText: String
    @Binding var searchResults: [MKMapItem]

    @State private var showingContactPicker = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Add a destination or stop", text: $searchText)
                    .accessibilityIdentifier(AccessibilityID.placeSearch)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    // Keep the field itself the hit target. An empty parent
                    // focus container on a regular-width iPad sheet can
                    // otherwise swallow the tap (no keyboard, map pans).
                    .contentShape(Rectangle())
                // Stays in the row while the field is empty. Removing it
                // left the search stack with a focus child that appeared
                // and disappeared as a replan cleared the query.
                Button {
                    searchText = ""
                    searchResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(searchText.isEmpty ? 0 : 1)
                .disabled(searchText.isEmpty)
                .accessibilityHidden(searchText.isEmpty)
            }
            .contentShape(Rectangle())
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

            if !searchResults.isEmpty {
                ForEach(searchResults.prefix(6), id: \.self) { item in
                    Button {
                        addSearchResult(item)
                    } label: {
                        HStack {
                            Image(systemName: "plus.circle")
                                .foregroundStyle(.blue)
                            if let locality = item.placemark.locality {
                                VStack(alignment: .leading) {
                                    Text(item.name ?? "Unknown")
                                    Text(locality)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            } else {
                                Text(item.name ?? "Unknown")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(AccessibilityID.searchResult(item.name ?? "Unknown"))
                }
            } else {
                FocusPlaceholderRow()
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
        .onReceive(NotificationCenter.default.publisher(for: UITestStubLaunch.focusPlaceSearchNotification)) { _ in
            guard UITestStubLaunch.skipsOnboarding else { return }
            NSLog("PerfectRouter UITest placeSearch taking focus")
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UITestStubLaunch.typePlaceSearchNotification)) { note in
            guard UITestStubLaunch.skipsOnboarding, let text = note.object as? String else { return }
            NSLog("PerfectRouter UITest placeSearch applying %@", text)
            // Set the query only. Focusing here expands an iPad medium sheet
            // to the large detent and invalidates the map-fit check.
            searchText = text
            Task { @MainActor in
                let results = await viewModel.searchPlaces(query: text, near: currentRegion)
                    .filter { $0.placemark.coordinate.isValidLocation }
                NSLog("PerfectRouter UITest placeSearch results %d", results.count)
                searchResults = results
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
        searchFocused = false
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
