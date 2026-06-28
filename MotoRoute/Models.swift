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

    var id: String { rawValue }

    /// Query string passed to MKLocalSearch.
    var searchQuery: String {
        switch self {
        case .gas:    return "gas station"
        case .food:   return "restaurant"
        case .coffee: return "coffee"
        case .scenic: return "scenic viewpoint"
        }
    }

    var systemImage: String {
        switch self {
        case .gas:    return "fuelpump.fill"
        case .food:   return "fork.knife"
        case .coffee: return "cup.and.saucer.fill"
        case .scenic: return "binoculars.fill"
        }
    }
}

/// How the planner should bias route calculation. Riders often prefer twisty
/// back roads over the fastest stretch of interstate, so MotoRoute can avoid
/// highways and, for scenic rides, tolls — favoring quieter, more scenic roads.
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
        case .scenic:        return "Favors quiet back roads, avoiding highways and tolls."
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

    var name: String { mapItem.name ?? "Unknown" }
    var coordinate: CLLocationCoordinate2D { mapItem.placemark.coordinate }
}

extension SuggestedStop {
    /// Rebuilds a stop from primitive values (e.g. a route shared by another
    /// rider), synthesizing a placemark-backed `MKMapItem` for the coordinate.
    init(name: String,
         coordinate: CLLocationCoordinate2D,
         category: StopCategory,
         distanceAlongRoute: CLLocationDistance) {
        let mapItem = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        mapItem.name = name
        self.init(mapItem: mapItem, category: category, distanceAlongRoute: distanceAlongRoute)
    }
}
