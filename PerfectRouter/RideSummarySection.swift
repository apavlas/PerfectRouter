import SwiftUI
import MapKit

/// The ride's headline numbers (distance, time), recommended fuel stops with
/// food paired to each, fuel-gap and rain warnings, and the navigation
/// hand-off buttons.
struct RideSummarySection: View {
    let viewModel: RoutePlannerViewModel
    /// Starts in-app guidance on the planned line. Empty in previews.
    var onStartNavigation: () -> Void = {}

    var body: some View {
        Section {
            if viewModel.isCalculating, viewModel.legs.isEmpty {
                ProgressView(viewModel.calculationStatus ?? RoutePlannerViewModel.routeReplanStatus(style: viewModel.routeStyle))
                    .focusable()
            } else if !viewModel.legs.isEmpty {
                // Always mounted. A bare `if` that appears only while
                // calculating is a focus container with no children on the
                // frame the replan ends.
                replanBannerRow
                if viewModel.isCalculating, viewModel.showsReplanProgress {
                    ProgressView(viewModel.replanStepDetail ?? "Still planning this route…")
                        .focusable()
                } else {
                    FocusPlaceholderRow()
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Label(formattedRideDistance(viewModel.totalDistanceMeters), systemImage: "road.lanes")
                        Spacer()
                        Label(formattedDuration(viewModel.totalExpectedTravelTime), systemImage: "clock")
                    }
                    .foregroundStyle(viewModel.isCalculating ? .secondary : .primary)
                    // Sits in the distance row, which the list always exposes.
                    // A separate one-point row was easy for the lazy list to
                    // omit, and combining this identifier onto the distance
                    // stack hid the mileage label. Not focusable() on the
                    // stack: that would group the children and hide this id.
                    Text(verbatim: "Ride summary")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                        .accessibilityIdentifier(viewModel.recommendedFuelPlanAccessibilityID)
                        .accessibilityLabel(Text(verbatim: "Ride summary"))
                        .focusable()
                }
                if !viewModel.bufferedGasStops.isEmpty {
                    BufferedGasApplyRow(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                // Mount the fuel list only once it has rows. An empty
                // FuelPlanRows is a focus container with no children, and
                // iPad aborts in UIFocusSystem when a replan clears the
                // stops before the next search publishes them.
                if !viewModel.isCalculating, !viewModel.visibleFuelPlanEntries.isEmpty {
                    FuelPlanRows(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                if viewModel.isSearchingGas {
                    ProgressView("Searching for gas along the route…")
                        .focusable()
                } else {
                    FocusPlaceholderRow()
                }
                if viewModel.showsGasLoadFailed {
                    GasLoadFailedButton(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                if let rainWarning = viewModel.rainWarning {
                    Label(rainWarning, systemImage: "cloud.rain.fill")
                        .foregroundStyle(.blue)
                        .focusable()
                } else if viewModel.isCheckingWeather {
                    Label("Checking weather along your route…", systemImage: "cloud.sun.fill")
                        .foregroundStyle(.secondary)
                        .focusable()
                } else {
                    FocusPlaceholderRow()
                }
                // Active style sits immediately above Navigate so the rider
                // can see which line they're about to hand off. The
                // representation is only the style name: a combined label
                // includes the detail and misses the banner fallback.
                VStack(alignment: .leading, spacing: 2) {
                    Label(viewModel.routeStyle.rawValue, systemImage: viewModel.routeStyle.systemImage)
                        .font(.subheadline.weight(.semibold))
                    Text(routeStyleDetail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityRepresentation {
                    Text(viewModel.routeStyle.rawValue)
                        .accessibilityIdentifier(AccessibilityID.activeRouteStyle)
                }
                // Primary action. Stays inside the app and follows the planned
                // line, including selected stops. Apple Maps is an explicit
                // alternative below — it recalculates and can leave a detour.
                Button {
                    viewModel.logCurrentRide()
                    onStartNavigation()
                } label: {
                    // motorcycle.fill is SF Symbols 6 / iOS 18+; reuse the
                    // Splash rider glyph so this stays valid on iOS 17.
                    Label("Navigate", systemImage: "figure.outdoor.cycle")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(AccessibilityID.navigate)
                .accessibilityLabel("Navigate")
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                Button {
                    launchAppleMaps()
                } label: {
                    Label("Open in Apple Maps", systemImage: "map")
                }
                .accessibilityIdentifier(AccessibilityID.openInAppleMaps)

                // Optional alternative, only when Google Maps is installed.
                // (Google Maps drives its own CarPlay support in its app.)
                if NavigationLauncher.isGoogleMapsAvailable {
                    Button {
                        launchGoogleMaps()
                    } label: {
                        Label("Open in Google Maps", systemImage: "location.north.line.fill")
                    }
                } else {
                    FocusPlaceholderRow()
                }
            } else {
                FocusPlaceholderRow()
            }
            if let here = viewModel.currentLocation,
               let shareURL = NavigationLauncher.currentLocationShareURL(here) {
                ShareLink(
                    item: shareURL,
                    subject: Text("My location"),
                    message: Text("Here's where I am right now.")
                ) {
                    Label("Share Current Location", systemImage: "dot.radiowaves.left.and.right")
                }
            } else {
                FocusPlaceholderRow()
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            } else {
                FocusPlaceholderRow()
            }
        }
    }

    /// Single text, always in the section, so the row does not appear and
    /// vanish as a replan starts. Hidden once calculating ends; the visible
    /// string is not the "Replanning for …" sentence then.
    private var replanBannerRow: some View {
        let showing = viewModel.isCalculating
        return Text(showing ? replanStatus : " ")
            .font(showing ? .subheadline.weight(.semibold) : .system(size: 1))
            .foregroundStyle(showing ? Color.primary : Color.clear)
            .accessibilityIdentifier(showing ? AccessibilityID.replanBanner : "replanBannerIdle")
            .accessibilityLabel(showing ? replanStatus : " ")
            .accessibilityHidden(!showing)
            .focusable()
    }

    private var routeStyleDetail: String {
        if let note = viewModel.twistyLimitationNote {
            return "\(viewModel.routeStyle.detail)\n\(note)"
        }
        return viewModel.routeStyle.detail
    }

    private var replanStatus: String {
        viewModel.calculationStatus
            ?? RoutePlannerViewModel.routeReplanStatus(style: viewModel.routeStyle)
    }

    private func launchAppleMaps() {
        viewModel.logCurrentRide()
        NavigationLauncher.openInAppleMaps(viewModel.waypoints)
    }

    private func launchGoogleMaps() {
        viewModel.logCurrentRide()
        NavigationLauncher.openInGoogleMaps(viewModel.waypoints)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }

}

/// One list row in the fuel plan. Flattened so a stop with no nearby food
/// does not leave an empty container beside the fuel button.
private struct FuelPlanRow: Identifiable {
    enum Kind {
        case recommended(SuggestedStop, number: Int)
        case food(SuggestedStop)
        case gap(FuelGap)
        case pastRange(SuggestedStop)
    }

    var id: String
    var kind: Kind
}

/// In-range fuel stops, with the named gap written where the tank runs out
/// and the next station marked past range instead of numbered as a fuel stop.
private struct FuelPlanRows: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        // Caller mounts this only when `planRows` is non-empty. Food is
        // flattened in so a stop with no nearby food is not an `if` whose
        // false branch is an empty focus container.
        ForEach(planRows) { row in
            rowContent(row)
        }
    }

    private var planRows: [FuelPlanRow] {
        var rows: [FuelPlanRow] = []
        var number = 0
        for entry in viewModel.visibleFuelPlanEntries {
            switch entry {
            case .recommended(let fuelStop):
                number += 1
                rows.append(FuelPlanRow(id: entry.id, kind: .recommended(fuelStop, number: number)))
                for food in foodNearFuelStop(fuelStop.id) {
                    rows.append(FuelPlanRow(id: "food-\(food.id.uuidString)", kind: .food(food)))
                }
            case .gap(let gap):
                rows.append(FuelPlanRow(id: entry.id, kind: .gap(gap)))
            case .pastRange(let stop):
                rows.append(FuelPlanRow(id: entry.id, kind: .pastRange(stop)))
            }
        }
        return rows
    }

    @ViewBuilder
    private func rowContent(_ row: FuelPlanRow) -> some View {
        switch row.kind {
        case .recommended(let fuelStop, let number):
            let stored = viewModel.fuelRowLabel(for: fuelStop)
            let title = stored?.title ?? "Fuel stop \(number): \(fuelStop.name)"
            let caption = stored?.caption ?? viewModel.fuelStopRidingCaption(for: fuelStop)
            Button {
                viewModel.toggleBufferedGasStop(fuelStop)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "fuelpump.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    FuelStopTextColumn(
                        title: title,
                        caption: caption,
                        titleColor: .green,
                        rowIdentifier: AccessibilityID.fuelStop(
                            fuelStop.name,
                            checked: viewModel.isGasBuffered(fuelStop)
                        )
                    )
                    bufferMark(viewModel.isGasBuffered(fuelStop))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .fuelRowAccessibility(
                RecommendedFuelAccessibility(
                    identifier: stored?.identifier ?? AccessibilityID.fuelStop(fuelStop.name, checked: viewModel.isGasBuffered(fuelStop)),
                    label: stored?.accessibilityLabel ?? "\(title), \(caption)",
                    title: title,
                    caption: caption
                )
            )
        case .food(let food):
            Button {
                viewModel.addStop(from: food)
            } label: {
                HStack {
                    Label(food.name, systemImage: "fork.knife")
                    Spacer()
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.blue)
                }
                .font(.subheadline)
                .padding(.leading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        case .gap(let gap):
            Label(gap.warning, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.subheadline)
        case .pastRange(let stop):
            let stored = viewModel.fuelRowLabel(for: stop)
            let title = stored?.title ?? stop.name
            let caption = stored?.caption ?? viewModel.fuelStopRidingCaption(for: stop)
            let note = stored?.pastFullTank == true
                ? RoutePlannerViewModel.pastFullTankNotice
                : viewModel.fuelListNote(for: stop)
            Button {
                viewModel.toggleBufferedGasStop(stop)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "fuelpump")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    FuelStopTextColumn(
                        title: title,
                        caption: caption,
                        titleColor: .orange
                    )
                    if note != nil {
                        PastFullTankLabel()
                    } else {
                        PastYourRangeLabel()
                    }
                    bufferMark(viewModel.isGasBuffered(stop))
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(stored?.accessibilityLabel ?? "\(title), \(caption), \(note ?? "")")
        }
    }

    private func bufferMark(_ buffered: Bool) -> some View {
        Image(systemName: buffered ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(buffered ? Color.green : Color.secondary)
    }

    private func foodNearFuelStop(_ fuelStopID: UUID) -> [SuggestedStop] {
        viewModel.fuelFoodStops.first { $0.id == fuelStopID }?.nearbyFood ?? []
    }
}
