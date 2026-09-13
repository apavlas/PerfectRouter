import SwiftUI

@main
struct PerfectRouterApp: App {
    /// Controls whether the scenic launch animation is still on screen.
    @State private var showSplash = true
    /// One-time post-splash intro. Returning riders skip it.
    @AppStorage(AppSettings.Keys.hasCompletedFirstRun)
    private var hasCompletedFirstRun = false

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Defer the location permission prompt until the splash (and
                // first-run, when shown) have cleared, so the system alert
                // doesn't appear over those screens. ContentView stays mounted
                // underneath so a shared-route deep link can import while the
                // intro is up and land after dismiss.
                ContentView(
                    readyForPermissions: !showSplash && hasCompletedFirstRun,
                    planningSheetEnabled: hasCompletedFirstRun
                )

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .task {
                            // Hold the scenic ride for about a second, then
                            // fade through to first-run or the map.
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation(.easeInOut(duration: 0.4)) {
                                showSplash = false
                            }
                        }
                } else if !hasCompletedFirstRun {
                    FirstRunView()
                        .transition(.opacity)
                }
            }
        }
    }
}
