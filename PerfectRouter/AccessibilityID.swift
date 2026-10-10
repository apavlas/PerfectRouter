import Foundation

/// Accessibility identifiers for the ride planner. They are not visible and
/// exist so UI tests can find controls without depending on layout.
enum AccessibilityID {
    static let placeSearch = "placeSearch"
    static let selectRecommended = "selectRecommended"
    static let applyStops = "applyStops"
    static let replanBanner = "replanBanner"
    static let routeStylePicker = "routeStylePicker"
    static let tankRangeSlider = "tankRangeSlider"
    static let leaveLaterToggle = "leaveLaterToggle"
    static let noGasStations = "noGasStations"

    static func searchResult(_ name: String) -> String { "searchResult.\(name)" }
    static func waypoint(_ name: String) -> String { "waypoint.\(name)" }
    static func routeGeneration(_ generation: Int) -> String { "routeGeneration.\(generation)" }
    static func routeStyleOption(_ style: String) -> String { "routeStyleOption.\(style)" }

    /// Fuel-plan row. The suffix flips when the rider checks the stop.
    static func fuelStop(_ name: String, checked: Bool) -> String {
        "fuelStop.\(name).\(checked ? "checked" : "unchecked")"
    }
}
