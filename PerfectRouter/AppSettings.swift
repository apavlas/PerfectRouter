import Foundation
import MapKit

/// Central access point for rider preferences. Views bind to these keys with
/// `@AppStorage`; non-View types (e.g. the view model) read the typed
/// accessors. Keeping the keys and defaults in one place avoids drift.
///
/// Preferences are *stored* in miles (the original storage unit, so existing
/// riders' settings survive) but *displayed* in the rider's locale unit.
enum AppSettings {
    static let metersPerMile: CLLocationDistance = 1609.344
    static let kilometersPerMile = 1.609344

    /// Whether rider-facing distances are shown in kilometers. The UK measures
    /// road distances in miles, so only fully metric locales count.
    static let usesMetricUnits = Locale.current.measurementSystem == .metric

    /// Short unit label for rider-facing distance values ("mi" / "km").
    static var distanceUnitAbbreviation: String { usesMetricUnits ? "km" : "mi" }

    /// Converts a stored miles value to the display unit.
    static func displayDistance(fromMiles miles: Double) -> Double {
        usesMetricUnits ? miles * kilometersPerMile : miles
    }

    /// Converts a display-unit value back to stored miles.
    static func miles(fromDisplayDistance value: Double) -> Double {
        usesMetricUnits ? value / kilometersPerMile : value
    }

    enum Keys {
        static let defaultFuelRangeMiles = "settings.defaultFuelRangeMiles"
        static let searchIntervalMiles = "settings.searchIntervalMiles"
        static let routeStyle = "settings.routeStyle"
    }

    static let defaultFuelRangeMilesDefault = 100.0
    static let searchIntervalMilesDefault = 25.0
    static let routeStyleDefault = RouteStyle.fastest

    /// Registers default values so first-launch reads are sensible.
    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            Keys.defaultFuelRangeMiles: defaultFuelRangeMilesDefault,
            Keys.searchIntervalMiles: searchIntervalMilesDefault,
            Keys.routeStyle: routeStyleDefault.rawValue,
        ])
    }

    /// The rider's preferred route style, used to seed new sessions.
    static var defaultRouteStyle: RouteStyle {
        let raw = UserDefaults.standard.string(forKey: Keys.routeStyle)
        return raw.flatMap(RouteStyle.init(rawValue:)) ?? routeStyleDefault
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

/// Shared distance string used across the app, in the rider's locale unit.
func formattedRideDistance(_ meters: CLLocationDistance) -> String {
    let formatter = MKDistanceFormatter()
    formatter.unitStyle = .abbreviated
    formatter.units = AppSettings.usesMetricUnits ? .metric : .imperial
    return formatter.string(fromDistance: meters)
}
