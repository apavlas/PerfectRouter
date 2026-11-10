import CoreLocation
import Foundation
import UIKit
import Darwin
import MapKit

/// Launch argument that swaps MapKit directions and stop search for canned
/// data. UI tests pass it; normal launches never do.
enum UITestStubLaunch {
    static let argument = "-UITestStubServices"
    /// Live UI tests pass this so they skip the splash and first-run
    /// screens without replacing MapKit with canned services.
    static let skipOnboardingArgument = "-UITestSkipOnboarding"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(argument)
    }

    /// Stub launches already skip onboarding. Live smoke tests use the
    /// dedicated flag so a fresh simulator reaches the planner.
    static var skipsOnboarding: Bool {
        isEnabled || ProcessInfo.processInfo.arguments.contains(skipOnboardingArgument)
    }

    /// In-process notice that placeSearch should take @FocusState.
    static let focusPlaceSearchNotification = Notification.Name("PerfectRouter.UITestFocusPlaceSearch")
    static let typePlaceSearchNotification = Notification.Name("PerfectRouter.UITestTypePlaceSearch")
    /// Cross-process name the UI test posts via `notify_post`. A synthesized
    /// tap on the 13-inch iPad floating sheet's field can be delivered to
    /// the map instead, so tests ask the field to focus this way.
    static let focusPlaceSearchNotifyName = "com.apavlas.PerfectRouter.UITestFocusPlaceSearch"
    private static var focusPlaceSearchBridgeInstalled = false

    /// Bridges the Darwin notification from the UI test runner into
    /// `focusPlaceSearchNotification`. No-op in a normal launch.
    static func installFocusPlaceSearchBridge() {
        guard skipsOnboarding, !focusPlaceSearchBridgeInstalled else { return }
        focusPlaceSearchBridgeInstalled = true
        UITestPlaceSearchListener.shared.start()
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            UnsafeRawPointer(bitPattern: 1),
            uiTestFocusPlaceSearchDarwinCallback,
            focusPlaceSearchNotifyName as CFString,
            nil,
            .deliverImmediately
        )
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

/// Must be a C function so the Darwin observer is not a short-lived Swift closure.
private func uiTestFocusPlaceSearchDarwinCallback(
    _ center: CFNotificationCenter?,
    _ observer: UnsafeMutableRawPointer?,
    _ name: CFNotificationName?,
    _ object: UnsafeRawPointer?,
    _ userInfo: CFDictionary?
) {
    DispatchQueue.main.async {
        NSLog("PerfectRouter UITest focusPlaceSearch Darwin notify received")
        NotificationCenter.default.post(
            name: UITestStubLaunch.focusPlaceSearchNotification,
            object: nil
        )
        UITestStubLaunch.makePlaceSearchFirstResponder()
    }
}

