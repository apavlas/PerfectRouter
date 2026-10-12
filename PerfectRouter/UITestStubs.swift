import CoreLocation
import Foundation
import MapKit

/// Launch argument that swaps MapKit directions and stop search for canned
/// data. UI tests pass it; normal launches never do.
enum UITestStubLaunch {
    static let argument = "-UITestStubServices"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// UI tests share the simulator's defaults. A style change or tank edit
    /// in one test must not decide the next test's fuel plan. Called only
    /// from a stub launch.
    static func resetPersistedRidePreferences() {
        UserDefaults.standard.set(
            RouteStyle.fastest.rawValue,
            forKey: AppSettings.Keys.routeStyle
        )
        UserDefaults.standard.set(
            AppSettings.defaultFuelRangeMilesDefault,
            forKey: AppSettings.Keys.defaultFuelRangeMiles
        )
    }
}

/// Fixed ride used by simulator UI tests. The road runs due north from
/// Augusta so distance is a latitude delta, longer than the default tank,
/// with pumps at known miles.
enum UITestFixture {
    static let metersPerMile: CLLocationDistance = 1_609.344
    static let routeMiles: Double = 280
    static let origin = CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105)

    struct Place {
        var name: String
        var milesNorth: Double
        var eastMeters: CLLocationDistance
        var searchable: Bool
        var gasStation: Bool
    }

    /// In-range recommendations for a 100-mile tank on `routeMiles`.
    /// "On Route Fuel" sits on the line so a search can add it as a waypoint.
    static let recommendedFuelNames = ["Pilot Madison", "On Route Fuel", "Shell Knoxville"]

    static let places: [Place] = [
        Place(name: "Test Origin", milesNorth: 0, eastMeters: 0, searchable: true, gasStation: false),
        Place(name: "Home Fuel", milesNorth: 0, eastMeters: 0, searchable: false, gasStation: true),
        Place(name: "Quick Stop", milesNorth: 40, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Pilot Madison", milesNorth: 80, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "On Route Fuel", milesNorth: 150, eastMeters: 0, searchable: true, gasStation: true),
        Place(name: "Shell Knoxville", milesNorth: 230, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Test Destination", milesNorth: routeMiles, eastMeters: 0, searchable: true, gasStation: false),
    ]

    /// Sights the stub returns for an attraction search. Far enough from the
    /// start and end to survive highlight selection, and far enough apart to
    /// both be kept. One publishes a paragraph; the other publishes nothing.
    struct Highlight {
        var name: String
        var milesNorth: Double
        var eastMeters: CLLocationDistance
        var publishedDescription: String?
    }

    static let describedHighlightName = "Tallulah Gorge"
    static let plainHighlightName = "Bare Overlook"
    /// Canned UI-test copy only. A normal launch never builds these stops.
    /// Two long sentences land on the row; later sentences exist so the sheet
    /// can show text the row does not.
    static let publishedHighlightDescription = "UI test fixture sentence one describes the canned highlight and keeps going so the row cannot show it all. UI test fixture sentence two is also on the row and continues past two lines of subheadline. UI test fixture sentence three appears only in the full sheet. UI test fixture sentence four is stub data and not a real place description."
    static let highlightDescriptionOpening = "UI test fixture sentence one"
    static let highlightDescriptionTail = "UI test fixture sentence three appears only in the full sheet."

    static let highlights: [Highlight] = [
        Highlight(
            name: describedHighlightName,
            milesNorth: 60,
            eastMeters: 200,
            publishedDescription: publishedHighlightDescription
        ),
        Highlight(
            name: plainHighlightName,
            milesNorth: 180,
            eastMeters: 200,
            publishedDescription: nil
        ),
    ]

    /// Projects canned sights onto the stub polyline. The paragraph is fixture
    /// text for the UI test, not a MapKit field. The plain sight has none.
    static func attractionStops(
        alongPolylines polylines: [[CLLocationCoordinate2D]],
        corridorRadiusMeters: CLLocationDistance
    ) -> [SuggestedStop] {
        var stops: [SuggestedStop] = []
        for highlight in highlights {
            let coordinate = coordinate(milesNorth: highlight.milesNorth, eastMeters: highlight.eastMeters)
            let detour = RouteGeometry.distanceFromRoute(of: coordinate, alongPolylines: polylines)
            guard detour <= corridorRadiusMeters else { continue }
            let projected = RouteGeometry.distanceAlongRoute(of: coordinate, alongPolylines: polylines)
            let canned = highlight.milesNorth * metersPerMile
            let distance = projected > 50 ? projected : canned
            var stop = SuggestedStop(
                name: highlight.name,
                coordinate: coordinate,
                category: .attraction,
                distanceAlongRoute: distance,
                detourMeters: detour
            )
            if let published = highlight.publishedDescription {
                stop = stop.withPlaceDescription(published)
            }
            stops.append(stop)
        }
        return stops.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
    }

    static func coordinate(milesNorth: Double, eastMeters: CLLocationDistance) -> CLLocationCoordinate2D {
        let northMeters = milesNorth * metersPerMile
        let latitude = origin.latitude + northMeters / 111_320
        let lonScale = 111_320 * cos(origin.latitude * .pi / 180)
        let longitude = origin.longitude + (lonScale == 0 ? 0 : eastMeters / lonScale)
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    static func coordinate(for place: Place) -> CLLocationCoordinate2D {
        coordinate(milesNorth: place.milesNorth, eastMeters: place.eastMeters)
    }

    static var totalMeters: CLLocationDistance { routeMiles * metersPerMile }
}

/// Builds `MKRoute` values without calling `MKDirections`. The planner reads
/// `polyline`, `distance`, `expectedTravelTime`, and `hasHighways`.
enum StubRouteBuilder {
    static func routes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        avoidsHighways: Bool,
        alternates: Bool
    ) -> [MKRoute] {
        let straight = make(
            from: origin,
            to: destination,
            bowMeters: 0,
            hasHighways: !avoidsHighways,
            name: avoidsHighways ? "Stub Avoid Highways" : "Stub Fastest"
        )
        guard alternates else { return [straight] }
        let bowed = make(
            from: origin,
            to: destination,
            bowMeters: 1_800,
            hasHighways: false,
            name: "Stub Alternate"
        )
        return [straight, bowed]
    }

    private static func make(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        bowMeters: CLLocationDistance,
        hasHighways: Bool,
        name: String
    ) -> MKRoute {
        let coordinates = samples(from: origin, to: destination, bowMeters: bowMeters)
        let distance = pathLength(coordinates)
        let hours = distance / (55 * UITestFixture.metersPerMile)
        return StubMKRoute(
            name: name,
            coordinates: coordinates,
            distance: max(distance, 1),
            expectedTravelTime: max(hours * 3_600, 1),
            hasHighways: hasHighways
        )
    }

    private static func samples(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        bowMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        let count = 24
        var coords: [CLLocationCoordinate2D] = []
        coords.reserveCapacity(count + 1)
        for index in 0...count {
            let fraction = Double(index) / Double(count)
            var point = interpolate(start, end, fraction)
            if bowMeters != 0 {
                let envelope = sin(fraction * .pi)
                point = offset(point, meters: bowMeters * envelope, from: start, to: end)
            }
            coords.append(point)
        }
        return coords
    }

    private static func interpolate(
        _ start: CLLocationCoordinate2D,
        _ end: CLLocationCoordinate2D,
        _ fraction: Double
    ) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: start.latitude + (end.latitude - start.latitude) * fraction,
            longitude: start.longitude + (end.longitude - start.longitude) * fraction
        )
    }

    /// Shifts `point` to the right of the start→end bearing, in meters.
    private static func offset(
        _ point: CLLocationCoordinate2D,
        meters: CLLocationDistance,
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D
    ) -> CLLocationCoordinate2D {
        let bearing = atan2(end.longitude - start.longitude, end.latitude - start.latitude)
        let perpendicular = bearing + (.pi / 2)
        let latScale = 111_320.0
        let lonScale = 111_320.0 * cos(point.latitude * .pi / 180)
        return CLLocationCoordinate2D(
            latitude: point.latitude + (meters * cos(perpendicular)) / latScale,
            longitude: point.longitude + (lonScale == 0 ? 0 : (meters * sin(perpendicular)) / lonScale)
        )
    }

    private static func pathLength(_ coordinates: [CLLocationCoordinate2D]) -> CLLocationDistance {
        guard coordinates.count >= 2 else { return 0 }
        var total: CLLocationDistance = 0
        for index in 1..<coordinates.count {
            let previous = coordinates[index - 1]
            let current = coordinates[index]
            total += CLLocation(latitude: previous.latitude, longitude: previous.longitude)
                .distance(from: CLLocation(latitude: current.latitude, longitude: current.longitude))
        }
        return total
    }
}

