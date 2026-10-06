import SwiftUI

/// Short recommended-fuel block for Food / Coffee / Scenic. The Gas chip
/// already lists stations under Suggested Gas, so this section stays gated
/// off that category. The full corridor list is optional under disclosure.
struct GasStationsSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Recommended fuel") {
            BufferedGasApplyRow(viewModel: viewModel)
            if viewModel.isCalculating || viewModel.isSearchingGas || viewModel.gasLoadState == .pending {
                ProgressView("Searching for gas along the route…")
            } else if viewModel.showsGasLoadFailed {
                GasLoadFailedButton(viewModel: viewModel)
            } else if viewModel.showsNoGasStationsMessage {
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
            viewModel.toggleBufferedGasStop(stop)
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
                Image(systemName: viewModel.isGasBuffered(stop)
                      ? "checkmark.circle.fill"
                      : "circle")
                    .foregroundStyle(viewModel.isGasBuffered(stop) ? Color.green : Color.secondary)
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
        Section(viewModel.routeStopsTitle) {
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
            if viewModel.selectedCategory == .gas {
                BufferedGasApplyRow(viewModel: viewModel)
            }
            if viewModel.isLoadingSuggestions {
                ProgressView("Searching along your route…")
            } else if viewModel.suggestedStops.isEmpty && !viewModel.legs.isEmpty {
                if viewModel.isCalculating || viewModel.isSearchingGas || viewModel.isLoadingSuggestions {
                    ProgressView("Searching along your route…")
                } else if viewModel.selectedCategory == .gas, viewModel.showsGasLoadFailed {
                    GasLoadFailedButton(viewModel: viewModel)
                } else if viewModel.selectedCategory == .gas,
                          !viewModel.fuelStops.isEmpty || !viewModel.gasStations.isEmpty {
                    Text("Gas along this ride is listed with the fuel stops above.")
                        .foregroundStyle(.secondary)
                } else if viewModel.selectedCategory == .gas, viewModel.gasLoadState == .pending {
                    ProgressView("Searching along your route…")
                } else if viewModel.selectedCategory == .gas, viewModel.showsNoGasStationsMessage {
                    Text("No gas stations found along this route.")
                        .foregroundStyle(.secondary)
                } else if viewModel.selectedCategory != .gas {
                    Text("No \(viewModel.selectedCategory.rawValue.lowercased()) stops found near this route.")
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.legs.isEmpty {
                Text("Add a start and a destination to see suggestions.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.suggestedStops.prefix(15)) { stop in
                Button {
                    if stop.category == .gas {
                        viewModel.toggleBufferedGasStop(stop)
                    } else {
                        viewModel.addStop(from: stop)
                    }
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
                        Image(systemName: stop.category == .gas && viewModel.isGasBuffered(stop)
                              ? "checkmark.circle.fill"
                              : "plus.circle.fill")
                            .foregroundStyle(stop.category == .gas && viewModel.isGasBuffered(stop) ? Color.green : Color.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Rate-limit and other gas-search failures. Tapping reruns gas on the
/// current line; it does not say the corridor is empty.
struct GasLoadFailedButton: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Button {
            viewModel.retryGasSearch()
        } label: {
            Label(RoutePlannerViewModel.gasLoadFailedCopy, systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Checked gas stops wait here until the rider applies them in one route update.
struct BufferedGasApplyRow: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        if !viewModel.bufferedGasStops.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    viewModel.applyBufferedGasStops()
                } label: {
                    Label("Apply \(viewModel.bufferedGasStops.count) stops", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button("Clear selection") {
                    viewModel.clearBufferedGasStops()
                }
            }
        }
    }
}
