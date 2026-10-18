import Foundation

/// Accessibility identifiers for the ride planner. They are not visible and
/// exist so UI tests can find controls without depending on layout.
enum AccessibilityID {
    static let placeSearch = "placeSearch"
    static let selectRecommended = "selectRecommended"
    /// Shown only when Select recommended is still working after half a second.
    static let fuelSelectingSpinner = "fuel.selecting.spinner"
    static let applyStops = "applyStops"
    static let replanBanner = "replanBanner"
    static let routeStylePicker = "routeStylePicker"
    static let activeRouteStyle = "activeRouteStyle"
    static let tankRangeSlider = "tankRangeSlider"
    static let leaveLaterToggle = "leaveLaterToggle"
    static let noGasStations = "noGasStations"
    static let noLodging = "noLodging"
    static let hotelTarget = "hotelTarget"
    /// One line of evening-1 lodging state for UI-test attachments.
    static let hotelLodgingState = "hotelLodgingState"
    static let applyHotels = "applyHotels"

    static func noHotelPicked(_ day: Int) -> String { "noHotelPicked.\(day)" }
    static func chooseHotel(_ day: Int) -> String { "chooseHotel.\(day)" }
    static func rideDayLimit(_ day: Int) -> String { "rideDayLimit.\(day)" }
    static func rideDayOverLimit(_ day: Int) -> String { "rideDayOverLimit.\(day)" }
    static func hotelDay(_ day: Int) -> String { "hotelDay.\(day)" }
    static let navigate = "navigate"
    static let rideHighlights = "rideHighlights"
    /// Camera center after a route is framed, as "latitude,longitude".
    static let routeMapFrame = "routeMapFrame"

    static func searchResult(_ name: String) -> String { "searchResult.\(name)" }
    static func waypoint(_ name: String) -> String { "waypoint.\(name)" }
    static func routeGeneration(_ generation: Int) -> String { "routeGeneration.\(generation)" }
    static func routeStyleOption(_ style: String) -> String { "routeStyleOption.\(style)" }

    /// Fuel-plan row. The suffix flips when the rider checks the stop.
    static func fuelStop(_ name: String, checked: Bool) -> String {
        "fuelStop.\(name).\(checked ? "checked" : "unchecked")"
    }

    /// Hotel row. The suffix flips when the rider checks the stop.
    static func hotelStop(_ name: String, checked: Bool) -> String {
        "hotelStop.\(name).\(checked ? "checked" : "unchecked")"
    }

    /// The highlight row, excluding the Add button. Tapping it opens the
    /// description sheet when the place has one.
    static func rideHighlightRow(_ name: String) -> String { "highlight.\(name).row" }

    static func rideHighlightName(_ name: String) -> String { "highlight.\(name).name" }
    /// Two-line clip under the place name.
    static func rideHighlightDescription(_ name: String) -> String { "highlight.\(name).description" }
    /// The same published text, unclipped, in the sheet.
    static func rideHighlightDescriptionFull(_ name: String) -> String { "highlight.\(name).description.full" }
}
