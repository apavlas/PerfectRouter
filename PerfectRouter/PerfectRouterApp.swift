import SwiftUI

@main
struct PerfectRouterApp: App {
    /// Controls whether the scenic launch animation is still on screen.
    /// UI tests skip it so the planner is on screen when the suite starts.
    @State private var showSplash = !UITestStubLaunch.skipsOnboarding
    /// One-time post-splash intro. Returning riders skip it.
    @AppStorage(AppSettings.Keys.hasCompletedFirstRun)
    private var hasCompletedFirstRun = false
    /// One-time safety notice, shown before first-run (and once to riders
    /// who finished first-run on an earlier build).
    @AppStorage(AppSettings.Keys.acknowledgedSafetyNoticeVersion)
    private var acknowledgedSafetyNoticeVersion = 0

    private var showsSafetyNotice: Bool {
        acknowledgedSafetyNoticeVersion < AppSettings.safetyNoticeVersion && !UITestStubLaunch.skipsOnboarding
    }

    /// Splash, safety notice, and first-run are all out of the way.
    private var introDone: Bool {
        UITestStubLaunch.skipsOnboarding || (hasCompletedFirstRun && !showsSafetyNotice)
    }

    init() {
        AppSettings.registerDefaults()
        if UITestStubLaunch.skipsOnboarding {
            AppSettings.acknowledgeSafetyNotice()
            AppSettings.completeFirstRun()
            UITestStubLaunch.installFocusPlaceSearchBridge()
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
                    readyForPermissions: !showSplash && introDone,
                    planningSheetEnabled: introDone
                )

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .task {
                            // Hold the scenic ride for about a second, then
                            // fade through to the safety notice, first-run,
                            // or the map.
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation(.easeInOut(duration: 0.4)) {
                                showSplash = false
                            }
                        }
                } else if showsSafetyNotice {
                    SafetyNoticeView()
                        .transition(.opacity)
                } else if !hasCompletedFirstRun && !UITestStubLaunch.skipsOnboarding {
                    FirstRunView()
                        .transition(.opacity)
                }
            }
        }
    }
}