/// `MKRoute` has no public memberwise initializer. Subclassing supplies the
/// getters the planner and the map actually read.
final class StubMKRoute: MKRoute {
    private let storedPolyline: MKPolyline
    private let storedDistance: CLLocationDistance
    private let storedTime: TimeInterval
    private let storedHighways: Bool
    private let storedName: String

    init(
        name: String,
        coordinates: [CLLocationCoordinate2D],
        distance: CLLocationDistance,
        expectedTravelTime: TimeInterval,
        hasHighways: Bool
    ) {
        var coords = coordinates
        if coords.count < 2, let only = coords.first ?? coordinates.first {
            coords = [only, only]
        }
        storedPolyline = MKPolyline(coordinates: &coords, count: coords.count)
        storedDistance = distance
        storedTime = expectedTravelTime
        storedHighways = hasHighways
        storedName = name
        super.init()
    }

    override var name: String { storedName }
    override var polyline: MKPolyline { storedPolyline }
    override var distance: CLLocationDistance { storedDistance }
    override var expectedTravelTime: TimeInterval { storedTime }
    override var hasHighways: Bool { storedHighways }
    override var hasTolls: Bool { false }
    override var transportType: MKDirectionsTransportType { .automobile }
    override var advisoryNotices: [String] { [] }
    override var steps: [MKRoute.Step] { [] }
}

