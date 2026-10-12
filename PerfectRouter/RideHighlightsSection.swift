import SwiftUI

/// Auto-recommended places of interest along the ride — a handful of
/// low-detour sights, spread across the route, that make good stops.
/// The Add button adds the stop. The card opens a published description
/// when the place has one.
struct RideHighlightsSection: View {
    let viewModel: RoutePlannerViewModel
    @State private var openDescription: OpenPlaceDescription?

    var body: some View {
        Section {
            ForEach(viewModel.rideHighlights) { stop in
                PlaceDescriptionCard(
                    name: stop.name,
                    placeDescription: PlaceDescriptionDisplay.text(for: stop.placeDescription),
                    detail: detailText(for: stop),
                    systemImage: "star.fill",
                    iconColor: .purple,
                    titleIdentifier: AccessibilityID.rideHighlightName(stop.name),
                    descriptionIdentifier: AccessibilityID.rideHighlightDescription(stop.name),
                    alignment: .center,
                    onOpen: { present(stop) },
                    onAdd: { viewModel.addStop(from: stop) }
                )
            }
        } header: {
            Text("Ride Highlights")
                .accessibilityIdentifier(AccessibilityID.rideHighlights)
        } footer: {
            Text("Places of interest right along your route, spread across the ride.")
        }
        .sheet(item: $openDescription) { item in
            PlaceDescriptionSheet(
                name: item.name,
                text: item.text,
                textIdentifier: AccessibilityID.rideHighlightDescriptionFull(item.name)
            )
        }
    }

    private func present(_ stop: SuggestedStop) {
        guard let text = PlaceDescriptionDisplay.text(for: stop.placeDescription) else { return }
        openDescription = OpenPlaceDescription(id: stop.id, name: stop.name, text: text)
    }

    private func detailText(for stop: SuggestedStop) -> String {
        let along = "~\(formattedRideDistance(stop.distanceAlongRoute)) from start"
        // Under ~100 m off the route reads as "on the way"; beyond that, tell
        // the rider what the detour costs.
        guard stop.detourMeters >= 100 else { return "\(along) · on your route" }
        return "\(along) · \(formattedRideDistance(stop.detourMeters)) off route"
    }
}
