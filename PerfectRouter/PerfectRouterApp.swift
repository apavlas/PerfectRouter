import SwiftUI

@main
struct PerfectRouterApp: App {
    /// Controls whether the scenic launch animation is still on screen.
    /// UI tests skip it so the planner is on screen when the suite starts.
    @State private var showSplash = !UITestStubLaunch.isEnabled
    /// One-time post-splash intro. Returning riders skip it.
    @AppStorage(AppSettings.Keys.hasCompletedFirstRun)
    private var hasCompletedFirstRun = false

    init() {
        AppSettings.registerDefaults()
        if UITestStubLaunch.isEnabled {
            AppSettings.completeFirstRun()
        }
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
                    readyForPermissions: !showSplash && (hasCompletedFirstRun || UITestStubLaunch.isEnabled),
                    planningSheetEnabled: hasCompletedFirstRun || UITestStubLaunch.isEnabled
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
                } else if !hasCompletedFirstRun && !UITestStubLaunch.isEnabled {
                    FirstRunView()
                        .transition(.opacity)
                }
            }
        }
    }
}
