import SwiftUI

/// Lets the rider pick Fastest, Avoid Highways, or Scenic. Changing the
/// style re-plans the current ride immediately.
struct RouteStyleSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section {
            Picker("Route style", selection: Binding(
                get: { viewModel.routeStyle },
                set: { viewModel.setRouteStyle($0) }
            )) {
                ForEach(RouteStyle.allCases) { style in
                    Label(style.rawValue, systemImage: style.systemImage)
                        .tag(style)
                }
            }
            .pickerStyle(.menu)
        } header: {
            Text("Route Style")
        } footer: {
            Text(viewModel.routeStyle.detail)
        }
    }
}

/// Lets the rider plan for a later departure, so the rain warning reflects
/// the forecast for when they'll actually pass each part of the route —
/// riders often plan the night before.
struct DepartureSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section {
            Toggle(isOn: leaveLaterBinding) {
                Label("Leave later", systemImage: "clock")
            }
            if viewModel.departureDate != nil {
                DatePicker(
                    "Departure",
                    selection: departureDateBinding,
                    in: Date()...,
                    displayedComponents: [.date, .hourAndMinute]
                )
            }
        } header: {
            Text("Departure")
        } footer: {
            Text(viewModel.departureDate == nil
                 ? "Weather along the route is checked as if you're leaving now."
                 : "Weather along the route is checked for when you'll pass each point.")
        }
    }

    /// On/off face of the optional departure date: turning it on seeds a
    /// departure an hour from now; turning it off reverts to "leaving now".
    private var leaveLaterBinding: Binding<Bool> {
        Binding(
            get: { viewModel.departureDate != nil },
            set: { viewModel.setDeparture($0 ? Date().addingTimeInterval(3600) : nil) }
        )
    }

    private var departureDateBinding: Binding<Date> {
        Binding(
            get: { viewModel.departureDate ?? Date() },
            set: { viewModel.setDeparture($0) }
        )
    }
}

/// Lets the rider set their tank range, which drives how often gas stops
/// are recommended. Re-plans fuel stops when the rider finishes adjusting.
struct FuelRangeSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Fuel Range") {
            DistanceSliderRow(
                label: "Tank range",
                systemImage: "fuelpump.fill",
                miles: fuelRangeMilesBinding,
                milesRange: 50...300,
                step: 10,
                onEditingChanged: { editing in
                    // Re-plan only when the drag ends. No network search —
                    // just re-selects from the gas stations already loaded.
                    if !editing {
                        viewModel.replanFuelStops()
                    }
                }
            )
        }
    }

    /// Two-way binding that exposes the fuel range (stored in meters) as miles
    /// for the shared distance slider.
    private var fuelRangeMilesBinding: Binding<Double> {
        Binding(
            get: { viewModel.fuelRangeMeters / AppSettings.metersPerMile },
            set: { viewModel.fuelRangeMeters = $0 * AppSettings.metersPerMile }
        )
    }
}
