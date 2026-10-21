import SwiftUI

/// Decides whether the gas section is on the sheet. The selecting flag is
/// read only by `FuelSelectionSpinnerSlot`, so a tap does not rebuild the
/// route list or the suggestion labels.
struct GasStationsSectionGate: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        if viewModel.selectedCategory != .gas,
           !viewModel.legs.isEmpty,
           GasStationsSection.hasContent(viewModel) {
            GasStationsSection(viewModel: viewModel)
        } else {
            FocusPlaceholderRow()
        }
    }
}

/// Short recommended-fuel block for Food / Coffee / Scenic. The Gas chip
/// already lists stations under Suggested Gas, so this section stays gated
/// off that category. The full corridor list is optional under disclosure.
struct GasStationsSection: View {
    let viewModel: RoutePlannerViewModel

    @Environment(\.planningUsesSidebar) private var planningUsesSidebar

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
                FuelSelectionSpinnerSlot(viewModel: viewModel)
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
        let along = viewModel.distanceFromStart(of: stop)
        let stored = viewModel.fuelRowLabel(for: stop)
        let markedPast = stored?.pastFullTank == true
            || pastRange
            || viewModel.isPastRangeFuelStop(stop)
            || viewModel.isBeyondRemainingRange(distanceAlongRoute: along)
        let pastFullTank = stored?.pastFullTank == true
            ? RoutePlannerViewModel.pastFullTankNotice
            : (stored == nil ? viewModel.fuelListNote(for: stop) : nil)
        let title = stored?.title ?? stop.name
        let caption = stored?.caption ?? milesFromStartCaption(along)
        let accessibility = fuelAccessibility(
            stored.flatMap { label in
                label.pastFullTank ? nil : RecommendedFuelAccessibility(
                    identifier: label.identifier,
                    label: label.accessibilityLabel,
                    title: label.title,
                    caption: label.caption
                )
            },
            appending: pastFullTank
        )
        let button = Button {
            guard !onRoute else { return }
            focusFromSidebar(stop)
            viewModel.toggleBufferedGasStop(stop)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "fuelpump.fill")
                    .foregroundStyle(markedPast ? Color.orange : (recommended ? Color.green : Color.secondary))
                    .accessibilityHidden(true)
                FuelStopTextColumn(
                    title: title,
                    caption: caption,
                    rowIdentifier: accessibility?.identifier ?? ""
                )
                if onRoute {
                    Text("Added")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if pastFullTank != nil {
                    PastFullTankLabel()
                } else if markedPast {
                    PastYourRangeLabel()
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
            listedStop(button.fuelRowAccessibility(accessibility), stop: stop)
        } else if let pastFullTank {
            listedStop(button.accessibilityLabel("\(title), \(caption), \(pastFullTank)"), stop: stop)
        } else {
            listedStop(button, stop: stop)
        }
    }

    /// Centers the map when this list is the sidebar. The gas disclosure can
    /// repeat a fuel-plan row, so this copy is not a scroll target.
    private func listedStop<V: View>(_ row: V, stop: SuggestedStop) -> some View {
        row.sidebarStopHighlight(selected: viewModel.highlightedStopID == stop.id)
    }

    private func focusFromSidebar(_ stop: SuggestedStop) {
        guard planningUsesSidebar else { return }
        viewModel.focusListedStop(id: stop.id, coordinate: stop.coordinate)
    }

    /// The note is folded into the accessibility value before the row is
    /// built. An assignment inside `gasRow` is a statement, and a view
    /// builder cannot turn that statement into a view.
    private func fuelAccessibility(
        _ accessibility: RecommendedFuelAccessibility?,
        appending note: String?
    ) -> RecommendedFuelAccessibility? {
        guard var accessibility else { return nil }
        if let note {
            accessibility.label = "\(accessibility.label), \(note)"
        }
        return accessibility
    }
}

/// The representation is the element XCUITest queries. Combining the name
/// and the riding-time caption left the identifier on a child the query
/// does not return. Applied to the outermost row view in either layout.
private struct WaypointAccessibility: ViewModifier {
    var label: String
    var name: String

