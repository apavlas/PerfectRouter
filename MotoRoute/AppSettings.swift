import Foundation
import MapKit

/// Central access point for rider preferences. Views bind to these keys with
/// `@AppStorage`; non-View types (e.g. the view model) read the typed
/// accessors. Keeping the keys and defaults in one place avoids drift.
///
/// Distances are shown in miles throughout the app for now.
enum AppSettings {
    static let metersPerMile: CLLocationDistance = 1609.344

    enum Keys {
        static let defaultFuelRangeMiles = "settings.defaultFuelRangeMiles"
        static let searchIntervalMiles = "settings.searchIntervalMiles"
    }

    static let defaultFuelRangeMilesDefault = 100.0
    static let searchIntervalMilesDefault = 25.0

    /// Registers default values so first-launch reads are sensible.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.defaultFuelRangeMiles: defaultFuelRangeMilesDefault,
            Keys.searchIntervalMiles: searchIntervalMilesDefault,
        ])
    }

    static var defaultFuelRangeMeters: CLLocationDistance {
        let miles = UserDefaults.standard.object(forKey: Keys.defaultFuelRangeMiles) as? Double
            ?? defaultFuelRangeMilesDefault
        return miles * metersPerMile
    }

    static var searchIntervalMeters: CLLocationDistance {
        let miles = UserDefaults.standard.object(forKey: Keys.searchIntervalMiles) as? Double
            ?? searchIntervalMilesDefault
        return miles * metersPerMile
    }
}

/// Shared distance string used across the app (miles).
func formattedRideDistance(_ meters: CLLocationDistance) -> String {
    let formatter = MKDistanceFormatter()
    formatter.unitStyle = .abbreviated
    formatter.units = .imperial
    return formatter.string(fromDistance: meters)
}
