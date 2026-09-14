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

    var id: String { rawValue }

    /// Query string passed to MKLocalSearch.
    var searchQuery: String {
        switch self {
        case .gas:        return "gas station"
        case .food:       return "restaurant"
        case .coffee:     return "coffee"
        case .scenic:     return "scenic viewpoint"
        case .attraction: return "tourist attractions"
        }
    }

    var systemImage: String {
        switch self {
        case .gas:        return "fuelpump.fill"
        case .food:       return "fork.knife"
        case .coffee:     return "cup.and.saucer.fill"
        case .scenic:     return "binoculars.fill"
        case .attraction: return "star.fill"
        }
    }
}

/// How the planner should bias route calculation. Scenic asks Apple to
/// avoid highways and tolls and pick an alternate when one is offered —
/// not twisty or back-road routing.
enum RouteStyle: String, CaseIterable, Identifiable {
    case fastest = "Fastest"
    case avoidHighways = "Avoid Highways"
    case scenic = "Scenic"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .fastest:       return "bolt.fill"
        case .avoidHighways: return "road.lanes"
        case .scenic:        return "mountain.2.fill"
        }
    }

    /// A short, rider-facing description of what the style does.
    var detail: String {
        switch self {
        case .fastest:       return "The quickest route, highways included."
        case .avoidHighways: return "Stays off highways where possible."
        case .scenic:        return "Avoids highways and tolls when Apple offers a quieter option — not true twisty routing."
        }
    }

    /// Whether the routing request should avoid highways.
    var avoidsHighways: Bool { self != .fastest }

    /// Whether the routing request should also avoid tolls (scenic rides favor
    /// quiet roads, which usually means steering clear of toll plazas too).
    var avoidsTolls: Bool { self == .scenic }

    /// Whether to fetch alternate routes and pick the most scenic one.
    var prefersAlternates: Bool { self == .scenic }
}

/// A recommended stop found near the route corridor.
struct SuggestedStop: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
    let category: StopCategory
    /// Approximate distance from the route start, in meters, measured
    /// along the route to the nearest sampled point. Used for sorting
    /// and for fuel-range warnings.
    let distanceAlongRoute: CLLocationDistance
    /// How far off the route line the stop sits, in meters — the detour a
    /// rider takes to reach it. 0 when unknown (e.g. stops from a shared
    /// route link).
    var detourMeters: CLLocationDistance = 0

    var name: String { mapItem.name ?? "Unknown" }
    var coordinate: CLLocationCoordinate2D { mapItem.placemark.coordinate }
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
}