    func body(content: Content) -> some View {
        content
            .accessibilityLabel(label)
            .accessibilityIdentifier(AccessibilityID.waypoint(name))
            .accessibilityRepresentation {
                Text(label)
                    .accessibilityIdentifier(AccessibilityID.waypoint(name))
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

    @Environment(\.planningUsesSidebar) private var planningUsesSidebar

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
                ForEach(viewModel.routeListEntries) { entry in
                    if let day = entry.dayMarker {
                        dayMarkerRow(day)
                            .moveDisabled(true)
                    } else if let index = entry.waypointIndex, viewModel.waypoints.indices.contains(index) {
                        let waypoint = viewModel.waypoints[index]
                        let label = waypointAccessibilityLabel(
                            index: index,
                            waypoint: waypoint,
                            dayTitle: entry.headingTitle
                        )
                        waypointCell(
                            index: index,
                            waypoint: waypoint,
                            label: label,
                            heading: entry.headingTitle
                        )
                    } else if let day = entry.unpickedDay {
                        noHotelRow(day, heading: entry.headingTitle)
                            .moveDisabled(true)
                    } else {
                        FocusPlaceholderRow()
                    }
                }
                .onDelete { viewModel.removeListedWaypoints(at: $0) }
                .onMove { viewModel.moveListedWaypoints(from: $0, to: $1) }
            } else {
                FocusPlaceholderRow()
            }
        } header: {
            Text(viewModel.routeStopsTitle)
                .accessibilityIdentifier(AccessibilityID.routeGeneration(viewModel.calculatingGeneration))
        }
    }

    /// Phone and portrait keep a plain row. The sidebar wraps the same row in
    /// a button so a tap centers the map. Both branches carry the identifier
    /// XCUITest queries; it is not on an inner text, which the query misses.
    @ViewBuilder
    private func waypointCell(
        index: Int,
        waypoint: Waypoint,
        label: String,
        heading: String?
    ) -> some View {
        if planningUsesSidebar {
            Button {
                viewModel.focusListedStop(id: waypoint.id, coordinate: waypoint.coordinate)
            } label: {
                waypointRow(index: index, waypoint: waypoint, heading: heading)
            }
            .buttonStyle(.plain)
            .sidebarStopHighlight(selected: viewModel.highlightedStopID == waypoint.id)
            .modifier(WaypointAccessibility(label: label, name: waypoint.name))
        } else {
            waypointRow(index: index, waypoint: waypoint, heading: heading)
                .modifier(WaypointAccessibility(label: label, name: waypoint.name))
        }
    }

    /// Pin plus name. The caption is `waypointRidingCaption` (not the fuel
    /// sheet's `fuelStopRidingCaption`). The first stop has no since-last
    /// clause; later stops keep it. The caption is a second text only inside
    /// a stack that already has the name — the other branch is the name alone,
    /// so a replan never leaves an empty stack in the row.
    @ViewBuilder
    private func waypointRow(
        index: Int,
        waypoint: Waypoint,
        heading: String?
    ) -> some View {
        let pastRange = viewModel.waypointIsBeyondRemainingRange(at: index)
        let dayTitle = FeatureFlags.hotelsAlongRoute
            ? (heading ?? viewModel.rideDayTitle(at: index))
            : nil
        let ending = viewModel.rideDayEnding(atWaypoint: index)
        let overDay: Int? = ending?.exceedsDailyLimit == true ? ending?.dayNumber : nil
        Label {
            if let caption = viewModel.waypointRidingCaption(at: index) {
                VStack(alignment: .leading, spacing: 2) {
                    dayHeadingSlot(dayTitle)
                    waypointName(waypoint)
                    ridingCaption(caption, overLimitDay: overDay)
                    if pastRange {
                        PastYourRangeLabel()
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            } else if pastRange || dayTitle != nil {
                VStack(alignment: .leading, spacing: 2) {
                    dayHeadingSlot(dayTitle)
                    waypointName(waypoint)
                    if pastRange {
                        PastYourRangeLabel()
                    } else {
                        Color.clear.frame(height: 1)
                    }
                }
            } else {
                waypointName(waypoint)
            }
        } icon: {
            Image(systemName: FeatureFlags.hotelsAlongRoute && waypoint.isOvernight ? "bed.double.fill" : "mappin.circle.fill")
                .accessibilityHidden(true)
        }
        .id(waypoint.id)
    }

    /// Visible "Day N" on the stop. The findable `rideDay.Day N` id lives on
    /// `dayMarkerRow`, outside the waypoint accessibility stand-in. The other
    /// branch is a one-point text so the stack does not drop to zero children
    /// when a replan has not published the day yet.
    @ViewBuilder
    private func dayHeadingSlot(_ title: String?) -> some View {
        if let title {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .accessibilityHidden(true)
        } else {
            Text(verbatim: " ")
                .font(.system(size: 1))
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityHidden(true)
        }
    }

    /// One header per riding day, as its own list row. The waypoint row keeps
    /// `waypoint.<name>`. Both the day id and the limit id are on this row so
    /// a query can find them after Apply. A missing day has no row.
    private func dayMarkerRow(_ day: HotelAlongRoute.RideDay) -> some View {
        let limit = day.exceedsDailyLimit ? "over" : "ok"
        return VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: "Day \(day.dayNumber)")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityIdentifier("rideDay.Day \(day.dayNumber)")
                .accessibilityLabel("Day \(day.dayNumber)")
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: limit)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityIdentifier(AccessibilityID.rideDayLimit(day.dayNumber))
                .accessibilityLabel(limit)
            if day.exceedsDailyLimit {
                Text(verbatim: "over")
                    .font(.system(size: 1))
                    .foregroundStyle(.clear)
                    .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                    .accessibilityIdentifier(AccessibilityID.rideDayOverLimit(day.dayNumber))
                    .accessibilityLabel("over")
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    /// Planned evening with no hotel. Ends that riding day and reopens the
    /// picker for it. The row stays even when a later night's hotel is applied.
    private func noHotelRow(
        _ day: HotelAlongRoute.RideDay,
        heading: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            dayHeadingSlot(heading)
            Text(HotelAlongRoute.noHotelPickedCopy)
                .accessibilityIdentifier(AccessibilityID.noHotelPicked(day.dayNumber))
                .accessibilityLabel(HotelAlongRoute.noHotelPickedCopy)
            ridingCaption(
                viewModel.rideDayCaption(day),
                overLimitDay: day.exceedsDailyLimit ? day.dayNumber : nil
            )
            Button("Choose") {
                viewModel.focusHotelEvening(day.unpickedEvening ?? day.dayNumber)
            }
            .buttonStyle(.borderless)
            .accessibilityIdentifier(AccessibilityID.chooseHotel(day.dayNumber))
        }
    }

    @ViewBuilder
    private func ridingCaption(_ caption: String, overLimitDay: Int?) -> some View {
        if let overLimitDay {
            Text(caption)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.orange)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
                .accessibilityIdentifier(AccessibilityID.rideDayOverLimit(overLimitDay))
        } else {
            Text(caption)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(4)
        }
    }

    private func waypointName(_ waypoint: Waypoint) -> some View {
        Text(waypoint.name)
            .multilineTextAlignment(.leading)
            .lineLimit(4)
            .accessibilityIdentifier(AccessibilityID.waypoint(waypoint.name))
    }

    private func waypointAccessibilityLabel(index: Int, waypoint: Waypoint, dayTitle: String? = nil) -> String {
        var parts: [String] = []
        if FeatureFlags.hotelsAlongRoute, let day = dayTitle ?? viewModel.rideDayTitle(at: index) {
            parts.append(day)
        }
        parts.append(waypoint.name)
        if let caption = viewModel.waypointRidingCaption(at: index) {
            parts.append(caption)
        }
        parts.append(contentsOf: viewModel.waypointRangeNotices(at: index))
        return parts.joined(separator: ", ")
    }
}

