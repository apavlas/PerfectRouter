import SwiftUI

@main
struct MotoRouteApp: App {
    init() {
        AppSettings.registerDefaults()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
