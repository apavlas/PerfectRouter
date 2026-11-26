import StoreKit
import SwiftUI

/// Rider preferences, persisted with `@AppStorage`. Changes take effect for
/// new rides; the per-ride fuel slider can still override the default in the
/// current session.
struct SettingsView: View {
    @AppStorage(AppSettings.Keys.defaultFuelRangeMiles)
    private var fuelRangeMiles = AppSettings.defaultFuelRangeMilesDefault

    @AppStorage(AppSettings.Keys.searchIntervalMiles)
    private var searchIntervalMiles = AppSettings.searchIntervalMilesDefault

    @AppStorage(AppSettings.Keys.routeStyle)
    private var routeStyle = AppSettings.routeStyleDefault

    @Environment(\.dismiss) private var dismiss
    private var proStore = ProStore.shared
    @State private var showingPaywall = false
    @State private var showingManageSubscription = false
    @State private var restoreMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if proStore.isPro {
                        Label("Pro is on", systemImage: "checkmark.seal.fill")
                        if let reminder = proStore.billingReminderText {
                            Text(reminder)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Button("Cancel or Change Plan") { showingManageSubscription = true }
                            .accessibilityIdentifier("settings.manageSubscription")
                    } else {
                        Button {
                            showingPaywall = true
                        } label: {
                            Label("Get Pro", systemImage: "sparkles")
                        }
                        .accessibilityIdentifier("settings.getPro")
                        Button("Restore Purchases") {
                            Task {
                                let restored = await proStore.restore()
                                restoreMessage = restored ? "Pro is on." : "No Pro subscription was found for this Apple Account."
                            }
                        }
                    }
                } header: {
                    Text("PerfectRouter Pro")
                }

                Section {
                    Picker("Route style", selection: $routeStyle) {
                        ForEach(RouteStyle.allCases) { style in
                            Label(RouteStyle.label(style, proUnlocked: proStore.isPro), systemImage: style.systemImage)
                                .tag(style)
                        }
                    }
                } header: {
                    Text("Route Style")
                } footer: {
                    Text(routeStyle.detail)
                }

                Section {
                    DistanceSliderRow(
                        label: "Default tank range",
                        systemImage: "fuelpump.fill",
                        miles: $fuelRangeMiles,
                        milesRange: 50...300,
                        step: 10
                    )
                } header: {
                    Text("Default Tank Range")
                } footer: {
                    Text("New rides start with this range. You can still adjust it per ride.")
                }

                Section {
                    DistanceSliderRow(
                        label: "Search every",
                        systemImage: "magnifyingglass",
                        miles: $searchIntervalMiles,
                        milesRange: 10...60,
                        step: 5
                    )
                } header: {
                    Text("Suggestion Density")
                } footer: {
                    Text("How far apart stops are searched along the route. Smaller finds more but uses more lookups.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingPaywall) {
                PaywallView(feature: nil)
            }
            .manageSubscriptionsSheet(isPresented: $showingManageSubscription)
            .alert("Restore Purchases", isPresented: Binding(
                get: { restoreMessage != nil },
                set: { if !$0 { restoreMessage = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(restoreMessage ?? "")
            }
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
