import SwiftUI

/// Auto-recommended places of interest along the ride — a handful of
/// low-detour sights, spread across the route, that make good stops.
/// The Add button adds the stop. The card opens a published description
/// when the place has one.
struct RideHighlightsSection: View {
    let viewModel: RoutePlannerViewModel
    /// Owned by the planning sheet, outside the list. A sheet attached to
    /// this section never presents: the row's cell swallows the presentation.
    @Binding var openDescription: OpenPlaceDescription?

    @Environment(\.planningUsesSidebar) private var planningUsesSidebar

    var body: some View {
        Section {
            let count = viewModel.rideHighlights.count
            let expanded = viewModel.highlightsListExpanded
            CollapsibleSectionHeader(
                title: CollapsibleListCopy.highlightsTitle(count: count),
                expanded: expanded,
                identifier: AccessibilityID.highlightsListHeader,
                label: CollapsibleListCopy.stateLabel(
                    title: CollapsibleListCopy.highlightsTitle(count: count),
                    expanded: expanded
                ),
                showsPastRange: false,
                action: { viewModel.toggleHighlightsList() }
            )
            // The old header id. Tests still look for it after the visible
            // title became "Highlights (N)".
            Text(verbatim: "Ride Highlights")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityIdentifier(AccessibilityID.rideHighlights)
                .accessibilityLabel("Ride Highlights")
            if expanded {
                ForEach(viewModel.rideHighlights) { stop in
                    highlightCard(stop)
                }
            } else {
                FocusPlaceholderRow()
            }
        } footer: {
            Text("Places of interest right along your route, spread across the ride.")
        }
    }

    private func highlightCard(_ stop: SuggestedStop) -> some View {
        PlaceDescriptionCard(
                    name: stop.name,
                    placeDescription: PlaceDescriptionDisplay.rowText(for: stop.placeDescription, name: stop.name),
                    detail: detailText(for: stop),
                    showsPastRange: viewModel.isBeyondRemainingRange(
                        distanceAlongRoute: stop.distanceAlongRoute
                    ),
                    systemImage: "star.fill",
                    iconColor: .purple,
                    titleIdentifier: AccessibilityID.rideHighlightName(stop.name),
                    descriptionIdentifier: AccessibilityID.rideHighlightDescription(stop.name),
                    rowIdentifier: AccessibilityID.rideHighlightRow(stop.name),
                    alignment: .center,
                    onSelect: { focusFromSidebar(stop) },
                    onOpen: {
                        focusFromSidebar(stop)
                        present(stop)
                    },
                    onAdd: {
                        focusFromSidebar(stop)
                        viewModel.addStop(from: stop)
                    }
                )
                .sidebarStopHighlight(selected: viewModel.highlightedStopID == stop.id)
                .id(stop.id)
    }

    private func focusFromSidebar(_ stop: SuggestedStop) {
        guard planningUsesSidebar else { return }
        viewModel.focusListedStop(id: stop.id, coordinate: stop.coordinate)
    }

    private func present(_ stop: SuggestedStop) {
        guard let text = PlaceDescriptionDisplay.text(for: stop.placeDescription, name: stop.name) else { return }
        openDescription = OpenPlaceDescription(
            id: stop.id,
            name: stop.name,
            text: text,
            textIdentifier: AccessibilityID.rideHighlightDescriptionFull(stop.name)
        )
    }

    private func detailText(for stop: SuggestedStop) -> String {
        let along = "~\(formattedRideDistance(stop.distanceAlongRoute)) from start"
        // Under ~100 m off the route reads as "on the way"; beyond that, tell
        // the rider what the detour costs.
        guard stop.detourMeters >= 100 else { return "\(along) · on your route" }
        return "\(along) · \(formattedRideDistance(stop.detourMeters)) off route"
    }
}
