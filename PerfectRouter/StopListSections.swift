import SwiftUI

/// Lists every gas station found along the route so the rider can pick any
/// of them. The auto-recommended fuel stops are badged. Shown while
/// browsing a non-gas category (the Gas category already lists these in
/// the suggestions section).
struct GasStationsSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Gas Stations on Route") {
            if viewModel.gasStations.isEmpty {
                Text("No gas stations found along this route.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.gasStations) { stop in
                Button {
                    viewModel.addStop(from: stop)
                } label: {
                    HStack {
                        Image(systemName: "fuelpump.fill")
                            .foregroundStyle(viewModel.isRecommendedFuelStop(stop) ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(stop.name)
                            Text("~\(formattedRideDistance(stop.distanceAlongRoute)) from start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewModel.isRecommendedFuelStop(stop) {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The ordered ride: start, stops, and destination. Supports swipe-to-delete
/// and drag-to-reorder, plus a fallback for setting a start when there's no
/// location fix.
struct WaypointsSection: View {
    let viewModel: RoutePlannerViewModel
    /// Drops a start point at the center of the visible map, used when
    /// there's no location fix to route from.
    let onUseMapCenterAsStart: () -> Void

    var body: some View {
        Section("Route (\(viewModel.waypoints.count) stops)") {
            if viewModel.waypoints.isEmpty {
                Text(viewModel.currentLocation == nil
                     ? "Long-press the map or use the button below to set a start, then search for your destination."
                     : "Search for your destination — we'll route from your current location.")
                    .foregroundStyle(.secondary)
            }
            // When there's no location fix to auto-seed the origin, let the
            // rider drop a start point at the center of the visible map. A new
            // start is inserted ahead of any place already added, so it becomes
            // the ride origin.
            if viewModel.currentLocation == nil, viewModel.waypoints.count < 2 {
                Button {
                    onUseMapCenterAsStart()
                } label: {
                    Label("Use Current Map Area as Start", systemImage: "mappin.and.ellipse")
                }
            }
            ForEach(viewModel.waypoints) { waypoint in
                Label(waypoint.name, systemImage: "mappin.circle.fill")
            }
            .onDelete { viewModel.removeWaypoint(at: $0) }
            .onMove { viewModel.moveWaypoint(from: $0, to: $1) }
        }
    }
}

/// Recommended stops along the route for the selected category — tap to add.
struct SuggestionsSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Suggested \(viewModel.selectedCategory.rawValue) Stops") {
            if viewModel.isLoadingSuggestions {
                ProgressView("Searching along your route…")
            } else if viewModel.suggestedStops.isEmpty && !viewModel.legs.isEmpty {
                Text("No \(viewModel.selectedCategory.rawValue.lowercased()) stops found near this route.")
                    .foregroundStyle(.secondary)
            } else if viewModel.legs.isEmpty {
                Text("Add at least two stops to see suggestions.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.suggestedStops.prefix(15)) { stop in
                Button {
                    viewModel.addStop(from: stop)
                } label: {
                    HStack {
                        Image(systemName: stop.category.systemImage)
                        VStack(alignment: .leading) {
                            Text(stop.name)
                            Text("~\(formattedRideDistance(stop.distanceAlongRoute)) from start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
