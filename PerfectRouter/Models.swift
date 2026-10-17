import Foundation
import MapKit

extension CLLocationCoordinate2D {
    /// Whether this is a real, finite, in-range coordinate that's safe to hand
    /// to MapKit. Guards against `kCLLocationCoordinate2DInvalid` and `NaN`
    /// values — some `MKLocalSearch` results and on-map point conversions can
    /// produce these, and MapKit raises an assertion when given a non-finite
    /// region center or route endpoint.
    var isValidLocation: Bool {
        CLLocationCoordinate2DIsValid(self) && latitude.isFinite && longitude.isFinite
    }
}

/// A user-added stop on the ride (start, intermediate stop, or destination).
struct Waypoint: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var coordinate: CLLocationCoordinate2D
    /// True when the rider added this stop as a gas station (pin, list, or
    /// ride-summary row). Counts as a tank fill for `planFuelStops`.
    var isGasFill: Bool = false
    /// An overnight hotel. Ends the riding day: the next morning's riding
    /// time starts here, and the tank is treated as full.
    var isOvernight: Bool = false

    static func == (lhs: Waypoint, rhs: Waypoint) -> Bool {
        lhs.id == rhs.id
    }
}

/// Categories of stops the app can recommend along the route.
enum StopCategory: String, CaseIterable, Identifiable {
    case gas = "Gas"
    case food = "Food"
    case coffee = "Coffee"
    case scenic = "Scenic"
    case attraction = "Sights"
    /// Evening lodging. Not a map chip — hotels are suggested from the
    /// riding-time window, then checked and applied like fuel.
    case lodging = "Lodging"

    var id: String { rawValue }

    /// Categories shown as map chips. Lodging stays off that row.
    static var plannerCases: [StopCategory] {
        allCases.filter { $0 != .lodging }
    }

    /// Query string passed to MKLocalSearch.
    var searchQuery: String {
        switch self {
        case .gas:        return "gas station"
        case .food:       return "restaurant"
        case .coffee:     return "coffee"
        case .scenic:     return "scenic viewpoint"
        case .attraction: return "tourist attractions"
        case .lodging:    return "hotel"
        }
    }

    var systemImage: String {
        switch self {
        case .gas:        return "fuelpump.fill"
        case .food:       return "fork.knife"
        case .coffee:     return "cup.and.saucer.fill"
        case .scenic:     return "binoculars.fill"
        case .attraction: return "star.fill"
        case .lodging:    return "bed.double.fill"
        }
    }

    /// Scenic viewpoints, sights, and lodging. Those cards can show a
    /// description Apple Maps already published. Gas, food, and coffee stay
    /// one-tap rows without one.
    var showsPlaceDescription: Bool {
        switch self {
        case .scenic, .attraction, .lodging:
            return true
        case .gas, .food, .coffee:
            return false
        }
    }
}

/// How the planner should bias route calculation.
///
/// Scenic asks Apple to avoid highways and tolls and then picks the longest
/// alternate — a quieter option, not curve-seeking. Twisty is a separate
/// style: it keeps the driving line with more curves than Fastest when one
/// exists. The name is Twisty.
enum RouteStyle: String, CaseIterable, Identifiable {
    case fastest = "Fastest"
    case avoidHighways = "Avoid Highways"
    case scenic = "Scenic"
    case twisty = "Twisty"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .fastest:       return "bolt.fill"
        case .avoidHighways: return "road.lanes"
        case .scenic:        return "mountain.2.fill"
        case .twisty:        return "point.topleft.down.curvedto.point.bottomright.up"
        }
    }

    /// A short, rider-facing description of what the style does.
    var detail: String {
        switch self {
        case .fastest:       return "The quickest route, highways included."
        case .avoidHighways: return "Stays off highways where possible."
        case .scenic:        return "Avoids highways and tolls when Apple offers a quieter option — not true twisty routing."
        case .twisty:        return "Biases the route toward roads with more curves than the fastest option."
        }
    }

    /// Whether the routing request should avoid highways.
    /// Twisty does not: a curving highway can beat a straight county road,
    /// and highway avoidance is already Avoid Highways / Scenic.
    var avoidsHighways: Bool {
        switch self {
        case .avoidHighways, .scenic:
            return true
        case .fastest, .twisty:
            return false
        }
    }

    /// Whether the routing request should also avoid tolls (scenic rides favor
    /// quiet roads, which usually means steering clear of toll plazas too).
    var avoidsTolls: Bool { self == .scenic }

    /// Whether to fetch alternate routes and pick the longest low-highway one.
    /// Twisty scores curvature itself; it does not use this scenic pick.
    var prefersAlternates: Bool { self == .scenic }
}

