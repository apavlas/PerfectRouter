import SwiftUI
import MapKit

/// The ride's headline numbers (distance, time), recommended fuel stops with
/// food paired to each, fuel-gap and rain warnings, and the navigation
/// hand-off buttons.
struct RideSummarySection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section {
            if viewModel.isCalculating {
                ProgressView("Calculating route…")
            } else if !viewModel.legs.isEmpty {
                HStack {
                    Label(formattedRideDistance(viewModel.totalDistanceMeters), systemImage: "road.lanes")
                    Spacer()
                    Label(formattedDuration(viewModel.totalExpectedTravelTime), systemImage: "clock")
                }
                ForEach(Array(viewModel.fuelStops.enumerated()), id: \.element.id) { index, fuelStop in
                    Label("Fuel stop \(index + 1): \(fuelStop.name) (~\(formattedRideDistance(fuelStop.distanceAlongRoute)) in)",
                          systemImage: "fuelpump.fill")
                        .foregroundStyle(.green)

                    // Food found right next to this fuel stop, so the rider can
                    // refuel and eat in one stop. Nested under its fuel stop.
                    ForEach(foodNearFuelStop(fuelStop.id)) { food in
                        Label(food.name, systemImage: "fork.knife")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.leading)
                    }
                }
                if viewModel.hasFuelGap {
                    Label("No gas station found within your fuel range on part of this route — consider a different path.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let rainWarning = viewModel.rainWarning {
                    Label(rainWarning, systemImage: "cloud.rain.fill")
                        .foregroundStyle(.blue)
                } else if viewModel.isCheckingWeather {
                    Label("Checking weather along your route…", systemImage: "cloud.sun.fill")
                        .foregroundStyle(.secondary)
                }
                // Primary, one-tap hand-off. Apple Maps is CarPlay-native, so
                // its turn-by-turn guidance automatically continues on the car
                // display once the rider connects to CarPlay.
                Button {
                    launchAppleMaps()
                } label: {
                    // motorcycle.fill is SF Symbols 6 / iOS 18+; reuse the
                    // Splash rider glyph so this stays valid on iOS 17.
                    Label("Navigate", systemImage: "figure.outdoor.cycle")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                // Optional alternative, only when Google Maps is installed.
                // (Google Maps drives its own CarPlay support in its app.)
                if NavigationLauncher.isGoogleMapsAvailable {
                    Button {
                        launchGoogleMaps()
                    } label: {
                        Label("Open in Google Maps", systemImage: "location.north.line.fill")
                    }
                }
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
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
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

    /// Food paired to the fuel stop with the given id, or empty while the
    /// (async) pairing is still loading.
    private func foodNearFuelStop(_ fuelStopID: UUID) -> [SuggestedStop] {
        viewModel.fuelFoodStops.first { $0.id == fuelStopID }?.nearbyFood ?? []
    }
}