/// Orange caption on a stop the remaining tank cannot reach.
struct PastYourRangeLabel: View {
    var body: some View {
        Text("Past your range")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
    }
}

/// Short note when the nearest station is farther than the full tank.
struct PastFullTankLabel: View {
    var body: some View {
        Text(RoutePlannerViewModel.pastFullTankNotice)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
    }
}

/// Recommended stops along the route for the selected category — tap to add.
struct SuggestionsSection: View {
    let viewModel: RoutePlannerViewModel
    /// Same binding as ride highlights. The sheet is presented by the
    /// planning sheet, not by this list section.
    @Binding var openDescription: OpenPlaceDescription?

    @Environment(\.planningUsesSidebar) private var planningUsesSidebar

    var body: some View {
        // Rows are written in this builder. A `Group` or stack returned from
        // another property becomes one cell, and the header stops toggling.
        Section {
            if viewModel.selectedCategory == .gas {
                if viewModel.showsSelectRecommendedFuelButton {
                    SelectRecommendedFuelButton(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                FuelSelectionSpinnerSlot(viewModel: viewModel)
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
                Text(viewModel.suggestedStops.allSatisfy { viewModel.isStopOnRoute($0) }
                     ? "Stops already on this route aren't listed again."
                     : "Gas along this ride is listed with the fuel stops above.")
                    .foregroundStyle(.secondary)
                    .focusable()
            } else {
                FocusPlaceholderRow()
            }
            if viewModel.selectedCategory == .gas, !viewModel.gasListStations.isEmpty {
                let grouping = viewModel.gasListGrouping
                let expanded = viewModel.gasListExpanded
                CollapsibleSectionHeader(
                    title: CollapsibleListCopy.gasTitle(count: grouping.stationCount),
                    expanded: expanded,
                    identifier: AccessibilityID.gasListHeader,
                    label: CollapsibleListCopy.stateLabel(
                        title: CollapsibleListCopy.gasTitle(count: grouping.stationCount),
                        expanded: expanded,
                        pastRange: grouping.pastRange
                    ),
                    showsPastRange: !expanded && grouping.pastRange,
                    action: { viewModel.toggleGasList() }
                )
                if expanded, !viewModel.gasListRows.isEmpty {
                    let stops = Dictionary(
                        viewModel.gasListStations.map { ($0.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    ForEach(viewModel.gasListRows) { row in
                        gasListRow(row, stops: stops)
                    }
                } else {
                    FocusPlaceholderRow()
                }
            } else if viewModel.selectedCategory == .food {
                let foodStops = viewModel.suggestionListStops.filter { $0.category == .food }
                let expanded = viewModel.foodListExpanded
                CollapsibleSectionHeader(
                    title: CollapsibleListCopy.foodTitle(count: foodStops.count),
                    expanded: expanded,
                    identifier: AccessibilityID.foodListHeader,
                    label: CollapsibleListCopy.stateLabel(
                        title: CollapsibleListCopy.foodTitle(count: foodStops.count),
                        expanded: expanded
                    ),
                    showsPastRange: false,
                    action: { viewModel.toggleFoodList() }
                )
                if expanded, !foodStops.isEmpty {
                    ForEach(foodStops) { stop in
                        suggestionButton(stop)
                    }
                } else {
                    FocusPlaceholderRow()
                }
            } else if !viewModel.suggestionListStops.isEmpty {
                ForEach(viewModel.suggestionListStops) { stop in
                    suggestionButton(stop)
                }
            } else {
                FocusPlaceholderRow()
            }
        } header: {
            suggestionSectionHeader
        }
    }

    /// Gas and food draw their own counted header as a row, so the section
    /// title is not a second copy. Other categories keep the plain title.
    @ViewBuilder
    private var suggestionSectionHeader: some View {
        if viewModel.selectedCategory == .gas || viewModel.selectedCategory == .food {
            Text(verbatim: " ")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityHidden(true)
        } else {
            Text("Suggested \(viewModel.selectedCategory.rawValue) Stops")
        }
    }

    /// Suggested Gas rows. Select recommended and Apply stay above these, so
    /// they remain on screen while the station rows are collapsed. The same
    /// rows are the sheet on iPhone and iPad portrait and the sidebar on
    /// iPad landscape and Mac.
    @ViewBuilder
    private func gasListRow(
        _ row: GasListGrouping.Row,
        stops: [UUID: SuggestedStop]
    ) -> some View {
        switch row {
        case .dayHeader(let day):
            let expanded = viewModel.isGasDayExpanded(day.dayNumber)
            CollapsibleSectionHeader(
                title: CollapsibleListCopy.dayTitle(day.dayNumber),
                expanded: expanded,
                identifier: AccessibilityID.gasDay(day.dayNumber),
                label: CollapsibleListCopy.stateLabel(
                    title: CollapsibleListCopy.dayTitle(day.dayNumber),
                    expanded: expanded,
                    pastRange: day.pastRange
                ),
                showsPastRange: !expanded && day.pastRange,
                action: { viewModel.toggleGasDay(day.dayNumber) }
            )
        case .legHeader(let leg):
            legHeader(leg)
        case .station(let station):
            if let stop = stops[station.id] {
                suggestionButton(stop)
            } else {
                FocusPlaceholderRow()
            }
        case .showMore(let legNumber, let expanded):
            Button(CollapsibleListCopy.showMoreTitle(expanded: expanded)) {
                viewModel.toggleGasLegOverflow(legNumber)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.gasLegShowMore(legNumber))
        }
    }

    private func legHeader(_ leg: GasListGrouping.Leg) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(leg.title)
                .font(.subheadline.weight(.semibold))
                .multilineTextAlignment(.leading)
                .accessibilityIdentifier(AccessibilityID.gasLeg(leg.number))
                .accessibilityLabel(GasListGrouping.legAccessibilityLabel(
                    title: leg.title,
                    pastRange: leg.pastRange
                ))
            Spacer(minLength: 8)
            if leg.pastRange {
                PastYourRangeLabel()
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The distance line is always present, so the row stack does not gain
    /// and lose a child when a replan reclassifies the stop.
    @ViewBuilder
    private func suggestionButton(_ stop: SuggestedStop) -> some View {
        let along = viewModel.distanceFromStart(of: stop)
        let stored = viewModel.fuelRowLabel(for: stop)
        let title = stored?.title ?? stop.name
        let caption = stored?.caption ?? milesFromStartCaption(along)
        let accessibility = stored.flatMap { label -> RecommendedFuelAccessibility? in
            guard !label.pastFullTank else { return nil }
            return RecommendedFuelAccessibility(
                identifier: label.identifier,
                label: label.accessibilityLabel,
                title: label.title,
                caption: label.caption
            )
        }
        let pastRange = stored?.pastFullTank == true
            || viewModel.isPastRangeFuelStop(stop)
            || viewModel.isBeyondRemainingRange(distanceAlongRoute: along)
        if stop.category.showsPlaceDescription {
            describedSuggestion(
                stop,
                title: title,
                caption: caption,
                pastRange: pastRange,
                accessibility: accessibility
            )
        } else {
            fuelSuggestionButton(
                stop,
                title: title,
                caption: caption,
                pastRange: pastRange,
                accessibility: accessibility
            )
        }
    }

    /// Scenic and sights cards. The distance caption and the Add button stay
    /// in the same places; the description sits under the name.
    @ViewBuilder
    private func describedSuggestion(
        _ stop: SuggestedStop,
        title: String,
        caption: String,
        pastRange: Bool,
        accessibility: RecommendedFuelAccessibility?
    ) -> some View {
        let card = PlaceDescriptionCard(
            name: title,
            placeDescription: PlaceDescriptionDisplay.rowText(for: stop.placeDescription, name: stop.name),
            detail: caption,
            showsPastRange: pastRange,
            systemImage: stop.category.systemImage,
            titleIdentifier: accessibility?.identifier ?? "",
            onOpen: {
                focusFromSidebar(stop)
                present(stop, title: title)
            },
            onAdd: {
                focusFromSidebar(stop)
                viewModel.addStop(from: stop)
            }
        )
        if let accessibility {
            listedStop(card.fuelRowAccessibility(accessibility), stop: stop)
        } else {
            listedStop(card, stop: stop)
        }
    }

    private func listedStop<V: View>(_ row: V, stop: SuggestedStop) -> some View {
        row
            .sidebarStopHighlight(selected: viewModel.highlightedStopID == stop.id)
            .id(listIdentity(for: stop))
    }

    /// The summary fuel row already uses the stop id. A second row with that
    /// id makes the list drop one of them when the gas group also shows it.
    private func listIdentity(for stop: SuggestedStop) -> AnyHashable {
        if stop.category == .gas, viewModel.isShownAsFuelPlanRow(stop) {
            return "gas-list-\(stop.id.uuidString)"
        }
        return stop.id
    }

    private func focusFromSidebar(_ stop: SuggestedStop) {
        guard planningUsesSidebar else { return }
        viewModel.focusListedStop(id: stop.id, coordinate: stop.coordinate)
    }

    private func present(_ stop: SuggestedStop, title: String) {
        guard let text = PlaceDescriptionDisplay.text(for: stop.placeDescription, name: stop.name) else { return }
        openDescription = OpenPlaceDescription(id: stop.id, name: title, text: text, textIdentifier: "")
    }

    @ViewBuilder
    private func fuelSuggestionButton(
        _ stop: SuggestedStop,
        title: String,
        caption: String,
        pastRange: Bool,
        accessibility: RecommendedFuelAccessibility?
    ) -> some View {
        let appliedFill = stop.category == .gas && viewModel.isAppliedGasFill(stop)
        let onRoute = appliedFill || (stop.category == .gas && viewModel.isStopOnRoute(stop))
        let button = Button {
            guard !onRoute else { return }
            focusFromSidebar(stop)
            if stop.category == .gas {
                viewModel.toggleBufferedGasStop(stop)
            } else {
                viewModel.addStop(from: stop)
            }
            } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: stop.category.systemImage)
                    .accessibilityHidden(true)
                FuelStopTextColumn(
                    title: title,
                    caption: caption,
                    rowIdentifier: accessibility?.identifier ?? viewModel.gasSuggestionIdentifier(for: stop)
                )
                if onRoute {
                    Text("Added")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else if pastRange {
                    PastYourRangeLabel()
                }
                if !onRoute {
                    Image(systemName: stop.category == .gas && viewModel.isGasBuffered(stop)
                          ? "checkmark.circle.fill"
                          : "plus.circle.fill")
                        .foregroundStyle(stop.category == .gas && viewModel.isGasBuffered(stop) ? Color.green : Color.blue)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onRoute)

        if let accessibility {
            listedStop(button.fuelRowAccessibility(accessibility), stop: stop)
        } else if stop.category == .gas {
            listedStop(
                button.accessibilityIdentifier(viewModel.gasSuggestionIdentifier(for: stop)),
                stop: stop
            )
        } else {
            listedStop(button, stop: stop)
        }
    }
}

/// Counted header with a chevron. Tapping it only changes the section's
/// open state. It does not check or uncheck a stop.
struct CollapsibleSectionHeader: View {
    var title: String
    var expanded: Bool
    var identifier: String
    var label: String
    var showsPastRange: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    // The list cell exposes this title, the same way a fuel
                    // row exposes its name. The label carries the count and
                    // whether the section is open.
                    .accessibilityIdentifier(identifier)
                    .accessibilityLabel(label)
                Spacer(minLength: 8)
                if showsPastRange {
                    PastYourRangeLabel()
                }
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            // The title is short on a wide iPad sheet. The shape makes the
            // rest of this row the button. Borderless would hand the whole
            // list row to this control, and on iPhone that steal reaches
            // the Apply button above the header.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
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

/// Spinner row. This is the only view that reads the selecting flag, so
/// the tap can paint it without rebuilding every fuel and suggestion label.
private struct FuelSelectionSpinnerSlot: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        if viewModel.isSelectingRecommendedFuel {
            FuelSelectionSpinner()
        } else {
            FocusPlaceholderRow()
        }
    }
}

/// One tap checks every recommended fuel stop, in ride order, and adds
/// them. Sits at the top of the buffered gas rows.
private struct SelectRecommendedFuelButton: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Button(viewModel.selectRecommendedButtonTitle) {
            viewModel.startRecommendedFuelSelection()
        }
        .accessibilityIdentifier(AccessibilityID.selectRecommended)
    }
}

/// Small status row while Select recommended is choosing stops. The flag
/// is set on the tap, before the scan, so `fuel.selecting.spinner` is on
/// screen within half a second and stays up while the list can still scroll.
private struct FuelSelectionSpinner: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(RoutePlannerViewModel.fuelSelectionStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(AccessibilityID.fuelSelectingSpinner)
        .accessibilityLabel(RoutePlannerViewModel.fuelSelectionStatus)
    }
}

/// Station name, then the distance and riding-time caption. The name wraps
/// on iPhone, iPad, and Mac. No `frame` or `fixedSize`: those wrappers were
/// focus containers UIKit visited with no children on iPad.
struct FuelStopTextColumn: View {
    let title: String
    let caption: String
    var titleColor: Color = .primary
    /// Stamped on the title text. A List cell on iPhone exposes that text
    /// even when it does not forward the surrounding button's identifier.
    var rowIdentifier: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .foregroundStyle(titleColor)
                .multilineTextAlignment(.leading)
                .lineLimit(8)
                .accessibilityIdentifier(rowIdentifier)
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
    /// Same shape as a search-result button, which XCUITest does return.
    /// An accessibility label or a stand-in on this button hid the row on
    /// iPhone and left only the map pin (the bare station name). The title
    /// text also carries `fuelStop.<name>.checked`, and its string is
    /// "Fuel stop N: Name". The riding-time caption stays under that title.
    func fuelRowAccessibility(_ accessibility: RecommendedFuelAccessibility) -> some View {
        accessibilityIdentifier(accessibility.identifier)
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
                Label(RoutePlannerViewModel.applyStopsLabel(count: viewModel.bufferedGasStops.count), systemImage: "checkmark.circle.fill")
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
