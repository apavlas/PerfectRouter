import SwiftUI

/// Short recommended-fuel block for Food / Coffee / Scenic. The Gas chip
/// already lists stations under Suggested Gas, so this section stays gated
/// off that category. The full corridor list is optional under disclosure.
struct GasStationsSection: View {
    let viewModel: RoutePlannerViewModel

    /// False when the section would have no rows. Callers omit the view
    /// entirely; an empty section aborts iPad focus updates.
    static func hasContent(_ viewModel: RoutePlannerViewModel) -> Bool {
        !viewModel.selectableRecommendedFuelStops.isEmpty
            || !viewModel.bufferedGasStops.isEmpty
            || viewModel.isCalculating
            || viewModel.isSearchingGas
            || viewModel.gasLoadState == .pending
            || viewModel.showsGasLoadFailed
            || viewModel.showsNoGasStationsMessage
            || !viewModel.visibleFuelPlanEntries.isEmpty
            || !viewModel.gasStations.isEmpty
    }

    var body: some View {
        Section("Recommended fuel") {
                if !viewModel.selectableRecommendedFuelStops.isEmpty {
                    SelectRecommendedFuelButton(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                if !viewModel.bufferedGasStops.isEmpty {
                    BufferedGasApplyRow(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                if viewModel.isCalculating || viewModel.isSearchingGas || viewModel.gasLoadState == .pending {
                    ProgressView("Searching for gas along the route…")
                        .focusable()
                } else if viewModel.showsGasLoadFailed {
                    GasLoadFailedButton(viewModel: viewModel)
                } else if viewModel.showsNoGasStationsMessage {
                    Text("No gas stations found along this route.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.noGasStations)
                        .focusable()
                } else {
                    FocusPlaceholderRow()
                }
                if !viewModel.visibleFuelPlanEntries.isEmpty {
                    ForEach(viewModel.visibleFuelPlanEntries) { entry in
                        switch entry {
                        case .recommended(let stop):
                            gasRow(stop, recommended: true, pastRange: false)
                        case .gap(let gap):
                            Label(gap.warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .font(.subheadline)
                                .focusable()
                        case .pastRange(let stop):
                            gasRow(stop, recommended: false, pastRange: true)
                        }
                    }
                } else {
                    FocusPlaceholderRow()
                }
                if !viewModel.gasStations.isEmpty {
                    Button {
                        viewModel.isShowingAllGasOnRoute.toggle()
                    } label: {
                        HStack {
                            Text("All gas on route")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(viewModel.isShowingAllGasOnRoute ? 90 : 0))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    FocusPlaceholderRow()
                }
                if viewModel.isShowingAllGasOnRoute, !viewModel.gasStations.isEmpty {
                    ForEach(viewModel.gasStations) { stop in
                        gasRow(stop, recommended: viewModel.isRecommendedFuelStop(stop))
                    }
                } else {
                    FocusPlaceholderRow()
                }
        }
    }

    /// Same green/recommended row used for auto picks; tap adds the stop.
    /// A station past the tank is listed, but not as a normal fuel stop.
    /// A place already on the route is shown as added and cannot be checked.
    @ViewBuilder
    private func gasRow(_ stop: SuggestedStop, recommended: Bool, pastRange: Bool = false) -> some View {
        let onRoute = viewModel.isStopOnRoute(stop)
        let markedPast = pastRange || viewModel.isPastRangeFuelStop(stop)
        let showsRidingTime = recommended || viewModel.isRecommendedFuelStop(stop) || markedPast
        let caption = showsRidingTime
            ? viewModel.fuelStopRidingCaption(for: stop, pastRange: markedPast)
            : "~\(formattedRideDistance(stop.distanceAlongRoute)) from start"
        let accessibility = viewModel.recommendedFuelAccessibility(for: stop)
        let title = accessibility?.title ?? stop.name
        let button = Button {
            guard !onRoute else { return }
            viewModel.toggleBufferedGasStop(stop)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(markedPast ? Color.orange : (recommended ? Color.green : Color.secondary))
                    .accessibilityHidden(true)
                FuelStopTextColumn(title: title, caption: caption)
                if onRoute {
                    Text("Added")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if markedPast {
                    Text("Past your range")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                } else if recommended {
                    Text("Recommended")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
                if !onRoute {
                    Image(systemName: viewModel.isGasBuffered(stop)
                          ? "checkmark.circle.fill"
                          : "circle")
                        .foregroundStyle(viewModel.isGasBuffered(stop) ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onRoute)

        if let accessibility {
            button.fuelRowAccessibility(accessibility) {
                guard !onRoute else { return }
                viewModel.toggleBufferedGasStop(stop)
            }
        } else {
            button
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
        Section {
            if viewModel.waypoints.isEmpty {
                Text(viewModel.currentLocation == nil
                     ? "Long-press the map or use the button below to set a start, then search for your destination."
                     : "Search for your destination — we'll route from your current location.")
                    .foregroundStyle(.secondary)
                    .focusable()
            } else {
                FocusPlaceholderRow()
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
            } else {
                FocusPlaceholderRow()
            }
            if !viewModel.waypoints.isEmpty {
                ForEach(Array(viewModel.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    let label = waypointAccessibilityLabel(index: index, waypoint: waypoint)
                    waypointRow(index: index, waypoint: waypoint)
                        // The representation is the element XCUITest queries.
                        // Combining the name and the riding-time caption left
                        // the identifier on a child the query does not return.
                        .accessibilityLabel(label)
                        .accessibilityIdentifier(AccessibilityID.waypoint(waypoint.name))
                        .accessibilityRepresentation {
                            Text(label)
                                .accessibilityIdentifier(AccessibilityID.waypoint(waypoint.name))
                        }
                }
                .onDelete { viewModel.removeWaypoint(at: $0) }
                .onMove { viewModel.moveWaypoint(from: $0, to: $1) }
            } else {
                FocusPlaceholderRow()
            }
        } header: {
            Text(viewModel.routeStopsTitle)
                .accessibilityIdentifier(AccessibilityID.routeGeneration(viewModel.calculatingGeneration))
        }
    }

    /// Pin plus name. Every row after the origin, including the destination,
    /// adds the same riding-time line the fuel rows use. The destination's
    /// line is the whole trip. The caption is a second text only inside a
    /// stack that already has the name — the other branch is the name alone,
    /// so a replan never leaves an empty stack in the row.
    @ViewBuilder
    private func waypointRow(index: Int, waypoint: Waypoint) -> some View {
        Label {
            if let caption = viewModel.waypointRidingCaption(at: index) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(waypoint.name)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(4)
                }
            } else {
                Text(waypoint.name)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
            }
        } icon: {
            Image(systemName: "mappin.circle.fill")
                .accessibilityHidden(true)
        }
    }

    private func waypointAccessibilityLabel(index: Int, waypoint: Waypoint) -> String {
        if let caption = viewModel.waypointRidingCaption(at: index) {
            return "\(waypoint.name), \(caption)"
        }
        return waypoint.name
    }
}

/// Recommended stops along the route for the selected category — tap to add.
struct SuggestionsSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Suggested \(viewModel.selectedCategory.rawValue) Stops") {
            if viewModel.selectedCategory == .gas {
                if !viewModel.selectableRecommendedFuelStops.isEmpty {
                    SelectRecommendedFuelButton(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                if !viewModel.bufferedGasStops.isEmpty {
                    BufferedGasApplyRow(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
            } else {
                FocusPlaceholderRow()
            }
            if viewModel.isLoadingSuggestions {
                ProgressView("Searching along your route…")
                    .focusable()
            } else if viewModel.suggestedStops.isEmpty && !viewModel.legs.isEmpty {
                if viewModel.isCalculating || viewModel.isSearchingGas || viewModel.isLoadingSuggestions {
                    ProgressView("Searching along your route…")
                        .focusable()
                } else if viewModel.selectedCategory == .gas, viewModel.showsGasLoadFailed {
                    GasLoadFailedButton(viewModel: viewModel)
                } else if viewModel.selectedCategory == .gas,
                          !viewModel.fuelStops.isEmpty || !viewModel.gasStations.isEmpty {
                    Text("Gas along this ride is listed with the fuel stops above.")
                        .foregroundStyle(.secondary)
                        .focusable()
                } else if viewModel.selectedCategory == .gas, viewModel.gasLoadState == .pending {
                    ProgressView("Searching along your route…")
                        .focusable()
                } else if viewModel.selectedCategory == .gas, viewModel.showsNoGasStationsMessage {
                    Text("No gas stations found along this route.")
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier(AccessibilityID.noGasStations)
                        .focusable()
                } else if viewModel.selectedCategory != .gas {
                    Text("No \(viewModel.selectedCategory.rawValue.lowercased()) stops found near this route.")
                        .foregroundStyle(.secondary)
                        .focusable()
                } else {
                    // Keeps the section from publishing an empty container in
                    // the gap between gas states. Not the in-progress copy;
                    // that string is how the ride screen tells a search is
                    // still running.
                    Text("Fuel stops update with the route.")
                        .foregroundStyle(.secondary)
                        .focusable()
                }
            } else if viewModel.legs.isEmpty {
                Text("Add a start and a destination to see suggestions.")
                    .foregroundStyle(.secondary)
                    .focusable()
            } else {
                FocusPlaceholderRow()
            }
            if !viewModel.suggestedStops.isEmpty, viewModel.addableSuggestions.isEmpty, !viewModel.legs.isEmpty {
                Text("Stops already on this route aren't listed again.")
                    .foregroundStyle(.secondary)
                    .focusable()
            } else {
                FocusPlaceholderRow()
            }
            if !viewModel.addableSuggestions.isEmpty {
                ForEach(viewModel.addableSuggestions.prefix(15)) { stop in
                    suggestionButton(stop)
                }
            } else {
                FocusPlaceholderRow()
            }
        }
    }

    /// The distance line is always present, so the row stack does not gain
    /// and lose a child when a replan reclassifies the stop.
    @ViewBuilder
    private func suggestionButton(_ stop: SuggestedStop) -> some View {
        let caption = viewModel.fuelStopListCaption(for: stop)
            ?? "~\(formattedRideDistance(stop.distanceAlongRoute)) from start"
        let accessibility = viewModel.recommendedFuelAccessibility(for: stop)
        let title = accessibility?.title ?? stop.name
        let button = Button {
            if stop.category == .gas {
                viewModel.toggleBufferedGasStop(stop)
            } else {
                viewModel.addStop(from: stop)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: stop.category.systemImage)
                    .accessibilityHidden(true)
                FuelStopTextColumn(title: title, caption: caption)
                Image(systemName: stop.category == .gas && viewModel.isGasBuffered(stop)
                      ? "checkmark.circle.fill"
                      : "plus.circle.fill")
                    .foregroundStyle(stop.category == .gas && viewModel.isGasBuffered(stop) ? Color.green : Color.blue)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(.plain)

        if let accessibility {
            button.fuelRowAccessibility(accessibility) {
                if stop.category == .gas {
                    viewModel.toggleBufferedGasStop(stop)
                } else {
                    viewModel.addStop(from: stop)
                }
            }
        } else {
            button
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

/// One tap checks every recommended fuel stop. When those are all checked,
/// the same button clears them. Sits at the top of the buffered gas rows.
private struct SelectRecommendedFuelButton: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Button(viewModel.selectRecommendedButtonTitle) {
            viewModel.toggleRecommendedFuelSelection()
        }
        .accessibilityIdentifier(AccessibilityID.selectRecommended)
    }
}

/// Station name, then the distance and riding-time caption. The name wraps
/// on iPhone, iPad, and Mac. No `frame` or `fixedSize`: those wrappers were
/// focus containers UIKit visited with no children on iPad.
struct FuelStopTextColumn: View {
    let title: String
    let caption: String
    var titleColor: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.leading)
                .lineLimit(8)
            Text(caption)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(6)
        }
    }
}

/// Leaf stand-in for a list `if` whose real row is absent. A bare `if` in a
/// `List` is a focus container, and iPad aborts in UIFocusSystem when that
/// container's children drop to zero during a replan.
struct FocusPlaceholderRow: View {
    var body: some View {
        Text(verbatim: " ")
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
            .accessibilityHidden(true)
            .focusable()
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}

extension View {
    /// Puts the fuel-stop identifier on the element XCUITest queries.
    /// `children: .combine` kept that identifier on a container the query
    /// does not return once the row held a caption stack. The stand-in
    /// button performs the same check as the row.
    func fuelRowAccessibility(
        _ accessibility: RecommendedFuelAccessibility,
        action: @escaping () -> Void
    ) -> some View {
        accessibilityLabel(accessibility.label)
            .accessibilityIdentifier(accessibility.identifier)
            .accessibilityAddTraits(.isButton)
            .accessibilityRepresentation {
                Button(action: action) {
                    Text(verbatim: accessibility.label)
                }
                .accessibilityIdentifier(accessibility.identifier)
            }
    }
}

/// Checked gas stops wait here until the rider applies them in one route update.
struct BufferedGasApplyRow: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.applyBufferedGasStops()
            } label: {
                Label("Apply \(viewModel.bufferedGasStops.count) stops", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.applyStops)

            Button("Clear selection") {
                viewModel.clearBufferedGasStops()
            }
        }
    }
}
