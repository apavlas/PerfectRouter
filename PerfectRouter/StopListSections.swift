import SwiftUI

/// Short recommended-fuel block for Food / Coffee / Scenic. The Gas chip
/// already lists stations under Suggested Gas, so this section stays gated
/// off that category. The full corridor list is optional under disclosure.
struct GasStationsSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Recommended fuel") {
            if viewModel.fuelStops.isEmpty && viewModel.gasStations.isEmpty {
                Text("No gas stations found along this route.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.fuelStops) { stop in
                gasRow(stop, recommended: true)
            }
            if !viewModel.gasStations.isEmpty {
                DisclosureGroup(
                    "All gas on route",
                    isExpanded: Binding(
                        get: { viewModel.isShowingAllGasOnRoute },
                        set: { viewModel.isShowingAllGasOnRoute = $0 }
                    )
                ) {
                    ForEach(viewModel.gasStations) { stop in
                        gasRow(stop, recommended: viewModel.isRecommendedFuelStop(stop))
                    }
                }
            }
        }
    }

    /// Same green/recommended row used for auto picks; tap adds the stop.
    private func gasRow(_ stop: SuggestedStop, recommended: Bool) -> some View {
        Button {
            viewModel.addStop(from: stop)
        } label: {
            HStack {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(recommended ? .green : .secondary)
                VStack(alignment: .leading) {
                    Text(stop.name)
                    Text("~\(formattedRideDistance(stop.distanceAlongRoute)) from start")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if recommended {
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