/// A recommended stop found near the route corridor.
struct SuggestedStop: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
    let category: StopCategory
    /// Distance from the route start, in meters, measured by projecting
    /// the stop onto the route polyline. Used for sorting and for
    /// fuel-range warnings.
    var distanceAlongRoute: CLLocationDistance
    /// How far off the route line the stop sits, in meters — the detour a
    /// rider takes to reach it. 0 when unknown (e.g. stops from a shared
    /// route link).
    var detourMeters: CLLocationDistance = 0
    /// Prose Apple Maps or the place itself published. Nil means the card
    /// shows no description — nothing is filled in.
    var placeDescription: String? = nil
    /// Copied once from the placemark. List rows and the fuel scan read
    /// these instead of touching `MKMapItem` again.
    let latitude: Double
    let longitude: Double

    var name: String { mapItem.name ?? "Unknown" }
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    init(mapItem: MKMapItem,
         category: StopCategory,
         distanceAlongRoute: CLLocationDistance,
         detourMeters: CLLocationDistance = 0,
         placeDescription: String? = nil) {
        self.mapItem = mapItem
        self.category = category
        self.distanceAlongRoute = distanceAlongRoute
        self.detourMeters = detourMeters
        self.placeDescription = placeDescription
        let coordinate = mapItem.placemark.coordinate
        self.latitude = coordinate.latitude
        self.longitude = coordinate.longitude
    }
}

/// Local-time windows when a rider is likely to want food with a fuel stop.
/// Used to prefer (not require) a gas+food pair when the tank-interval ETA
/// falls near breakfast, lunch, or dinner.
struct MealWindow: Equatable, Sendable {
    /// Minutes from midnight, inclusive.
    let startMinutes: Int
    /// Minutes from midnight, exclusive.
    let endMinutes: Int

    static let breakfast = MealWindow(startMinutes: 7 * 60, endMinutes: 9 * 60 + 30)
    static let lunch = MealWindow(startMinutes: 11 * 60 + 30, endMinutes: 13 * 60 + 30)
    static let dinner = MealWindow(startMinutes: 17 * 60 + 30, endMinutes: 20 * 60)

    static let typical = [breakfast, lunch, dinner]
}

/// A recommended fuel stop together with food found right next to it, so a
/// rider can refuel and eat in a single stop instead of two. Derived from
/// `fuelStops` and recomputed when they change — never persisted.
struct FuelFoodStop: Identifiable {
    /// Mirrors the underlying fuel stop's id, giving stable diffing and a
    /// simple way to detect when the set of paired stops has changed.
    var id: UUID { fuelStop.id }
    let fuelStop: SuggestedStop
    /// Food near the fuel stop, sorted nearest-first. Empty when nothing is
    /// within the search radius.
    let nearbyFood: [SuggestedStop]
}

extension SuggestedStop {
    /// Rebuilds a stop from primitive values (e.g. a route shared by another
    /// rider), synthesizing a placemark-backed `MKMapItem` for the coordinate.
    init(name: String,
         coordinate: CLLocationCoordinate2D,
         category: StopCategory,
         distanceAlongRoute: CLLocationDistance,
         detourMeters: CLLocationDistance = 0) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = name
        self.init(mapItem: mapItem,
                  category: category,
                  distanceAlongRoute: distanceAlongRoute,
                  detourMeters: detourMeters)
    }

    /// Same stop, with a new distance from the start. The id stays put so
    /// the suggestion row does not jump when the mile mark is filled in.
    func withDistanceAlongRoute(_ distance: CLLocationDistance) -> SuggestedStop {
        var copy = self
        copy.distanceAlongRoute = distance
        return copy
    }
}