extension UITestStubLaunch {
    /// UI-test only. A 13-inch iPad floating sheet can stay out of the key
    /// window, so @FocusState alone does not give placeSearch first responder.
    @discardableResult
    static func makePlaceSearchFirstResponder() -> UIView? {
        var windowCount = 0
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                windowCount += 1
                if let field = findPlaceSearchTextInput(in: window) {
                    if !window.isKeyWindow {
                        window.makeKeyAndVisible()
                    }
                    let accepted = field.becomeFirstResponder()
                    NSLog(
                        "PerfectRouter UITest placeSearch becomeFirstResponder accepted=%d isFirst=%d keyWindow=%d frame=%@",
                        accepted ? 1 : 0,
                        field.isFirstResponder ? 1 : 0,
                        window.isKeyWindow ? 1 : 0,
                        NSCoder.string(for: field.frame)
                    )
                    return field
                }
            }
        }
        NSLog("PerfectRouter UITest placeSearch UITextField not found windows=%d", windowCount)
        return nil
    }

    /// UI-test only. Set the placeSearch query without becoming first
    /// responder. Focusing the field expands an iPad medium sheet to large.
    @discardableResult
    static func applyPlaceSearchText(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        NotificationCenter.default.post(
            name: typePlaceSearchNotification,
            object: text
        )
        NSLog("PerfectRouter UITest placeSearch apply text %@", text)
        return true
    }

    private static func findPlaceSearchTextInput(in view: UIView) -> UIView? {
        if (view is UITextField || view is UITextView),
           view.accessibilityIdentifier == AccessibilityID.placeSearch {
            return view
        }
        for sub in view.subviews {
            if let found = findPlaceSearchTextInput(in: sub) {
                return found
            }
        }
        // Identifier may sit on a SwiftUI wrapper around the field.
        if view.accessibilityIdentifier == AccessibilityID.placeSearch {
            if let field = view as? UITextField ?? deepestTextInput(in: view) {
                return field
            }
        }
        return nil
    }

    private static func deepestTextInput(in view: UIView) -> UIView? {
        if view is UITextField || view is UITextView { return view }
        for sub in view.subviews {
            if let found = deepestTextInput(in: sub) { return found }
        }
        return nil
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
        var food: Bool = false
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
        // Extra pumps in each tank window, all closer than that window's
        // recommended fill, so the 100-mile plan stays Pilot / On Route /
        // Shell. Each leg then has more than the recommended stop and two
        // alternates, which is what Show more is for.
        Place(name: "Alt 15", milesNorth: 15, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 25", milesNorth: 25, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 55", milesNorth: 55, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 100", milesNorth: 100, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 120", milesNorth: 120, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 140", milesNorth: 140, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 180", milesNorth: 180, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 200", milesNorth: 200, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Alt 210", milesNorth: 210, eastMeters: 800, searchable: false, gasStation: true),
        Place(name: "Test Destination", milesNorth: routeMiles, eastMeters: 0, searchable: true, gasStation: false),
        // Food within a short walk of recommended pumps (FP-1). Shell has
        // none so the nested row can show "No food nearby" (FP-2).
        Place(name: "Pilot Diner", milesNorth: 80, eastMeters: 1_100, searchable: false, gasStation: false, food: true),
        Place(name: "On Route Cafe", milesNorth: 150, eastMeters: 120, searchable: false, gasStation: false, food: true),
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
    /// Four sentences go in. The model keeps the first two, the row clips
    /// those to two lines, and the sheet shows the same two. Sentence three
    /// must not appear.
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

    /// Two hotels for evening 1, one hotel for evening 2, and a later
    /// evening with no lodging. UI tests assert the radio check, applying
    /// only evening 2, and the exact empty-window copy.
    /// These are fixture rows, not MapKit results. Captions are real
    /// offsets, not the 6:00 PM / 0 mi stand-in.
    static let sameEveningHotelA = "Quality Inn"
    static let sameEveningHotelB = "Holiday Inn Express"
    /// Evening 2's hotel. Applying only this one must not collapse evening 1.
    static let secondEveningHotel = "Weatherford Inn"
    static let noLodgingCopy = "No lodging found between 5 and 7 PM"

    /// On-route 6 PM points for the stub ride. The empty lodging evening is
    /// not one of these: it stays in the hotel section so the no-lodging
    /// copy can be found, and it does not add a riding day.
    static func stubPlannedEvenings() -> [HotelAlongRoute.Evening] {
        let mile = metersPerMile
        return [
            HotelAlongRoute.Evening(
                dayNumber: 1,
                dayStartDistance: 0,
                targetDistance: 90 * mile,
                departureMinutes: 8 * 60,
                ridingSeconds: 10 * 3_600
            ),
            HotelAlongRoute.Evening(
                dayNumber: 2,
                dayStartDistance: 90 * mile,
                targetDistance: 180 * mile,
                departureMinutes: HotelAlongRoute.morningDepartureMinutes,
                ridingSeconds: 10 * 3_600
            ),
        ]
    }

    static func stubHotelEvenings() -> [HotelEveningPlan] {
        let quality = SuggestedStop(
            name: sameEveningHotelA,
            coordinate: coordinate(milesNorth: 90, eastMeters: 2 * metersPerMile),
            category: .lodging,
            distanceAlongRoute: 90 * metersPerMile,
            detourMeters: 2 * metersPerMile
        )
        let holiday = SuggestedStop(
            name: sameEveningHotelB,
            coordinate: coordinate(milesNorth: 92, eastMeters: 4 * metersPerMile),
            category: .lodging,
            distanceAlongRoute: 92 * metersPerMile,
            detourMeters: 4 * metersPerMile
        )
        let captions = [
            quality.id: HotelAlongRoute.arrivalCaption(
                arrivalMinutes: 17 * 60 + 40,
                detourMeters: quality.detourMeters,
                fartherOff: false,
                usesMetric: false
            ),
            holiday.id: HotelAlongRoute.arrivalCaption(
                arrivalMinutes: 18 * 60 + 20,
                detourMeters: holiday.detourMeters,
                fartherOff: false,
                usesMetric: false
            ),
        ]
        let weatherford = SuggestedStop(
            name: secondEveningHotel,
            coordinate: coordinate(milesNorth: 180, eastMeters: 2 * metersPerMile),
            category: .lodging,
            distanceAlongRoute: 180 * metersPerMile,
            detourMeters: 2 * metersPerMile
        )
        let dayTwoCaptions = [
            weatherford.id: HotelAlongRoute.arrivalCaption(
                arrivalMinutes: 18 * 60 + 5,
                detourMeters: weatherford.detourMeters,
                fartherOff: false,
                usesMetric: false
            ),
        ]
        return [
            HotelEveningPlan(
                dayNumber: 1,
                dayStartDistance: 0,
                departureMinutes: 8 * 60,
                options: [quality, holiday],
                captions: captions,
                widened: false,
                emptyMessage: nil
            ),
            HotelEveningPlan(
                dayNumber: 2,
                dayStartDistance: 90 * metersPerMile,
                departureMinutes: HotelAlongRoute.morningDepartureMinutes,
                options: [weatherford],
                captions: dayTwoCaptions,
                widened: false,
                emptyMessage: nil
            ),
            HotelEveningPlan(
                dayNumber: 3,
                dayStartDistance: 400 * metersPerMile,
                departureMinutes: HotelAlongRoute.morningDepartureMinutes,
                options: [],
                captions: [:],
                widened: false,
                emptyMessage: HotelAlongRoute.emptyMessage(
                    targetMinutes: HotelAlongRoute.defaultTargetMinutes
                )
            ),
        ]
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
        let origin = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var candidates: [SuggestedStop] = []
        for place in UITestFixture.places where place.food {
            let foodCoordinate = UITestFixture.coordinate(for: place)
            let distance = origin.distance(
                from: CLLocation(latitude: foodCoordinate.latitude, longitude: foodCoordinate.longitude)
            )
            guard distance <= RoutePlannerViewModel.fuelFoodRadiusMeters else { continue }
            candidates.append(SuggestedStop(
                name: place.name,
                coordinate: foodCoordinate,
                category: .food,
                distanceAlongRoute: RouteGeometry.distanceAlongRoute(
                    of: foodCoordinate,
                    alongPolylines: legPolylines
                ),
                detourMeters: RouteGeometry.distanceFromRoute(
                    of: foodCoordinate,
                    alongPolylines: legPolylines
                )
            ))
        }
        return StopSuggestionService.rankFood(
            candidates,
            near: coordinate,
            radiusMeters: RoutePlannerViewModel.fuelFoodRadiusMeters,
            maxResults: 3
        )
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


/// UI-test-only IPv4 loopback server. XCTest cannot type into placeSearch
/// on a 13-inch iPad floating sheet, so the test writes the query here and
/// the app focuses the field and inserts the text. Bound only when a UI
/// test launch argument is present.
final class UITestPlaceSearchListener {
    static let shared = UITestPlaceSearchListener()
    static let port: in_port_t = 17321

    private var listenFD: Int32 = -1
    private let lock = NSLock()

    private init() {}

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard listenFD < 0 else { return }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            NSLog("PerfectRouter UITest placeSearch socket failed errno=%d", errno)
            return
        }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = Self.port.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr)
        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            NSLog("PerfectRouter UITest placeSearch bind failed errno=%d", errno)
            close(fd)
            return
        }
        if listen(fd, 4) != 0 {
            NSLog("PerfectRouter UITest placeSearch listen failed errno=%d", errno)
            close(fd)
            return
        }
        listenFD = fd
        NSLog("PerfectRouter UITest placeSearch POSIX listener on %d", Int(Self.port))
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
    }

    private func acceptLoop() {
        while true {
            lock.lock()
            let fd = listenFD
            lock.unlock()
            guard fd >= 0 else { return }
            var addr = sockaddr_in()
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            let conn = withUnsafeMutablePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    accept(fd, sockaddrPointer, &len)
                }
            }
            if conn < 0 {
                if errno == EINTR { continue }
                NSLog("PerfectRouter UITest placeSearch accept failed errno=%d", errno)
                return
            }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let capacity = buffer.count
            let n = buffer.withUnsafeMutableBytes { raw in
                read(conn, raw.baseAddress, capacity)
            }
            close(conn)
            NSLog("PerfectRouter UITest placeSearch POSIX received %d bytes", n)
            guard n > 0, let raw = String(bytes: buffer[0..<n], encoding: .utf8) else { continue }
            let text: String?
            if raw.hasPrefix("TYPE ") {
                text = raw.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                text = nil
            }
            if let text {
                DispatchQueue.main.async {
                    _ = UITestStubLaunch.applyPlaceSearchText(text)
                }
            }
        }
    }
}