/// Canned directions, corridor search, and place search for `-UITestStubServices`.
@MainActor
final class UITestStubServices: DirectionsProviding, StopSearching, PlaceSearching {
    /// Canned directions time. The replanning banner stays up while this
    /// request is in flight, because `isCalculating` is still true — the
    /// same rule as a live request. UI tests observe the banner during the
    /// delay. Nothing keeps the banner up after the routes return, and a
    /// normal launch never uses this stub.
    static let responseDelay: Duration = .seconds(3)

    func calculateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        avoidsHighways: Bool,
        avoidsTolls: Bool,
        alternates: Bool,
        departure: Date
    ) async throws -> [MKRoute] {
        // Toll preference and departure are part of the live request. The
        // canned geometry does not vary with them.
        _ = avoidsTolls
        _ = departure
        try await Task.sleep(for: Self.responseDelay)
        guard origin.isValidLocation, destination.isValidLocation else { return [] }
        return StubRouteBuilder.routes(
            from: origin,
            to: destination,
            avoidsHighways: avoidsHighways,
            alternates: alternates
        )
    }

    func findStops(
        category: StopCategory,
        alongLegs legs: [MKRoute],
        sampleDistances: [CLLocationDistance]?,
        corridorRadiusMeters: CLLocationDistance?,
        generation: Int
    ) async -> CorridorSearchResult {
        _ = sampleDistances
        _ = generation
        let radius = corridorRadiusMeters ?? RoutePlannerViewModel.fuelSearchCorridorMeters
        if category == .attraction {
            let polylines = legs.map { RouteGeometry.coordinates(of: $0.polyline) }
            let sights = UITestFixture.attractionStops(
                alongPolylines: polylines,
                corridorRadiusMeters: radius
            )
            return CorridorSearchResult(
                stops: sights,
                status: .completed,
                succeeded: max(sights.count, 1),
                failed: 0,
                throttled: 0
            )
        }
        // Food, coffee, and scenic chips are not part of the ride journey.
        // A completed empty result must not look like a throttled gas search.
        guard category == .gas else {
            return CorridorSearchResult(stops: [], status: .completed, succeeded: 1, failed: 0, throttled: 0)
        }
        let polylines = legs.map { RouteGeometry.coordinates(of: $0.polyline) }
        var stops: [SuggestedStop] = []
        for place in UITestFixture.places where place.gasStation {
            let coordinate = UITestFixture.coordinate(for: place)
            let detour = RouteGeometry.distanceFromRoute(of: coordinate, alongPolylines: polylines)
            guard detour <= radius else { continue }
            // Prefer the projection onto the stub polyline. If that geometry
            // comes back empty, keep the canned mile so the tank planner still
            // sees Pilot, On Route Fuel, and Shell.
            let projected = RouteGeometry.distanceAlongRoute(of: coordinate, alongPolylines: polylines)
            let canned = place.milesNorth * UITestFixture.metersPerMile
            let distance = projected > 50 ? projected : canned
            stops.append(SuggestedStop(
                name: place.name,
                coordinate: coordinate,
                category: .gas,
                distanceAlongRoute: distance,
                detourMeters: detour
            ))
        }
        let sorted = stops.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        return CorridorSearchResult(
            stops: sorted,
            status: .completed,
            succeeded: max(sorted.count, 1),
            failed: 0,
            throttled: 0
        )
    }

    func findFood(
        near coordinate: CLLocationCoordinate2D,
        alongPolylines legPolylines: [[CLLocationCoordinate2D]]
    ) async -> [SuggestedStop] {
        _ = coordinate
        _ = legPolylines
        return []
    }

    func searchPlaces(query: String, near region: MKCoordinateRegion) async -> [MKMapItem] {
        _ = region
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return UITestFixture.places.compactMap { place in
            guard place.searchable, place.name.localizedCaseInsensitiveContains(trimmed) else { return nil }
            let item = MKMapItem(placemark: MKPlacemark(coordinate: UITestFixture.coordinate(for: place)))
            item.name = place.name
            return item
        }
    }
}
