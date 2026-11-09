import CoreLocation

/// Caption under a ride highlight: where it sits on the ride and what the
/// detour costs. Both numbers are measured against the planned route line,
/// so neither carries a "~".
enum HighlightDetourCopy {
    /// A sight this close to the route line is a stop on the road, not a detour.
    static let onRouteMeters: CLLocationDistance = 0.5 * AppSettings.metersPerMile

    static func detour(_ meters: CLLocationDistance, usesMetric: Bool) -> String {
        guard meters.isFinite, meters >= onRouteMeters else { return "On route" }
        return "\(measured(meters, usesMetric: usesMetric)) off route"
    }

    static func along(_ meters: CLLocationDistance, usesMetric: Bool) -> String {
        guard meters.isFinite, meters >= onRouteMeters else { return "At start" }
        return "\(measured(meters, usesMetric: usesMetric)) from start"
    }

    static func caption(
        distanceAlongRoute: CLLocationDistance,
        detourMeters: CLLocationDistance,
        usesMetric: Bool
    ) -> String {
        "\(along(distanceAlongRoute, usesMetric: usesMetric)) · \(detour(detourMeters, usesMetric: usesMetric))"
    }

    /// One decimal under 10 ("2.4 mi"), whole units from 10 up ("38 mi").
    static func measured(_ meters: CLLocationDistance, usesMetric: Bool) -> String {
        let unit: CLLocationDistance = usesMetric ? 1_000 : AppSettings.metersPerMile
        let value = max(0, meters) / unit
        let suffix = usesMetric ? "km" : "mi"
        let rounded = (value * 10).rounded() / 10
        if rounded < 10 {
            return String(format: "%.1f %@", rounded, suffix)
        }
        return "\(Int(value.rounded())) \(suffix)"
    }
}
