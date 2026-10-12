import Foundation

/// Accessibility identifiers for the ride planner. They are not visible and
/// exist so UI tests can find controls without depending on layout.
enum AccessibilityID {
    static let placeSearch = "placeSearch"
    static let selectRecommended = "selectRecommended"
    static let applyStops = "applyStops"
    static let replanBanner = "replanBanner"
    static let routeStylePicker = "routeStylePicker"
    static let activeRouteStyle = "activeRouteStyle"
    static let tankRangeSlider = "tankRangeSlider"
    static let leaveLaterToggle = "leaveLaterToggle"
    static let noGasStations = "noGasStations"
    static let rideHighlights = "rideHighlights"

    static func searchResult(_ name: String) -> String { "searchResult.\(name)" }
    static func waypoint(_ name: String) -> String { "waypoint.\(name)" }
    static func routeGeneration(_ generation: Int) -> String { "routeGeneration.\(generation)" }
    static func routeStyleOption(_ style: String) -> String { "routeStyleOption.\(style)" }

    /// Fuel-plan row. The suffix flips when the rider checks the stop.
    static func fuelStop(_ name: String, checked: Bool) -> String {
        "fuelStop.\(name).\(checked ? "checked" : "unchecked")"
    }

    static func rideHighlightName(_ name: String) -> String { "highlight.\(name).name" }
    /// Two-line clip under the place name.
    static func rideHighlightDescription(_ name: String) -> String { "highlight.\(name).description" }
    /// The same published text, unclipped, in the sheet.
    static func rideHighlightDescriptionFull(_ name: String) -> String { "highlight.\(name).description.full" }
}
