import SwiftUI

/// Rider preferences, persisted with `@AppStorage`. Changes take effect for
/// new rides; the per-ride fuel slider can still override the default in the
/// current session.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.defaultFuelRangeMiles)
    private var fuelRangeMiles = AppSettings.defaultFuelRangeMilesDefault

    @AppStorage(AppSettings.Keys.searchIntervalMiles)
    private var searchIntervalMiles = AppSettings.searchIntervalMilesDefault

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Default tank range", systemImage: "fuelpump.fill")
                            Spacer()
                            Text("\(Int(fuelRangeMiles.rounded())) mi")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fuelRangeMiles, in: 50...300, step: 10)
                    }
                } header: {
                    Text("Default Tank Range")
                } footer: {
                    Text("New rides start with this range. You can still adjust it per ride.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Label("Search every", systemImage: "magnifyingglass")
                            Spacer()
                            Text("\(Int(searchIntervalMiles.rounded())) mi")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $searchIntervalMiles, in: 10...60, step: 5)
                    }
                } header: {
                    Text("Suggestion Density")
                } footer: {
                    Text("How far apart stops are searched along the route. Smaller finds more but uses more lookups.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    SettingsView()
}
