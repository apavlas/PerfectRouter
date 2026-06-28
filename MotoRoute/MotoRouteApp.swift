import SwiftUI

@main
struct MotoRouteApp: App {
    /// Controls whether the scenic launch animation is still on screen.
    @State private var showSplash = true

    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                // Defer the location permission prompt until the splash has
                // faded, so the system alert doesn't appear over the launch
                // animation.
                ContentView(readyForPermissions: !showSplash)

                if showSplash {
                    SplashScreenView()
                        .transition(.opacity)
                        .task {
                            // Hold the scenic ride for about a second, then
                            // fade through to the main app.
                            try? await Task.sleep(for: .seconds(1))
                            withAnimation(.easeInOut(duration: 0.4)) {
                                showSplash = false
                            }
                        }
                }
            }
        }
    }
}
