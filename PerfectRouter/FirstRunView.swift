import SwiftUI

/// One-time post-splash intro: tank range for fuel stops, then location
/// When-In-Use after this screen (never over the splash). Skipping still
/// marks the flow done so returning riders aren't nagged.
struct FirstRunView: View {
    @AppStorage(AppSettings.Keys.hasCompletedFirstRun)
    private var hasCompletedFirstRun = false
    @State private var tankMiles = AppSettings.defaultFuelRangeMilesDefault

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 24) {
                        Image(systemName: "figure.outdoor.cycle")
                            .font(.system(size: 56))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.tint)
                            .padding(.top, 12)

                        Text("Before your first ride")
                            .font(.title.bold())
                            .multilineTextAlignment(.center)

                        Text("PerfectRouter uses your location as the ride start, and your tank range so fuel stops land where you actually need them.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)

                        DistanceSliderRow(
                            label: "Tank range",
                            systemImage: "fuelpump.fill",
                            miles: $tankMiles,
                            milesRange: 50...300,
                            step: 10
                        )
                        .padding()
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }

                VStack(spacing: 12) {
                    Button(action: startPlanning) {
                        Text("Start planning")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Set up later", action: setUpLater)
                        .font(.subheadline)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 16)
            }
            .navigationTitle("PerfectRouter")
            .navigationBarTitleDisplayMode(.inline)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    /// Persists the chosen tank to the Settings key, marks first-run done,
    /// and dismisses so ContentView can seed the planner and ask for location.
    private func startPlanning() {
        finish(savingTankMiles: tankMiles)
    }

    /// Dismisses without nagging again. Location can prompt on first plan
    /// the same way it does after splash today; the stored tank default stays.
    private func setUpLater() {
        finish(savingTankMiles: nil)
    }

    private func finish(savingTankMiles miles: Double?) {
        AppSettings.completeFirstRun(savingTankMiles: miles)
        withAnimation(.easeInOut(duration: 0.35)) {
            hasCompletedFirstRun = true
        }
    }
}

#Preview {
    FirstRunView()
}
