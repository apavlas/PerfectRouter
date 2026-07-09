import SwiftUI

/// Auto-recommended places of interest along the ride — a handful of
/// low-detour sights, spread across the route, that make good stops.
/// Tap one to add it to the ride.
struct RideHighlightsSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section {
            ForEach(viewModel.rideHighlights) { stop in
                Button {
                    viewModel.addStop(from: stop)
                } label: {
                    HStack {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.purple)
                        VStack(alignment: .leading) {
                            Text(stop.name)
                            Text(detailText(for: stop))
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
        } header: {
            Text("Ride Highlights")
        } footer: {
            Text("Places of interest right along your route, spread across the ride.")
        }
    }

    private func detailText(for stop: SuggestedStop) -> String {
        let along = "~\(formattedRideDistance(stop.distanceAlongRoute)) from start"
        // Under ~100 m off the route reads as "on the way"; beyond that, tell
        // the rider what the detour costs.
        guard stop.detourMeters >= 100 else { return "\(along) · on your route" }
        return "\(along) · \(formattedRideDistance(stop.detourMeters)) off route"
    }
}
