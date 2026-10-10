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
                ProgressView(viewModel.calculationStatus ?? "Calculating route…")
            } else if !viewModel.legs.isEmpty {
                HStack {
                    Label(formattedRideDistance(viewModel.totalDistanceMeters), systemImage: "road.lanes")
                    Spacer()
                    Label(formattedDuration(viewModel.totalExpectedTravelTime), systemImage: "clock")
                }
                BufferedGasApplyRow(viewModel: viewModel)
                FuelPlanRows(viewModel: viewModel)
                if viewModel.isSearchingGas {
                    ProgressView("Searching for gas along the route…")
                }
                if viewModel.showsGasLoadFailed {
                    GasLoadFailedButton(viewModel: viewModel)
                }
                if let rainWarning = viewModel.rainWarning {
                    Label(rainWarning, systemImage: "cloud.rain.fill")
                        .foregroundStyle(.blue)
                } else if viewModel.isCheckingWeather {
                    Label("Checking weather along your route…", systemImage: "cloud.sun.fill")
                        .foregroundStyle(.secondary)
                }
                // Active style sits immediately above Navigate so the rider
                // can see which line they're about to hand off.
                VStack(alignment: .leading, spacing: 2) {
                    Label(viewModel.routeStyle.rawValue, systemImage: viewModel.routeStyle.systemImage)
                        .font(.subheadline.weight(.semibold))
                    Text(viewModel.routeStyle.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if let note = viewModel.twistyLimitationNote {
                        Text(note)
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
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

}

/// In-range fuel stops, with the named gap written where the tank runs out
/// and the next station marked past range instead of numbered as a fuel stop.
private struct FuelPlanRows: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        let entries = viewModel.visibleFuelPlanEntries
        let numbers = fuelNumbers(entries)
        ForEach(entries) { entry in
            switch entry {
            case .recommended(let fuelStop):
                Group {
                    Button {
                        viewModel.toggleBufferedGasStop(fuelStop)
                    } label: {
                        HStack {
                            Label("Fuel stop \(numbers[entry.id] ?? 0): \(fuelStop.name) (~\(formattedRideDistance(fuelStop.distanceAlongRoute)) in)",
                                  systemImage: "fuelpump.fill")
                            Spacer()
                            bufferMark(viewModel.isGasBuffered(fuelStop))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.green)

                    ForEach(foodNearFuelStop(fuelStop.id)) { food in
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
                    }
                }
            case .gap(let gap):
                Label(gap.warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
            case .pastRange(let stop):
                Button {
                    viewModel.toggleBufferedGasStop(stop)
                } label: {
                    HStack {
                        Label("\(stop.name) (~\(formattedRideDistance(stop.distanceAlongRoute))) — past your range",
                              systemImage: "fuelpump")
                        Spacer()
                        bufferMark(viewModel.isGasBuffered(stop))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }
        }
    }

    private func bufferMark(_ buffered: Bool) -> some View {
        Image(systemName: buffered ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(buffered ? Color.green : Color.secondary)
    }

    private func fuelNumbers(_ entries: [FuelPlanEntry]) -> [String: Int] {
        var numbers: [String: Int] = [:]
        var count = 0
        for entry in entries {
            if case .recommended = entry {
                count += 1
                numbers[entry.id] = count
            }
        }
        return numbers
    }

    private func foodNearFuelStop(_ fuelStopID: UUID) -> [SuggestedStop] {
        viewModel.fuelFoodStops.first { $0.id == fuelStopID }?.nearbyFood ?? []
    }
}
