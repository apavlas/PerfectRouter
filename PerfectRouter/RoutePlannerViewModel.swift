import Contacts
import Foundation
import MapKit
import Observation
import os
import SwiftUI

/// Console log for gas planning. Same subsystem and category as the
/// corridor search so one Xcode filter shows the whole path.
private let gasLog = Logger(subsystem: "com.apavlas.PerfectRouter", category: "gas")

/// One scored option inside a Twisty leg: either a single `MKRoute` alternate
/// or several routes stitched through an offset corridor.
private struct TwistyPoolEntry {
    var id: Int
    var routes: [MKRoute]
    var coordinates: [CLLocationCoordinate2D]
    var distance: CLLocationDistance
}

private struct CachedLeg {
    var routes: [MKRoute]
    var usedFastestFallback: Bool
}

/// One station or waypoint to measure along the route. File-level so the
/// background measurement is not isolated to the main actor.
private struct AlongRouteQuery: Sendable {
    var id: UUID
    var latitude: Double
    var longitude: Double
    /// Mile mark already stored on the stop. Kept when the projection collapses.
    var known: CLLocationDistance
}

/// One leg's vertices and drive time, copied on the main actor so the
/// length scan can run off it. `MKRoute` itself is not sendable.
private struct DriveLegSnapshot: Sendable {
    var polyline: [CLLocationCoordinate2D]
    var expectedTravelTime: TimeInterval
}

private enum FuelPlanRowKind: Sendable {
    case recommended
    case pastRange
    case gap
}

/// One fuel-list row reduced to sendable fields. The visible-plan pass
/// runs off the main actor and never touches `MKMapItem`.
private struct FuelPlanRow: Sendable {
    var entryID: String
    var stopID: UUID
    var key: String
    var distance: CLLocationDistance
    var kind: FuelPlanRowKind
}

private struct FuelPlanInputs: Sendable {
    var rows: [FuelPlanRow]
    var onRouteKeys: Set<String>
    var onRouteGasDistances: [CLLocationDistance]
    var showsGap: Bool
    var tank: CLLocationDistance
}

private struct FuelPlanSnapshot: Sendable {
    var visibleEntryIDs: [String]
    var fuelPlanKeys: Set<String>
    var onRouteKeys: Set<String>
    var onRouteGasDistances: [CLLocationDistance]
}

private struct TankCandidate: Sendable {
    var id: UUID
    var distance: CLLocationDistance
}

/// A gas station reduced to the fields the fuel planner reads. `SuggestedStop`
/// holds an `MKMapItem`, so the background selection never sees one.
/// Fileprivate so the fileprivate planner methods can name it.
fileprivate struct FuelCandidate: Sendable {
    var id: UUID
    var distanceAlongRoute: CLLocationDistance
    var detourMeters: CLLocationDistance
}

fileprivate enum FuelPlanDraftEntry: Sendable {
    case recommended(UUID)
    case pastRange(UUID)
    case gap(fromMeters: CLLocationDistance, toMeters: CLLocationDistance, rangeMeters: CLLocationDistance)
}

/// Fuel plan as ids. The main actor maps these back onto the real stops.
/// Fileprivate so the fileprivate planner methods can name it.
fileprivate struct FuelPlanDraft: Sendable {
    var recommendedIDs: [UUID]
    var entries: [FuelPlanDraftEntry]
    var hasGap: Bool
}

/// One station or buffered stop, already copied off `MKMapItem`.
private struct FuelSelectionStation: Sendable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var distance: CLLocationDistance
    var detour: CLLocationDistance
    var key: String
    var isGas: Bool
}

private struct FuelSelectionWaypoint: Sendable {
    var id: UUID
    var name: String
    var latitude: Double
    var longitude: Double
    var isGasFill: Bool
    var key: String
}

/// Everything Select recommended needs, captured after the spinner yields.
private struct FuelSelectionInput: Sendable {
    var stations: [FuelSelectionStation]
    var existingFuelStops: [FuelSelectionStation]
    var existingRows: [FuelPlanRow]
    var buffered: [FuelSelectionStation]
    var pastRangeIDs: Set<UUID>
    var pastRangeKeys: Set<String>
    var waypoints: [FuelSelectionWaypoint]
    var queries: [AlongRouteQuery]
    var polylines: [[CLLocationCoordinate2D]]
    var tank: CLLocationDistance
    var totalDistance: CLLocationDistance
    var totalTravelTime: TimeInterval
    var departure: Date?
    var foodIDs: Set<UUID>
    var unsearched: [CLLocationDistance]
    var drivesOnRight: Bool
    var replan: Bool
    var hasLegs: Bool
    var countsGasFills: Bool
    var showsGap: Bool
    var driveLegs: [FuelStopRidingTime.Leg]
    var usesMetric: Bool
}

private enum FuelPlacement: Sendable {
    case keep(UUID)
    case insert(UUID)
}

/// The route list, the fuel rows, and the cached distances, ready to assign.
private struct FuelSelectionOutput: Sendable {
    var didReplan: Bool
    var hasInserts: Bool
    /// Legs are about to be replaced, so the published fuel rows are cleared.
    var clearFuel: Bool
    var poolIDs: [UUID]
    var recommendedIDs: [UUID]
    var draft: FuelPlanDraft
    var placements: [FuelPlacement]
    var keptBufferedIDs: [UUID]
    var distances: [UUID: CLLocationDistance]
    var onRouteKeys: Set<String>
    var fuelPlanKeys: Set<String>
    var onRouteGasDistances: [CLLocationDistance]
    var visibleEntryIDs: [String]
    var planHasGap: Bool
    /// Titles and mile marks for the rows this result shows. Empty when the
    /// published fuel list is cleared with the insert.
    var labels: FuelRowLabelSet
}

/// What a fuel-range commit restarts. File-level so a nonisolated helper can
/// return it; a type nested in the main-actor view model would be isolated too.
enum PlanRestart: Equatable {
    case route
    case gas
}

/// What a settled departure change does. File-level so a nonisolated helper
/// can return it. `.local` re-picks stops and weather without a new search.
enum DepartureRestart: Equatable {
    case route
    case gas
    case local

    var logName: String {
        switch self {
        case .route: return "route"
        case .gas: return "gas"
        case .local: return "local"
        }
    }
}

/// What the sheet is allowed to say about gas. `empty` is the only state
/// that may read "no gas stations". `failed` is a load error with a retry.
enum GasLoadState: Equatable {
    case pending
    case loaded
    case empty
    case failed

    var logName: String {
        switch self {
        case .pending: return "pending"
        case .loaded: return "loaded"
        case .empty: return "empty"
        case .failed: return "failed"
        }
    }
}

/// A dry stretch the planner can name: the last gas still inside the tank,
/// and the next station (or the destination) past it.
struct FuelGap: Equatable {
    var fromMeters: CLLocationDistance
    var toMeters: CLLocationDistance
    var rangeMeters: CLLocationDistance

    var warning: String {
        Self.warning(fromMeters: fromMeters, toMeters: toMeters, rangeMeters: rangeMeters)
    }

    /// "No gas between mile 2,328 and 2,602 (274 mi, beyond your 170 mi range)".
    /// Digits are grouped so the sentence matches the rider-facing copy.
    static func warning(
        fromMeters: CLLocationDistance,
        toMeters: CLLocationDistance,
        rangeMeters: CLLocationDistance,
        usesMetric: Bool = AppSettings.usesMetricUnits
    ) -> String {
        let unitMeters: CLLocationDistance = usesMetric ? 1_000 : AppSettings.metersPerMile
        let unitName = usesMetric ? "kilometer" : "mile"
        let unitAbbrev = usesMetric ? "km" : "mi"
        let from = Int((fromMeters / unitMeters).rounded())
        let to = Int((toMeters / unitMeters).rounded())
        let span = abs(to - from)
        let range = max(Int((rangeMeters / unitMeters).rounded()), 0)
        return "No gas between \(unitName) \(grouped(from)) and \(grouped(to)) (\(grouped(span)) \(unitAbbrev), beyond your \(grouped(range)) \(unitAbbrev) range)"
    }

    private static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = Locale(identifier: "en_US")
        formatter.usesGroupingSeparator = true
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/// Accessibility values XCUITest reads on a recommended fuel row.
struct RecommendedFuelAccessibility: Equatable {
    var identifier: String
    /// "Fuel stop N: Name, caption". Contains both "Fuel stop" and the name.
    var label: String
    /// "Fuel stop N: Name", shown on the row and inside `label`.
    var title: String
    /// Riding caption shown under the title. Paired with `title` so a row
    /// never mixes a fuel-stop number with the generic miles line.
    var caption: String
}

/// Title and caption for one fuel row, published together.
struct FuelRowLabel: Equatable, Sendable {
    var title: String
    var caption: String
    var accessibilityLabel: String
    var identifier: String
    var pastFullTank: Bool
}

/// Lookup by stop id and by coordinate key. One value is replaced at a time
/// so every row sees the same titles and mile marks.
struct FuelRowLabelSet: Equatable, Sendable {
    var byID: [UUID: FuelRowLabel] = [:]
    var byKey: [String: FuelRowLabel] = [:]

    func label(id: UUID, key: String) -> FuelRowLabel? {
        byID[id] ?? byKey[key]
    }
}

/// Visible fuel rows and the labels those rows draw. One value, so a list
/// update cannot show a fuel-stop number with another row's mile caption.
struct FuelListPresentation {
    var visibleEntries: [FuelPlanEntry] = []
    var labels: FuelRowLabelSet = FuelRowLabelSet()
}

/// One row of the fuel list: an in-range recommendation, the named gap that
/// follows it, or the next station marked past the tank.
enum FuelPlanEntry: Identifiable {
    case recommended(SuggestedStop)
    case gap(FuelGap)
    case pastRange(SuggestedStop)

    var id: String {
        switch self {
        case .recommended(let stop):
            return "rec-\(stop.id.uuidString)"
        case .gap(let gap):
            return "gap-\(Int(gap.fromMeters.rounded()))-\(Int(gap.toMeters.rounded()))"
        case .pastRange(let stop):
            return "past-\(stop.id.uuidString)"
        }
    }
}

/// In-range fuel stops, plus the inline gap and past-range rows around them.
struct FuelPlan {
    var stops: [SuggestedStop]
    var entries: [FuelPlanEntry]
    var hasGap: Bool
}

@MainActor
@Observable
final class RoutePlannerViewModel: NSObject, CLLocationManagerDelegate {

    // MARK: - Published state

    /// Ordered ride: first = start, last = destination, middle = stops.
    var waypoints: [Waypoint] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Planning list scrolls to this stop after the rider adds one.
    /// Nil until a stop is inserted.
    var scrollToWaypointID: UUID?

    /// Intermediate stops only. Start and destination are not stops
    /// (Apple/Google Maps). A ride of start + 5 mids + end is 5 stops.
    var intermediateStopCount: Int {
        max(0, waypoints.count - 2)
    }

    /// Route-list title. Uses "stops" for the intermediate count only.
    var routeStopsTitle: String {
        switch intermediateStopCount {
        case 0: return "Route"
        case 1: return "Route (1 stop)"
        default: return "Route (\(intermediateStopCount) stops)"
        }
    }

    /// The rider's most recent known coordinate, used to auto-seed the ride
    /// start. `nil` until a location fix arrives (or if permission is denied).
    private(set) var currentLocation: CLLocationCoordinate2D?

    /// One MKRoute per leg (waypoint i -> waypoint i+1).
    var legs: [MKRoute] = [] {
        didSet {
            routeGeometryGeneration &+= 1
            rebuildDriveLegCache()
            rebuildDistanceCache()
        }
    }

    /// Polyline length and drive time for the current legs. Rebuilt when
    /// `legs` changes. Row captions read this instead of walking the polyline.
    private var cachedDriveLegs: [FuelStopRidingTime.Leg] = []

    /// Recommended stops for the currently selected category.
    var suggestedStops: [SuggestedStop] = [] {
        didSet { rebuildDistanceCache() }
    }

    var selectedCategory: StopCategory = .gas
    var isCalculating = false {
        didSet { publishFuelPlanSnapshot() }
    }
    /// Rider-facing line under the route spinner so a long Twisty plan
    /// doesn't look frozen.
    var calculationStatus: String?
    /// True while the tank-interval gas search is in flight.
    var isSearchingGas = false {
        didSet { publishFuelPlanSnapshot() }
    }
    var isLoadingSuggestions = false
    var errorMessage: String?

    /// Gas stops the rider has checked but not applied. The recommendation
    /// list stays put until `applyBufferedGasStops()`.
    private(set) var bufferedGasStops: [SuggestedStop] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Rider's fuel range in meters (default ~100 miles).
    var fuelRangeMeters: CLLocationDistance = 160_900 {
        didSet { publishFuelPlanSnapshot() }
    }

    /// How routes are biased — fastest, avoiding highways, scenic, or twisty.
    var routeStyle: RouteStyle = .fastest

    /// Set when Twisty could not beat Fastest on a leg. Nil for other styles,
    /// and nil when every leg found a curvier corridor. Surfaced in the
    /// summary so a Fastest-shaped line is never silently labeled Twisty.
    private(set) var twistyLimitationNote: String?

    /// Routed legs keyed by endpoints + style, so adding a stop does not
    /// re-probe pairs that did not change.
    private var legCache: [TwistyLegCacheKey: CachedLeg] = [:]

    /// Polyline of the last successful plan. Fuel stops that sit on it are
    /// stitched with one directions request instead of a via cascade.
    /// Suggestion distances project onto this copy, which was read on the
    /// main actor. A later `MKPolyline` read can come back empty and would
    /// otherwise label every stop "~0 ft from start".
    var plannedCorridor: [[CLLocationCoordinate2D]] = [] {
        didSet {
            routeGeometryGeneration &+= 1
            rebuildDistanceCache()
        }
    }

    /// Route geometry for "miles from start". Prefer the corridor captured
    /// when the route was published. Read the live legs only when that
    /// cache has no segment.
    private var suggestionRoutePolylines: [[CLLocationCoordinate2D]] {
        if plannedCorridor.contains(where: { $0.count > 1 }) {
            return plannedCorridor
        }
        return legs.map { RouteGeometry.coordinates(of: $0.polyline) }
    }

    private var suggestionService = StopSuggestionService()

    /// Live MapKit directions, or the canned provider for `-UITestStubServices`.
    private let directionsProvider: any DirectionsProviding

    /// Set only for UI tests. Replaces corridor `MKLocalSearch`.
    private let stopSearchOverride: (any StopSearching)?

    /// Set only for UI tests. Replaces the place-search field's `MKLocalSearch`.
    private let placeSearchOverride: (any PlaceSearching)?

    /// Rides the rider has saved on this device, most recent first.
    private(set) var savedRoutes: [SavedRoute] = []
    private let savedRouteStore = SavedRouteStore()

    /// Named groups of riders this device shares rides with.
    private(set) var riderGroups: [RiderGroup] = []
    private let riderGroupStore = RiderGroupStore()

    /// History of rides the rider has sent to navigation.
    private let rideLogStore = RideLogStore()

    /// Owned by the view model (NOT the view) so it isn't recreated and
    /// deallocated every time SwiftUI rebuilds the view hierarchy.
    private let locationManager = CLLocationManager()

    /// The in-flight route recalculation. Each new plan cancels the previous
    /// one; otherwise two overlapping recalculations (e.g. two stops added
    /// quickly) can interleave, and the slower one — computed from an older
    /// waypoint list — can finish last and overwrite the newer results.
    private var routeTask: Task<Void, Never>?

    /// Gas search started on its own (fuel-range commit after the line is
    /// already drawn). Cancelled together with `routeTask` so a mid-plan
    /// tweak cannot leave two searches writing the station list.
    private var gasTask: Task<Void, Never>?

    /// Category-chip search. Cancelled when the rider switches chips so a
    /// slow empty result cannot land after the next search.
    private var suggestionTask: Task<Void, Never>?
    private var suggestionGeneration = 0

    /// Bumped whenever a route plan is replaced. A superseded calculation
    /// must not clear `isCalculating` or publish legs. Readable so a test
    /// can prove Apply schedules one replan.
    private(set) var calculatingGeneration = 0

    /// Bumped whenever a gas search is replaced. A superseded search must
    /// not publish an empty station list or drop `isSearchingGas`.
    private var gasGeneration = 0

    /// Distinct from "searching". Only `.empty` may say there are no stations.
    /// A cancel leaves this alone (the replacement search owns the screen).
    private(set) var gasLoadState: GasLoadState = .pending {
        didSet { publishFuelPlanSnapshot() }
    }

    /// Shown when MapKit throttles or every sample errors. Not an empty corridor.
    nonisolated static let gasLoadFailedCopy = "Couldn't load gas — tap to retry"

    /// Cancels any in-flight route or gas work and starts one fresh route plan.
    private func scheduleRecalculation(refreshingSuggestions: Bool = true) {
        calculatingGeneration += 1
        gasGeneration += 1
        let calcGen = calculatingGeneration
        let gasGen = gasGeneration
        gasTask?.cancel()
        routeTask?.cancel()
        suggestionTask?.cancel()
        isCalculating = true
        // The cancelled search's defer will not clear this flag (its
        // generation no longer matches), so clear it here. Geometry is
        // running; the empty-state copy keys off `isCalculating`.
        isSearchingGas = false
        gasLoadState = .pending
        invalidateFuelCoverage()
        weatherTask?.cancel()
        showsReplanProgress = false
        replanStepDetail = nil
        replanProgressTask?.cancel()
        let replanningExistingLine = !legs.isEmpty
        calculationStatus = Self.routeReplanStatus(style: routeStyle)
        // The old pumps belong to the line being replaced. Clear them now
        // so the list cannot keep showing the previous style's stops.
        if replanningExistingLine {
            twistyLimitationNote = nil
            fuelFoodStops = []
            pairedFuelStopIDs = []
            mutateFuelList {
                fuelStops = []
                fuelPlanEntries = []
                hasFuelGap = false
            }
            let generation = calculatingGeneration
            replanProgressTask = Task { await self.noteReplanIfStillRunning(generation: generation) }
        }
        routeTask = Task {
            await recalculateRoute(
                refreshingSuggestions: refreshingSuggestions,
                calcGen: calcGen,
                gasGen: gasGen
            )
        }
    }

    /// Cancels in-flight gas (and a route task still in its gas tail) and
    /// starts one search on the line already drawn.
    ///
    /// The previous task is cancelled before the replacement is stored, so
    /// the owner that is allowed to publish is never a task we just cancelled.
    private func scheduleGasSearch() {
        gasGeneration += 1
        let gasGen = gasGeneration
        routeTask?.cancel()
        gasTask?.cancel()
        suggestionTask?.cancel()
        isSearchingGas = true
        gasLoadState = .pending
        invalidateFuelCoverage()
        gasLog.info("gas owner gen=\(gasGen, privacy: .public) start")
        gasTask = Task { await refreshGasStations(generation: gasGen) }
    }

    /// Reruns gas for the line already on screen. Does not redraw the route.
    func retryGasSearch() {
        guard !legs.isEmpty, !isCalculating else { return }
        scheduleGasSearch()
    }

    /// Fuel-range drag ended. One cancel, one restart: the route if it is
    /// still being drawn, otherwise a single gas search at the new range.
    func commitFuelRange() {
        guard waypoints.count >= 2 else { return }
        switch Self.planRestartForFuelRangeChange(isCalculating: isCalculating) {
        case .route:
            scheduleRecalculation()
        case .gas:
            scheduleGasSearch()
        }
    }

    /// While the line is still calculating, a tank change restarts that plan
    /// once so its gas tail uses the new range. After the line exists, only
    /// the gas search restarts.
    nonisolated static func planRestartForFuelRangeChange(isCalculating: Bool) -> PlanRestart {
        isCalculating ? .route : .gas
    }

    /// "No gas stations" only after a search that actually returned and found
    /// zero. Calculating, searching, cancelled, and failed stay off this copy.
    var showsNoGasStationsMessage: Bool {
        Self.shouldShowNoGasStations(
            loadState: gasLoadState,
            isCalculating: isCalculating,
            isSearchingGas: isSearchingGas,
            gasStationCount: gasStations.count,
            fuelStopCount: fuelStops.count
        )
    }

    var showsGasLoadFailed: Bool {
        Self.shouldShowGasLoadFailed(
            loadState: gasLoadState,
            isCalculating: isCalculating,
            isSearchingGas: isSearchingGas
        )
    }

    nonisolated static func shouldShowNoGasStations(
        loadState: GasLoadState,
        isCalculating: Bool,
        isSearchingGas: Bool,
        gasStationCount: Int,
        fuelStopCount: Int
    ) -> Bool {
        loadState == .empty
            && !isCalculating
            && !isSearchingGas
            && gasStationCount == 0
            && fuelStopCount == 0
    }

    nonisolated static func shouldShowGasLoadFailed(
        loadState: GasLoadState,
        isCalculating: Bool,
        isSearchingGas: Bool
    ) -> Bool {
        loadState == .failed && !isCalculating && !isSearchingGas
    }

    /// Still the generation that is allowed to write. Captured by the caller
    /// before its first await, and checked again immediately before a write.
    func gasSearchStillOwns(_ generation: Int) -> Bool {
        generation == gasGeneration && !Task.isCancelled
    }

    override init() {
        let stubs = UITestStubLaunch.isEnabled ? UITestStubServices() : nil
        if let stubs {
            directionsProvider = stubs
            stopSearchOverride = stubs
            placeSearchOverride = stubs
        } else {
            directionsProvider = MapKitDirectionsProvider()
            stopSearchOverride = nil
            placeSearchOverride = nil
        }
        if UITestStubLaunch.isEnabled {
            // Before the reads below. Otherwise a previous test's Scenic
            // style or tank value is the plan this launch recommends.
            UITestStubLaunch.resetPersistedRidePreferences()
        }
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        savedRoutes = savedRouteStore.load()
        riderGroups = riderGroupStore.load()
        // Seed session defaults from the rider's saved preferences.
        fuelRangeMeters = AppSettings.defaultFuelRangeMeters
        routeStyle = AppSettings.defaultRouteStyle
        suggestionService.sampleIntervalMeters = AppSettings.searchIntervalMeters
        // If already authorized from a previous launch, begin tracking now.
        // UI tests keep location nil so the two fixed search points are the
        // ride ends, and so the system permission alert never covers the sheet.
        if !UITestStubLaunch.isEnabled {
            startTrackingIfAuthorized()
        }

#if targetEnvironment(simulator)
        // The simulator has no GPS fix unless one is set in Features ▸ Location,
        // leaving the rider unable to auto-route from "here". Seed a sensible
        // default so route planning works out of the box on the simulator. A
        // real (simulated) location update overrides this as soon as it arrives.
        if currentLocation == nil, !UITestStubLaunch.isEnabled {
            currentLocation = Self.simulatorDefaultLocation
        }
#endif
    }

#if targetEnvironment(simulator)
    /// Fallback "current location" used only on the simulator (Augusta, GA),
    /// matching the map's default region, so auto-routing works without a GPS
    /// fix. Never compiled into device or release builds.
    private static let simulatorDefaultLocation = CLLocationCoordinate2D(
        latitude: 33.4735,
        longitude: -82.0105
    )
#endif

    /// Re-reads preferences that can change mid-session (e.g. after the rider
    /// edits Settings). The per-ride fuel slider is left as-is so an in-progress
    /// adjustment isn't overwritten, unless `seedFuelRange` is set (first-run /
    /// post-splash) so the planner picks up `settings.defaultFuelRangeMiles`.
    func applySettings(seedFuelRange: Bool = false) {
        suggestionService.sampleIntervalMeters = AppSettings.searchIntervalMeters
        if seedFuelRange {
            fuelRangeMeters = AppSettings.defaultFuelRangeMeters
        }
        // Pick up a route style changed in Settings and re-plan if it differs.
        let newStyle = AppSettings.defaultRouteStyle
        if newStyle != routeStyle {
            routeStyle = newStyle
            scheduleRecalculation()
        } else if seedFuelRange, !waypoints.isEmpty {
            // Tank miles changed the search grid — one gas search at the new
            // intervals, cancelling anything already in flight.
            commitFuelRange()
        }
    }

    func requestLocationPermission() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        } else {
            startTrackingIfAuthorized()
        }
    }

    private func startTrackingIfAuthorized() {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.startUpdatingLocation()
        default:
            break
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in startTrackingIfAuthorized() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        // One good fix is all the planner needs (it seeds the ride start and
        // the location-share link). Stop continuous updates to save battery;
        // `refreshLocation()` requests a fresh fix when the app returns to
        // the foreground.
        manager.stopUpdatingLocation()
        Task { @MainActor in currentLocation = coordinate }
    }

    /// Requests a fresh location fix (e.g. when the app returns to the
    /// foreground). Updates stop again once the fix arrives, so this stays
    /// cheap on battery.
    func refreshLocation() {
        startTrackingIfAuthorized()
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Non-fatal: we simply fall back to letting the rider add a start
        // point manually until a fix arrives.
    }

    // MARK: - Derived values

    var totalDistanceMeters: CLLocationDistance {
        Self.rideSummaryTotals(
            distances: legs.map(\.distance),
            times: legs.map(\.expectedTravelTime)
        ).distance
    }

    var totalExpectedTravelTime: TimeInterval {
        Self.rideSummaryTotals(
            distances: legs.map(\.distance),
            times: legs.map(\.expectedTravelTime)
        ).time
    }

    /// Miles and time the summary shows for whatever legs were published.
    /// A superseded style change does not publish, so these stay on the
    /// previous line until the replacement actually lands.
    nonisolated static func rideSummaryTotals(
        distances: [CLLocationDistance],
        times: [TimeInterval]
    ) -> (distance: CLLocationDistance, time: TimeInterval) {
        (
            distance: distances.reduce(0, +),
            time: times.reduce(0, +)
        )
    }

    /// Every gas station found along the route, so the rider can pick any of
    /// them regardless of the selected category. Computed after each route
    /// change by `refreshGasStations()`.
    var gasStations: [SuggestedStop] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Whether the planning sheet's "All gas on route" disclosure is open.
    /// Gray map pins for non-recommended stations follow this so the map
    /// stays quiet until the rider asks for the full list.
    var isShowingAllGasOnRoute = false

    /// Extra gray gas pins: only while browsing a non-gas category *and* the
    /// full station list is expanded. Recommended pumps and category pins stay.
    var showsAllGasPins: Bool {
        selectedCategory != .gas && isShowingAllGasOnRoute
    }

    /// The subset of `gasStations` automatically recommended as fuel stops —
    /// one per tank along the whole ride (`fuelRangeMeters`). Food is
    /// optional; preferred in-window when the tank-interval ETA is a meal.
    /// Travel-side only. Out-of-range stations are not included; they live
    /// on `fuelPlanEntries` as past-range rows.
    var fuelStops: [SuggestedStop] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Recommended stops, inline gap warnings, and past-range stations, in
    /// ride order. The sheet shows gap and past-range rows only when the
    /// coverage that produced them is trusted.
    var fuelPlanEntries: [FuelPlanEntry] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Fuel rows and their labels, replaced in one assignment. A view that
    /// reads the array and the label sees the same generation.
    private var fuelListPresentation = FuelListPresentation()

    /// Fuel rows the sheet should draw. A cancelled or throttled search
    /// keeps in-range recommendations and hides the named gap. A stop
    /// already on the route is omitted so Apply cannot add it twice.
    ///
    /// Stored on `fuelListPresentation`. Rebuilt off the main thread when
    /// the route, the stations, the selection, or the tank change. A view
    /// body only reads the array.
    var visibleFuelPlanEntries: [FuelPlanEntry] {
        fuelListPresentation.visibleEntries
    }

    /// Waypoint coordinates rounded to three decimals. `isStopOnRoute` is
    /// one set lookup, not a scan of the route list.
    private var onRouteCoordinateKeys: Set<String> = []

    /// Coordinates of the fuel rows currently on screen. Suggestions use
    /// this so they are not listed again under the fuel plan.
    private var fuelPlanCoordinateKeys: Set<String> = []

    /// Mile marks of gas already on the route. Rebuilt with the fuel plan.
    private var onRouteGasDistances: [CLLocationDistance] = []

    /// Test identity for one in-range recommendation. Summary rows and the
    /// plain station rows share it, so a list cell that only shows the
    /// station name still exposes `fuelStop.<name>.checked` and a
    /// "Fuel stop N:" label. Past-range rows are not fuel stops.
    func recommendedFuelAccessibility(for stop: SuggestedStop) -> RecommendedFuelAccessibility? {
        guard let label = fuelRowLabel(for: stop) else { return nil }
        return RecommendedFuelAccessibility(
            identifier: label.identifier,
            label: label.accessibilityLabel,
            title: label.title,
            caption: label.caption
        )
    }

    /// Title and caption published for this place. Nil when the stop is not
    /// one of the current fuel rows. Both strings come from the same value.
    func fuelRowLabel(for stop: SuggestedStop) -> FuelRowLabel? {
        fuelListPresentation.labels.label(
            id: stop.id,
            key: Self.coordinateKey(stop.coordinate)
        )
    }

    /// Summary, suggestion, and gas-list rows are separate searches, so they
    /// do not share a UUID. The name is what the ride list shows.
    nonisolated static func sameFuelPlace(_ fuel: SuggestedStop, _ stop: SuggestedStop) -> Bool {
        fuel.id == stop.id
            || fuel.name == stop.name
            || sameCoordinate(fuel.coordinate, stop.coordinate)
    }

    /// Distance, then riding time, for one fuel-stop row.
    ///
    /// "344 mi · 5h 04m riding (2h 29m since last)". The first stop keeps the
    /// miles and the total riding time and drops the since-last part:
    /// "170 mi · 2h 35m riding". Time is each current leg's drive
    /// time spread along that leg's polyline, so a style change, tank-range
    /// search, applied stop, or leave-time replan updates it with the new
    /// line. Applied gas fills count as the previous stop; time sitting at
    /// a stop is not added.
    func fuelStopRidingCaption(for stop: SuggestedStop) -> String {
        let distance = distanceFromStart(of: stop)
        return FuelStopRidingTime.caption(
            distanceMeters: distance,
            anchors: fuelRidingAnchorDistances(including: distance),
            legs: driveLegTimings()
        )
    }

    /// Visible fuel rows plus applied gas fills. The fill is no longer a
    /// row after Apply, but the next recommendation is still "since last"
    /// from that pump.
    private func fuelRidingAnchorDistances(including distance: CLLocationDistance) -> [CLLocationDistance] {
        var anchors = gasFillDistances
        for entry in visibleFuelPlanEntries {
            switch entry {
            case .recommended(let other), .pastRange(let other):
                anchors.append(cachedDistance(for: other))
            case .gap:
                break
            }
        }
        anchors.append(distance)
        return anchors
    }

    /// Subtitle for a row in "Route (N stops)". This is the formatter
    /// `WaypointsSection` reads. The origin has none. The first stop drops
    /// "(since last)". Every later row, including the destination, keeps
    /// it. A replan replaces the line. Nil while the published legs do not
    /// match the list.
    func waypointRidingCaption(at index: Int) -> String? {
        guard legs.count + 1 == waypoints.count else { return nil }
        return FuelStopRidingTime.waypointCaption(index: index, legs: driveLegTimings())
    }

    /// Polyline length and `expectedTravelTime` for each current leg.
    /// The scan ran when `legs` changed. A row caption must not copy the
    /// polyline again.
    private func driveLegTimings() -> [FuelStopRidingTime.Leg] {
        cachedDriveLegs
    }

    /// Copies each leg on the caller, then measures its length off the main
    /// thread. View updates only read `cachedDriveLegs`.
    private func rebuildDriveLegCache() {
        let snapshots = legs.map { route in
            DriveLegSnapshot(
                polyline: RouteGeometry.coordinates(of: route.polyline),
                expectedTravelTime: route.expectedTravelTime
            )
        }
        cachedDriveLegs = Self.driveLegsOffMain(snapshots)
    }

    private nonisolated static func driveLegsOffMain(
        _ snapshots: [DriveLegSnapshot]
    ) -> [FuelStopRidingTime.Leg] {
        guard !snapshots.isEmpty else { return [] }
        return DispatchQueue.global(qos: .userInitiated).sync { @Sendable in
            snapshots.map { snapshot in
                FuelStopRidingTime.leg(
                    polyline: snapshot.polyline,
                    expectedTravelTime: snapshot.expectedTravelTime
                )
            }
        }
    }

    /// Category suggestions the rider can still add. Places already on the
    /// route, and stops already shown in the fuel plan, are left off so the
    /// sheet does not list the same pump twice (riding time in the summary,
    /// and again as "~80 mi from start").
    var addableSuggestions: [SuggestedStop] {
        suggestedStops.filter { stop in
            !isStopOnRoute(stop) && !isShownAsFuelPlanRow(stop)
        }
    }

    /// Rows under "Suggested … Stops". Gas is the fuel-corridor pool, which
    /// already spans the ride, so the list is not the first 15 stations
    /// nearest the origin. Other categories stay capped.
    var suggestionListStops: [SuggestedStop] {
        if selectedCategory == .gas {
            return addableSuggestions
        }
        return Array(addableSuggestions.prefix(15))
    }

    /// True when the summary already renders this place as a fuel row.
    /// Rounded coordinate, so a re-fetched pin of the same pump matches.
    func isShownAsFuelPlanRow(_ stop: SuggestedStop) -> Bool {
        fuelPlanCoordinateKeys.contains(Self.coordinateKey(stop.coordinate))
    }

    /// Identifier whose suffix is the in-range recommendations, in ride
    /// order. UI tests wait for these names instead of a station that is
    /// only a map pin.
    var recommendedFuelPlanAccessibilityID: String {
        let names = visibleFuelPlanEntries.compactMap { entry -> String? in
            guard case .recommended(let stop) = entry else { return nil }
            return stop.name
        }
        return "recommendedFuelPlan." + names.joined(separator: "|")
    }

    /// Gas stations on the rider's side of travel (no crossing oncoming
    /// traffic). Candidate pool for `fuelStops`; recomputed when the route
    /// or tank-interval search changes.
    private var travelSideGasStations: [SuggestedStop] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Travel-side gas stations that have food within `fuelFoodRadiusMeters`.
    /// Fed into `planFuelStops` so a pump with food wins over a gas-only
    /// neighbor in the same tank window.
    private var gasStopsWithFood: Set<UUID> = []

    /// True when the ride is longer than one tank but the route has a stretch
    /// longer than the fuel range with no gas station found.
    var hasFuelGap = false {
        didSet { publishFuelPlanSnapshot() }
    }

    /// Each recommended fuel stop paired with food found right next to it, so a
    /// rider can refuel and eat in one stop. Recomputed whenever `fuelStops`
    /// change by `refreshFoodNearFuelStops()`.
    var fuelFoodStops: [FuelFoodStop] = []

    /// IDs of the fuel stops the food pairing was last computed for. Lets us
    /// skip redundant (networked) food searches when `replanFuelStops()` runs
    /// but the chosen stops haven't actually changed — e.g. small tank-range
    /// tweaks that don't move any stop.
    private var pairedFuelStopIDs: Set<UUID> = []

    /// A handful of recommended places of interest along the ride — low-detour
    /// sights spread across the route that make good stops. Recomputed after
    /// each route change by `refreshHighlights()`.
    var rideHighlights: [SuggestedStop] = [] {
        didSet { rebuildDistanceCache() }
    }

    /// Distance along the current route, keyed by station or waypoint id.
    /// Rebuilt off the main thread when stations or the route change. View
    /// updates only read this map.
    private var distanceAlongRouteByID: [UUID: CLLocationDistance] = [:]

    /// Bumped when the polyline changes. Station edits reuse `cachedMeasuredRoute`
    /// so Select recommended does not rebuild the coast-to-coast line per array.
    private var routeGeometryGeneration = 0
    private var measuredRouteGeneration = -1
    private var cachedMeasuredRoute: RouteGeometry.MeasuredRoute?

    /// Bumped when highlights are cleared or refreshed. A description fetch
    /// from an older pass must not write over the newer list.
    private var highlightGeneration = 0

    /// When the rider plans to leave, or `nil` to assume leaving now. Drives
    /// the weather check so a ride planned for tomorrow morning is checked
    /// against tomorrow morning's forecast, not right now's.
    private(set) var departureDate: Date?

    /// The departure used for time-of-passing estimates. A picked time that
    /// has since passed falls back to "now" rather than a time in the past.
    var effectiveDeparture: Date {
        guard let departureDate, departureDate > Date() else { return Date() }
        return departureDate
    }

    /// Sets when the rider plans to leave (`nil` = now).
    ///
    /// The date picker fires on every wheel tick. Each tick only stores the
    /// date and arms one commit. After the wheel has been quiet, that commit
    /// cancels in-flight route or gas work and restarts it once — the route
    /// if the line is still calculating, gas if a search is running. An idle
    /// plan re-picks fuel stops and refreshes weather without a new search.
    func setDeparture(_ date: Date?) {
        guard date != departureDate else { return }
        departureDate = date
        scheduleDepartureCommit()
    }

    /// Quiet period after the last picker tick. Rapid ticks share one restart.
    nonisolated static let departureSettleDelay: Duration = .milliseconds(400)

    /// While the line is still calculating, a settled departure restarts that
    /// plan once so directions and the gas tail share the new time. While gas
    /// is in flight (or the line is up and gas has not published yet), only
    /// the gas search restarts. A finished plan re-picks stops locally.
    nonisolated static func planRestartForDepartureChange(
        isCalculating: Bool,
        isSearchingGas: Bool,
        hasLegs: Bool,
        loadState: GasLoadState
    ) -> DepartureRestart {
        if isCalculating { return .route }
        if hasLegs, isSearchingGas || loadState == .pending { return .gas }
        return .local
    }

    /// Only the latest picker tick may restart. An earlier tick was cancelled
    /// when the next one was armed.
    nonisolated static func shouldCommitDeparture(
        tick: Int,
        latestTick: Int,
        cancelled: Bool
    ) -> Bool {
        tick == latestTick && !cancelled
    }

    /// The fuel-gap warning is a coverage result. A cancelled, throttled, or
    /// otherwise incomplete search must not raise it, even if the planner
    /// would flag a dry stretch on the stations it happened to hold.
    nonisolated static func gasCoverageIsTrusted(
        status: GasSearchStatus,
        failed: Int,
        throttled: Int
    ) -> Bool {
        status == .completed && failed == 0 && throttled == 0
    }

    nonisolated static func shouldShowFuelGapWarning(
        hasFuelGap: Bool,
        coverageTrusted: Bool,
        loadState: GasLoadState,
        isCalculating: Bool,
        isSearchingGas: Bool
    ) -> Bool {
        hasFuelGap
            && coverageTrusted
            && (loadState == .loaded || loadState == .empty)
            && !isCalculating
            && !isSearchingGas
    }

    /// True only after the current generation published a search in which
    /// every sample returned. The gap warning reads this so a partial or
    /// throttled pool cannot say the tank does not reach.
    private var gasCoverageTrusted = false {
        didSet { publishFuelPlanSnapshot() }
    }

    /// Mile marks whose lookup throttled or failed. The planner must not
    /// treat the road between them as empty.
    private var unsearchedFuelDistances: [CLLocationDistance] = []

    var showsFuelGapWarning: Bool {
        Self.shouldShowFuelGapWarning(
            hasFuelGap: hasFuelGap,
            coverageTrusted: gasCoverageTrusted,
            loadState: gasLoadState,
            isCalculating: isCalculating,
            isSearchingGas: isSearchingGas
        )
    }

    private var departureTick = 0
    private var departureCommitTask: Task<Void, Never>?
    private var weatherGeneration = 0
    private var weatherTask: Task<Void, Never>?

    private func scheduleDepartureCommit() {
        departureTick += 1
        let tick = departureTick
        departureCommitTask?.cancel()
        gasLog.info("departure tick=\(tick, privacy: .public) armed")
        departureCommitTask = Task { await commitDepartureAfterSettle(tick: tick) }
    }

    private func commitDepartureAfterSettle(tick: Int) async {
        let waited = await Self.pauseForDepartureSettle()
        let commit = Self.shouldCommitDeparture(
            tick: tick,
            latestTick: departureTick,
            cancelled: Task.isCancelled || !waited
        )
        guard commit else {
            gasLog.info("departure drop tick=\(tick, privacy: .public) latest=\(self.departureTick, privacy: .public) reason=superseded")
            return
        }
        commitSettledDeparture(tick: tick)
    }

    private func commitSettledDeparture(tick: Int) {
        guard waypoints.count >= 2 else { return }
        let action = Self.planRestartForDepartureChange(
            isCalculating: isCalculating,
            isSearchingGas: isSearchingGas,
            hasLegs: !legs.isEmpty,
            loadState: gasLoadState
        )
        gasLog.info("departure commit tick=\(tick, privacy: .public) action=\(action.logName, privacy: .public) calculating=\(self.isCalculating, privacy: .public) searching=\(self.isSearchingGas, privacy: .public) gas=\(self.gasLoadState.logName, privacy: .public)")
        switch action {
        case .route:
            scheduleRecalculation()
        case .gas:
            scheduleGasSearch()
            scheduleWeatherRefresh()
        case .local:
            guard !legs.isEmpty else { return }
            replanFuelStops()
            scheduleWeatherRefresh()
        }
    }

    /// `false` when this settle wait was cancelled by a newer tick.
    private static func pauseForDepartureSettle() async -> Bool {
        do {
            try await Task.sleep(for: departureSettleDelay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private func beginWeatherRefresh() -> Int {
        weatherGeneration += 1
        weatherTask?.cancel()
        return weatherGeneration
    }

    private func scheduleWeatherRefresh() {
        let generation = beginWeatherRefresh()
        weatherTask = Task { await refreshWeather(generation: generation) }
    }

    /// Drops a stale coverage flag so a restart cannot keep showing the
    /// fuel-gap warning from the search it just cancelled.
    private func invalidateFuelCoverage() {
        gasCoverageTrusted = false
        hasFuelGap = false
        unsearchedFuelDistances = []
    }

    /// Rain risk along the route at the rider's expected time of passing, or
    /// `nil` if unknown (weather unavailable) or not yet checked.
    var rainForecast: RouteRainForecast?

    /// True while the route's weather is being fetched.
    var isCheckingWeather = false

    /// Precipitation chance (0...1) at or above which a rain warning is shown.
    static let rainChanceThreshold = 0.3

    private let weatherService = RouteWeatherService()

    /// Posts a local rain warning so the rider is alerted after they've put the
    /// phone away. Mirrors the on-screen `rainWarning`.
    private let weatherNotifier = WeatherNotificationService()

    /// A rider-facing rain warning, or `nil` when rain is unlikely / unknown.
    var rainWarning: String? {
        guard let forecast = rainForecast, forecast.maxChance >= Self.rainChanceThreshold else {
            return nil
        }
        let percent = Int((forecast.maxChance * 100).rounded())
        let formatter = MKDistanceFormatter()
        formatter.unitStyle = .abbreviated
        let whereText = formatter.string(fromDistance: forecast.distanceOfMaxChance)
        return "\(percent)% chance of rain along your route (around \(whereText) from start). Pack rain gear."
    }

    // MARK: - Waypoint management

    func addWaypoint(_ waypoint: Waypoint) {
        // Reject coordinates MapKit can't handle (invalid / NaN), which would
        // otherwise trip an assertion once they reach a route request or the map.
        guard waypoint.coordinate.isValidLocation else { return }
        // When the rider adds their first place, treat it as the destination
        // and seed the start with the current location so the route plots
        // from here immediately — no need to add a start point by hand.
        if waypoints.isEmpty, let here = currentLocation, here.isValidLocation {
            waypoints.append(Waypoint(name: "Current Location", coordinate: here))
        }
        // Later searches and contact addresses insert before the existing
        // destination so they become mid-ride stops, matching `addStop`.
        if waypoints.count >= 2 {
            waypoints.insert(waypoint, at: waypoints.count - 1)
        } else {
            waypoints.append(waypoint)
        }
        scrollToWaypointID = waypoint.id
        scheduleRecalculation()
    }

    /// Sets the ride origin. Replaces the first waypoint when one already
    /// exists (for example the auto-seeded current location) so a long-press
    /// does not insert a second start.
    func addStart(_ waypoint: Waypoint) {
        guard waypoint.coordinate.isValidLocation else { return }
        if waypoints.isEmpty {
            waypoints.append(waypoint)
        } else {
            waypoints[0] = waypoint
        }
        scrollToWaypointID = waypoints.first?.id
        scheduleRecalculation()
    }

    func addStop(from suggestion: SuggestedStop) {
        guard suggestion.coordinate.isValidLocation else { return }
        // A place already on the ride is not added again, even when a new
        // search returns it under a different name.
        guard !isStopOnRoute(suggestion) else { return }
        // Gas is buffered (AC-C5). Checking a pump must not re-route; Apply
        // inserts the set once. Food, sights, and other categories still
        // insert immediately.
        if suggestion.category == .gas {
            toggleBufferedGasStop(suggestion)
            return
        }
        insertStop(suggestion)
        scheduleRecalculation()
    }

    /// Checks or unchecks a gas stop. Does not change waypoints or legs.
    /// A pump already on the route is left unchecked.
    func toggleBufferedGasStop(_ stop: SuggestedStop) {
        guard stop.coordinate.isValidLocation, stop.category == .gas else { return }
        guard !isStopOnRoute(stop) else {
            bufferedGasStops.removeAll { Self.sameCoordinate($0.coordinate, stop.coordinate) }
            return
        }
        if let index = bufferedGasStops.firstIndex(where: { Self.sameCoordinate($0.coordinate, stop.coordinate) }) {
            bufferedGasStops.remove(at: index)
        } else {
            bufferedGasStops.append(stop)
        }
    }

    func isGasBuffered(_ stop: SuggestedStop) -> Bool {
        bufferedGasStops.contains { Self.sameCoordinate($0.coordinate, stop.coordinate) }
    }

    /// Recommended fuel stops the rider can still check (AC-C7). Food,
    /// past-range stations, and stops already on the route are left out.
    var selectableRecommendedFuelStops: [SuggestedStop] {
        fuelStops.filter { stop in
            stop.category == .gas
                && !isPastRangeFuelStop(stop)
                && !isStopOnRoute(stop)
        }
    }

    /// Label for the one-tap control above the buffered gas rows.
    var selectRecommendedButtonTitle: String {
        "Select recommended"
    }

    /// Copy next to the small spinner. The flag is set on the tap, before
    /// the scan, so this row can appear within half a second.
    nonisolated static let fuelSelectionStatus = "Finding fuel stops…"

    /// True from the tap until the route list takes the result. Set before
    /// any scan so `fuel.selecting.spinner` is on screen within half a
    /// second, including while a multi-second scan keeps the main actor free.
    private(set) var isSelectingRecommendedFuel = false

    /// The in-flight tap. A second tap waits for this one instead of
    /// inserting the same stops twice.
    private var recommendedFuelSelectionTask: Task<Void, Never>?

    /// Skips the per-assignment distance rebuild while one tap is writing
    /// several arrays. The tap measures once, off the main actor, at the end.
    private var suppressDistanceRebuild = false

    /// Greater than zero while stops and entries are changing together.
    /// Snapshots wait until the batch finishes so a row cannot publish
    /// halfway through.
    private var fuelListMutationDepth = 0

    /// Checks every recommended fuel stop from the start to the destination,
    /// in ride order, and adds that whole set in the same tap. The route is
    /// recalculated once. When the current line already has stations, the
    /// tap replans through `replanFuelStops` first so the inserted hops are
    /// the reserve cap (0.85 × tank), or the nearest station still inside
    /// the tank when that window is empty. A pump already on the route is a
    /// fill for that check, including one search added without `isGasFill`,
    /// so the next station is measured from that pump rather than the
    /// origin. A stop on the far side of a dry gap stays on the list and is
    /// not inserted. Past-range stations, other categories, and pumps
    /// already on the route stay out. Afterward none of those
    /// recommendations are still selectable. A pump the rider checked by
    /// hand, and that is not one of these recommendations, stays checked
    /// for Apply and is not routed by this tap.
    ///
    /// The travel-side scan, the fuel plan, and the route insert run off
    /// the main actor. Callers that need the inserted stops await this.
    /// The button does not: `startRecommendedFuelSelection` returns as soon
    /// as the flag is set.
    func toggleRecommendedFuelSelection() async {
        if let recommendedFuelSelectionTask {
            await recommendedFuelSelectionTask.value
            return
        }
        startRecommendedFuelSelection()
        if let recommendedFuelSelectionTask {
            await recommendedFuelSelectionTask.value
        }
    }

    /// Sets the spinner and returns before any scan. The sheet can paint
    /// `fuel.selecting.spinner` within half a second, and the main actor
    /// stays free for the rest of the scan even when that scan takes a few
    /// seconds.
    func startRecommendedFuelSelection() {
        guard recommendedFuelSelectionTask == nil else { return }
        isSelectingRecommendedFuel = true
        let task = Task { @MainActor in
            defer {
                self.isSelectingRecommendedFuel = false
                self.recommendedFuelSelectionTask = nil
            }
            // One turn for SwiftUI to draw the spinner before the snapshot.
            await Task.yield()
            await self.runRecommendedFuelSelection()
        }
        recommendedFuelSelectionTask = task
    }

    /// Snapshots sendable inputs, then awaits the whole selection off the
    /// main actor and assigns the result once.
    private func runRecommendedFuelSelection() async {
        let input = makeFuelSelectionInput()
        if !input.replan, !Self.hasSelectableFuel(input) {
            return
        }
        let output = await Task.detached(priority: .userInitiated) {
            Self.computeFuelSelection(input)
        }.value
        applyFuelSelection(output)
    }

    /// Copies coordinates and ids on the main actor. The scan that follows
    /// does not touch `MKMapItem` or `MKPolyline`.
    private func makeFuelSelectionInput() -> FuelSelectionInput {
        func station(_ stop: SuggestedStop) -> FuelSelectionStation {
            let coordinate = stop.coordinate
        return FuelSelectionStation(
            id: stop.id,
            name: stop.name,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            distance: stop.distanceAlongRoute,
            detour: stop.detourMeters,
            key: Self.coordinateKey(coordinate),
            isGas: stop.category == .gas
        )
        }
        var pastRangeIDs = Set<UUID>()
        var pastRangeKeys = Set<String>()
        for entry in fuelPlanEntries {
            guard case .pastRange(let stop) = entry else { continue }
            pastRangeIDs.insert(stop.id)
            pastRangeKeys.insert(Self.coordinateKey(stop.coordinate))
        }
        let corridorReady = plannedCorridor.contains(where: { $0.count > 1 })
        return FuelSelectionInput(
            stations: gasStations.map(station),
            existingFuelStops: fuelStops.map(station),
            existingRows: fuelPlanInputs().rows,
            buffered: bufferedGasStops.map(station),
            pastRangeIDs: pastRangeIDs,
            pastRangeKeys: pastRangeKeys,
            waypoints: waypoints.map { waypoint in
                FuelSelectionWaypoint(
                    id: waypoint.id,
                    name: waypoint.name,
                    latitude: waypoint.coordinate.latitude,
                    longitude: waypoint.coordinate.longitude,
                    isGasFill: waypoint.isGasFill,
                    key: Self.coordinateKey(waypoint.coordinate)
                )
            },
            queries: distanceQueries(),
            polylines: corridorReady ? plannedCorridor : [],
            tank: fuelRangeMeters,
            totalDistance: totalDistanceMeters,
            totalTravelTime: totalExpectedTravelTime,
            departure: effectiveDeparture,
            foodIDs: gasStopsWithFood,
            unsearched: unsearchedFuelDistances,
            drivesOnRight: RouteGeometry.drivesOnRight,
            replan: totalDistanceMeters > fuelRangeMeters && !gasStations.isEmpty,
            hasLegs: !legs.isEmpty,
            countsGasFills: !legs.isEmpty || corridorReady,
            showsGap: showsFuelGapWarning,
            driveLegs: cachedDriveLegs,
            usesMetric: AppSettings.usesMetricUnits
        )
    }

    /// One turn: waypoints, the fuel rows, and the cached sets. Distance
    /// rebuilds stay suppressed so each stored property does not measure
    /// the polyline again.
    private func applyFuelSelection(_ output: FuelSelectionOutput) {
        suppressDistanceRebuild = true
        defer { suppressDistanceRebuild = false }

        var stationsByID: [UUID: SuggestedStop] = [:]
        for stop in gasStations {
            stationsByID[stop.id] = stop
        }
        var fuelStopsByID: [UUID: SuggestedStop] = [:]
        for stop in fuelStops {
            fuelStopsByID[stop.id] = stop
        }
        func stop(for id: UUID) -> SuggestedStop? {
            stationsByID[id] ?? fuelStopsByID[id]
        }

        if output.didReplan {
            travelSideGasStations = output.poolIDs.compactMap { stationsByID[$0] }
            if !output.clearFuel {
                let plan = Self.fuelPlan(from: output.draft, stops: gasStations)
                fuelStops = plan.stops
                fuelPlanEntries = plan.entries
                hasFuelGap = output.planHasGap && gasCoverageTrusted
            }
        }

        if output.hasInserts {
            var waypointsByID: [UUID: Waypoint] = [:]
            for waypoint in waypoints {
                waypointsByID[waypoint.id] = waypoint
            }
            let existingIDs = Set(waypoints.map(\.id))
            var placed: [Waypoint] = []
            placed.reserveCapacity(output.placements.count)
            for placement in output.placements {
                switch placement {
                case .keep(let id):
                    if let waypoint = waypointsByID[id] {
                        placed.append(waypoint)
                    }
                case .insert(let id):
                    guard let stop = stop(for: id) else { continue }
                    placed.append(Self.waypoint(from: stop))
                }
            }
            if placed.count >= 2 {
                waypoints = placed
            }
            var bufferedByID: [UUID: SuggestedStop] = [:]
            for stop in bufferedGasStops {
                bufferedByID[stop.id] = stop
            }
            bufferedGasStops = output.keptBufferedIDs.compactMap { bufferedByID[$0] }
            if let added = waypoints.first(where: { !existingIDs.contains($0.id) }) {
                scrollToWaypointID = added.id
            }
            scheduleRecalculation()
        }

        distanceAlongRouteByID = output.distances
        onRouteCoordinateKeys = output.onRouteKeys
        fuelPlanCoordinateKeys = output.clearFuel ? [] : output.fuelPlanKeys
        onRouteGasDistances = output.onRouteGasDistances
        // Rows and labels swap together, after every other field is in place.
        var byID: [String: FuelPlanEntry] = [:]
        for entry in fuelPlanEntries {
            byID[entry.id] = entry
        }
        let visible = output.clearFuel
            ? []
            : output.visibleEntryIDs.compactMap { byID[$0] }
        fuelListPresentation = FuelListPresentation(
            visibleEntries: visible,
            labels: output.clearFuel ? FuelRowLabelSet() : output.labels
        )
    }

    /// True when a waypoint already sits on this place. Matching is the
    /// coordinate rounded to three decimals (~111 m), so a re-fetched pin
    /// with a new name still counts as the stop the rider applied.
    func isStopOnRoute(_ stop: SuggestedStop) -> Bool {
        onRouteCoordinateKeys.contains(Self.coordinateKey(stop.coordinate))
    }

    /// A station the fuel list marks past the tank. Never part of the
    /// one-tap recommended selection, even if it also sits in `fuelStops`.
    func isPastRangeFuelStop(_ stop: SuggestedStop) -> Bool {
        fuelPlanEntries.contains { entry in
            guard case .pastRange(let past) = entry else { return false }
            return past.id == stop.id || Self.sameCoordinate(past.coordinate, stop.coordinate)
        }
    }

    /// True when `distance` is farther than the tank from the last fill the
    /// rider can use: the start, an applied gas stop, or an in-range
    /// recommendation. Recommended stops themselves are inside that window.
    func isBeyondRemainingRange(distanceAlongRoute distance: CLLocationDistance) -> Bool {
        guard distance.isFinite, distance > 0, fuelRangeMeters > 0 else { return false }
        if isRecommendedFuelDistance(distance) { return false }
        let previous = remainingRangeAnchors
            .filter { $0 < distance - FuelStopRidingTime.sameStopToleranceMeters }
            .max() ?? 0
        return distance - previous > fuelRangeMeters
    }

    /// A waypoint past the tank from the previous fill. Nil legs, or a list
    /// that does not match the published route, are not labeled.
    func waypointIsBeyondRemainingRange(at index: Int) -> Bool {
        guard index > 0, legs.count + 1 == waypoints.count else { return false }
        let distance = legs.prefix(index).reduce(0) { $0 + $1.distance }
        return isBeyondRemainingRange(distanceAlongRoute: distance)
    }

    /// Shown on a fuel stop whose hop from the previous fill is longer
    /// than the full tank. A hop inside the tank, even past the 170 mi
    /// reserve, keeps its mileage and has no note.
    /// Nonisolated so the note helper and the nonisolated planner tests can
    /// read it; the class is `@MainActor`.
    nonisolated static let pastFullTankNotice = "Past full tank"

    /// Captions the route list draws under the stop name, in order.
    func waypointRangeNotices(at index: Int) -> [String] {
        guard waypointIsBeyondRemainingRange(at: index) else { return [] }
        return ["Past your range"]
    }

    /// Nil when `hop` still fits in the tank, including a 193 mi hop on a
    /// 200 mi tank. "Past full tank" only when the nearest station is farther
    /// than the tank.
    nonisolated static func pastFullTankNote(
        hopMeters: CLLocationDistance,
        tankMeters: CLLocationDistance
    ) -> String? {
        guard hopMeters.isFinite, tankMeters > 0, hopMeters > tankMeters else { return nil }
        return pastFullTankNotice
    }

    /// Miles from the previous fill (or the start) to this station, using
    /// the same anchors as the fuel-row caption.
    func fuelHopMeters(for stop: SuggestedStop) -> CLLocationDistance {
        let distance = cachedDistance(for: stop)
        guard distance.isFinite else { return 0 }
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        let previous = fuelRidingAnchorDistances(including: distance)
            .filter { $0.isFinite && $0 < distance - tolerance }
            .max() ?? 0
        return max(0, distance - previous)
    }

    /// The fuel-list note for this station. Recommended stops inside the
    /// tank, including those past the reserve, return nil. A station the
    /// plan marks past the tank always gets the note.
    func fuelListNote(for stop: SuggestedStop) -> String? {
        let pastEntry = fuelPlanEntries.contains { entry in
            guard case .pastRange(let past) = entry else { return false }
            return Self.sameFuelPlace(past, stop)
        }
        if pastEntry { return Self.pastFullTankNotice }
        return Self.pastFullTankNote(hopMeters: fuelHopMeters(for: stop), tankMeters: fuelRangeMeters)
    }

    private var remainingRangeAnchors: [CLLocationDistance] {
        var anchors: [CLLocationDistance] = [0]
        anchors.append(contentsOf: gasFillDistances)
        anchors.append(contentsOf: fuelStops.map { cachedDistance(for: $0) })
        return anchors
    }

    private func isRecommendedFuelDistance(_ distance: CLLocationDistance) -> Bool {
        fuelStops.contains {
            abs(cachedDistance(for: $0) - distance) <= FuelStopRidingTime.sameStopToleranceMeters
        }
    }

    /// Drops the checked set. The planned route is unchanged.
    func clearBufferedGasStops() {
        bufferedGasStops = []
    }

    /// Inserts every checked gas stop in ride order, then routes once.
    /// Stops already on the route, and repeats of the same coordinate in
    /// the checked set, are dropped.
    func applyBufferedGasStops() {
        var seen = Set<String>()
        let stops = bufferedGasStops
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
            .filter { stop in
                guard !isStopOnRoute(stop) else { return false }
                return seen.insert(Self.coordinateKey(stop.coordinate)).inserted
            }
        bufferedGasStops = []
        guard !stops.isEmpty else { return }
        let existingIDs = Set(waypoints.map(\.id))
        let polylines = plannedCorridor
        if waypoints.count >= 2, !polylines.isEmpty {
            waypoints = Self.waypoints(
                waypoints,
                inserting: stops,
                along: polylines,
                totalDistance: totalDistanceMeters
            )
        } else {
            for stop in stops {
                insertStop(stop)
            }
        }
        if let added = waypoints.first(where: { !existingIDs.contains($0.id) }) {
            scrollToWaypointID = added.id
        }
        scheduleRecalculation()
    }

    /// Places `stops` among existing waypoints by distance along `polylines`.
    /// The destination stays last.
    nonisolated static func waypoints(
        _ waypoints: [Waypoint],
        inserting stops: [SuggestedStop],
        along polylines: [[CLLocationCoordinate2D]],
        totalDistance: CLLocationDistance
    ) -> [Waypoint] {
        guard waypoints.count >= 2 else {
            var occupied = Set(waypoints.map { coordinateKey($0.coordinate) })
            let added = stops.compactMap { stop -> Waypoint? in
                let key = coordinateKey(stop.coordinate)
                guard occupied.insert(key).inserted else { return nil }
                return waypoint(from: stop)
            }
            return waypoints + added
        }
        // One measurement for every middle stop. A start-and-end ride has
        // nothing to project, and rebuilding the line per stop was the hitch.
        let measured: RouteGeometry.MeasuredRoute? = waypoints.count > 2
            && polylines.contains(where: { $0.count > 1 })
            ? RouteGeometry.MeasuredRoute(polylines: polylines)
            : nil
        var placed: [(distance: CLLocationDistance, waypoint: Waypoint)] = []
        for (index, waypoint) in waypoints.enumerated() {
            let distance: CLLocationDistance
            if index == 0 {
                distance = 0
            } else if index == waypoints.count - 1 {
                distance = .greatestFiniteMagnitude
            } else if let measured {
                distance = RouteGeometry.distanceAlongRoute(of: waypoint.coordinate, on: measured)
            } else if polylines.isEmpty {
                distance = totalDistance * Double(index) / Double(waypoints.count)
            } else {
                distance = 0
            }
            placed.append((distance, waypoint))
        }
        var occupied = Set(waypoints.map { coordinateKey($0.coordinate) })
        for stop in stops.sorted(by: { $0.distanceAlongRoute < $1.distanceAlongRoute }) {
            let key = coordinateKey(stop.coordinate)
            guard occupied.insert(key).inserted else { continue }
            let waypoint = waypoint(from: stop)
            let index = placed.firstIndex { $0.distance > stop.distanceAlongRoute } ?? placed.count
            placed.insert((stop.distanceAlongRoute, waypoint), at: index)
        }
        return placed.map(\.waypoint)
    }

    private func insertStop(_ suggestion: SuggestedStop) {
        guard !waypoints.contains(where: { Self.sameCoordinate($0.coordinate, suggestion.coordinate) }) else {
            return
        }
        let waypoint = Self.waypoint(from: suggestion)
        if waypoints.count >= 2 {
            waypoints.insert(waypoint, at: waypoints.count - 1)
        } else {
            waypoints.append(waypoint)
        }
        scrollToWaypointID = waypoint.id
    }

    private nonisolated static func waypoint(from suggestion: SuggestedStop) -> Waypoint {
        Waypoint(
            name: suggestion.name,
            coordinate: suggestion.coordinate,
            isGasFill: suggestion.category == .gas
        )
    }

    nonisolated static func samePlace(_ lhs: SuggestedStop, _ rhs: SuggestedStop) -> Bool {
        lhs.name == rhs.name && sameCoordinate(lhs.coordinate, rhs.coordinate)
    }

    /// Same place for dedupe: latitude and longitude rounded to three
    /// decimals (~111 m). The name is ignored so a second search result
    /// for the pump already on the route does not insert a copy.
    nonisolated static func sameCoordinate(
        _ lhs: CLLocationCoordinate2D,
        _ rhs: CLLocationCoordinate2D
    ) -> Bool {
        coordinateKey(lhs) == coordinateKey(rhs)
    }

    nonisolated static func coordinateKey(_ coordinate: CLLocationCoordinate2D) -> String {
        "\(roundedThousandths(coordinate.latitude))|\(roundedThousandths(coordinate.longitude))"
    }

    private nonisolated static func roundedThousandths(_ value: Double) -> Int {
        Int((value * 1000).rounded())
    }

    func removeWaypoint(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        scheduleRecalculation()
    }

    func moveWaypoint(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)
        scheduleRecalculation()
    }

    // MARK: - Routing

    /// Routes each consecutive pair of waypoints. Fastest, Avoid Highways,
    /// and Scenic use one request per leg. Twisty may use alternates and an
    /// offset corridor, then keeps that geometry for fuel, food, and highlights.
    func recalculateRoute(
        refreshingSuggestions: Bool = true,
        calcGen: Int,
        gasGen: Int
    ) async {
        guard calcGen == calculatingGeneration else { return }
        // Dropping the old suggestion rows does not need a polyline walk.
        // The synchronous rebuild blocked the main thread for the whole tap.
        suppressDistanceRebuild = true
        suggestedStops = []
        suppressDistanceRebuild = false
        errorMessage = nil
        rainForecast = nil

        guard waypoints.count >= 2 else {
            legs = []
            twistyLimitationNote = nil
            clearStopRecommendations()
            if calcGen == calculatingGeneration {
                isCalculating = false
                calculationStatus = nil
            }
            await weatherNotifier.updateRainWarning(nil)
            return
        }

        isCalculating = true
        calculationStatus = Self.routeReplanStatus(style: routeStyle)
        defer {
            if calcGen == calculatingGeneration {
                isCalculating = false
                calculationStatus = nil
                replanStepDetail = nil
                showsReplanProgress = false
                replanProgressTask?.cancel()
            }
        }

        var newLegs: [MKRoute] = []
        var missedTwistyLegs = 0
        let legCount = waypoints.count - 1
        let corridor = plannedCorridor

        for i in 0..<legCount {
            let origin = waypoints[i]
            let destination = waypoints[i + 1]
            guard Self.shouldPublishRoute(
                generation: calcGen,
                latestGeneration: calculatingGeneration,
                cancelled: Task.isCancelled
            ) else { return }
            calculationStatus = Self.routeReplanStatus(style: routeStyle)
            replanStepDetail = routeProgress(index: i, count: legCount)
            let key = TwistyRouting.legCacheKey(
                from: origin.coordinate,
                to: destination.coordinate,
                style: routeStyle,
                departure: effectiveDeparture
            )
            do {
                let outcome: (routes: [MKRoute], usedFastestFallback: Bool)
                if let cached = legCache[key] {
                    outcome = (cached.routes, cached.usedFastestFallback)
                } else if routeStyle == .twisty {
                    let fastestKey = TwistyRouting.legCacheKey(
                        from: origin.coordinate,
                        to: destination.coordinate,
                        style: .fastest,
                        departure: effectiveDeparture
                    )
                    let cachedFastest = legCache[fastestKey]?.routes
                    let straight = CLLocation(
                        latitude: origin.coordinate.latitude,
                        longitude: origin.coordinate.longitude
                    ).distance(from: CLLocation(
                        latitude: destination.coordinate.latitude,
                        longitude: destination.coordinate.longitude
                    ))
                    let onCorridor = TwistyRouting.liesOnPlannedCorridor(
                        from: origin.coordinate,
                        to: destination.coordinate,
                        polylines: corridor
                    )
                    let plan = TwistyRouting.fetchPlan(
                        straightMeters: straight,
                        liesOnPlannedCorridor: onCorridor
                    )
                    if plan.offsetVias {
                        calculationStatus = Self.routeReplanStatus(style: routeStyle)
                        replanStepDetail = "Looking for a curvier road… (\(i + 1) of \(legCount))"
                    }
                    outcome = try await twistyLeg(
                        from: origin,
                        to: destination,
                        avoidHighwayAlternates: plan.avoidHighwayAlternates,
                        probeOffsetVias: plan.offsetVias,
                        cachedFastest: cachedFastest
                    )
                } else {
                    let routes = try await calculateRoutes(
                        from: origin.coordinate,
                        to: destination.coordinate,
                        avoidsHighways: routeStyle.avoidsHighways,
                        avoidsTolls: routeStyle.avoidsTolls,
                        alternates: routeStyle.prefersAlternates
                    )
                    guard let route = Self.preferredRoute(from: routes, style: routeStyle) else {
                        guard calcGen == calculatingGeneration, !Task.isCancelled else { return }
                        failRoute(between: origin, and: destination)
                        return
                    }
                    outcome = ([route], false)
                }
                // MKDirections isn't cancellation-aware, so a superseded
                // recalculation still gets its response — drop it here rather
                // than let stale legs overwrite the newer plan's results.
                guard calcGen == calculatingGeneration, !Task.isCancelled else { return }
                guard !outcome.routes.isEmpty else {
                    guard calcGen == calculatingGeneration else { return }
                    failRoute(between: origin, and: destination)
                    return
                }
                legCache[key] = CachedLeg(
                    routes: outcome.routes,
                    usedFastestFallback: outcome.usedFastestFallback
                )
                if outcome.usedFastestFallback { missedTwistyLegs += 1 }
                newLegs.append(contentsOf: outcome.routes)
            } catch is CancellationError {
                return
            } catch {
                guard calcGen == calculatingGeneration, !Task.isCancelled else { return }
                errorMessage = "Routing failed: \(error.localizedDescription)"
                legs = []
                twistyLimitationNote = nil
                clearStopRecommendations()
                return
            }
        }

        guard Self.shouldPublishRoute(
            generation: calcGen,
            latestGeneration: calculatingGeneration,
            cancelled: Task.isCancelled
        ) else { return }
        legs = newLegs
        plannedCorridor = newLegs.map { RouteGeometry.coordinates(of: $0.polyline) }
        twistyLimitationNote = routeStyle == .twisty
            ? Self.twistyLimitationNote(missedLegs: missedTwistyLegs, totalLegs: legCount)
            : nil
        // Geometry is committed. Drop the calculating flag before gas so a
        // tank-range tweak restarts the search once instead of the whole line.
        // The banner is `isCalculating` and nothing else: it comes down as
        // soon as the line is ready. UI tests watch it while the stubbed
        // directions request is still in flight.
        if calcGen == calculatingGeneration {
            isCalculating = false
            calculationStatus = nil
        }
        guard calcGen == calculatingGeneration, gasGen == gasGeneration, !Task.isCancelled else { return }
        // Chip suggestions often find pumps the tank-interval search misses
        // (long interstate). Search gas, then merge those suggestions into
        // the fuel pool so later tanks still get a recommendation.
        await refreshGasStations(generation: gasGen)
        guard gasGen == gasGeneration, !Task.isCancelled else { return }
        if refreshingSuggestions {
            await refreshSuggestions()
        }
        guard gasGen == gasGeneration, !Task.isCancelled else { return }
        applyFuelCandidatePool()
        await refreshHighlights()
        guard gasGen == gasGeneration, !Task.isCancelled else { return }
        let weatherGen = beginWeatherRefresh()
        await refreshWeather(generation: weatherGen)
    }

    private func routeProgress(index: Int, count: Int) -> String {
        let step = "(\(index + 1) of \(count))"
        if routeStyle == .twisty {
            return "Calculating Twisty route… \(step)"
        }
        return "Calculating route… \(step)"
    }

    /// Changes the route style, remembers it as the rider's new default, and
    /// re-plans the current ride once. A second change cancels that plan
    /// and starts another. The leg cache is keyed by style, so the new
    /// pass cannot reuse the previous style's geometry.
    func setRouteStyle(_ style: RouteStyle) {
        guard let restart = Self.styleChangeRestart(from: routeStyle, to: style) else { return }
        routeStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: AppSettings.Keys.routeStyle)
        switch restart {
        case .route:
            scheduleRecalculation()
        case .gas:
            scheduleGasSearch()
        }
    }

    /// A real style change redraws the line (and the gas search that follows
    /// it). The same style is not a restart.
    nonisolated static func styleChangeRestart(from current: RouteStyle, to next: RouteStyle) -> PlanRestart? {
        current == next ? nil : .route
    }

    /// Only the latest style change may publish. An earlier run was cancelled
    /// when the next one was armed.
    nonisolated static func shouldPublishRoute(
        generation: Int,
        latestGeneration: Int,
        cancelled: Bool
    ) -> Bool {
        generation == latestGeneration && !cancelled
    }

    /// "Replanning for Twisty…" is set synchronously, before any routing
    /// request. The first plan uses the same sentence as a style switch.
    nonisolated static func routeReplanStatus(style: RouteStyle) -> String {
        "Replanning for \(style.rawValue)…"
    }

    /// Map banner: a line is already drawn and a replacement is in flight.
    /// The first plan has no line yet, so the sheet carries the same copy.
    nonisolated static func showsMapReplanBanner(isCalculating: Bool, hasLegs: Bool) -> Bool {
        isCalculating && hasLegs
    }

    /// The previous line stays on the map, dimmed, until the new one lands.
    nonisolated static func shouldDimExistingLine(isCalculating: Bool, hasLegs: Bool) -> Bool {
        isCalculating && hasLegs
    }

    /// Spinner for a replan that is still running after about 10 seconds.
    /// The "Replanning for …" label is already up; this is the extra progress.
    nonisolated static let replanProgressDelay: Duration = .seconds(10)

    nonisolated static func shouldShowReplanProgress(
        elapsed: Duration,
        threshold: Duration = replanProgressDelay
    ) -> Bool {
        elapsed >= threshold
    }

    /// True while a replacement line is in flight and a line is already drawn.
    var dimsRouteLine: Bool {
        Self.shouldDimExistingLine(isCalculating: isCalculating, hasLegs: !legs.isEmpty)
    }

    /// Set after `replanProgressDelay` if that same replan is still running.
    private(set) var showsReplanProgress = false

    /// Step text under the spinner once a replan has run long enough.
    private(set) var replanStepDetail: String?

    private var replanProgressTask: Task<Void, Never>?

    private func noteReplanIfStillRunning(generation: Int) async {
        let waited = await Self.pauseForReplanProgress()
        guard waited,
              Self.shouldShowReplanProgress(elapsed: Self.replanProgressDelay),
              generation == calculatingGeneration,
              isCalculating
        else { return }
        showsReplanProgress = true
    }

    private static func pauseForReplanProgress() async -> Bool {
        do {
            try await Task.sleep(for: replanProgressDelay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// Picks which of MapKit's returned routes to use for a leg. For scenic
    /// rides we prefer a route that avoids highways, and among those the longest
    /// — back-roads detours tend to be the more scenic option. Otherwise we take
    /// MapKit's top recommendation. Twisty does not use this; it scores
    /// curvature in `twistyLeg`.
    nonisolated static func preferredRoute(from routes: [MKRoute], style: RouteStyle) -> MKRoute? {
        guard style.prefersAlternates else { return routes.first }
        let withoutHighways = routes.filter { !$0.hasHighways }
        let candidates = withoutHighways.isEmpty ? routes : withoutHighways
        return candidates.max(by: { $0.distance < $1.distance }) ?? routes.first
    }

    /// Honest copy when Twisty had to keep Fastest's geometry. `nil` when
    /// every leg found a curvier corridor, or when no leg was missed.
    nonisolated static func twistyLimitationNote(missedLegs: Int, totalLegs: Int) -> String? {
        guard missedLegs > 0, totalLegs > 0 else { return nil }
        if missedLegs >= totalLegs {
            return "No twistier roads found on this route"
        }
        return "Part of this ride stayed on the fastest roads — MapKit didn't offer a curvier corridor there."
    }

    private func failRoute(between origin: Waypoint, and destination: Waypoint) {
        errorMessage = "No route found between \(origin.name) and \(destination.name)."
        legs = []
        twistyLimitationNote = nil
        clearStopRecommendations()
    }

    /// One or more `MKRoute`s for a Twisty leg. May be a single MapKit
    /// alternate or a stitch through an offset corridor. Downstream fuel,
    /// food, highlights, and the map all read `legs`, so the chosen geometry
    /// is the plan — the style is not swapped back to Fastest.
    ///
    /// Fastest alternates, avoid-highway alternates, and both offset-via
    /// sides start together. Each via side's segments run together too.
    /// A cached Fastest leg is the baseline so that request is not repeated.
    private func twistyLeg(
        from origin: Waypoint,
        to destination: Waypoint,
        avoidHighwayAlternates: Bool,
        probeOffsetVias: Bool,
        cachedFastest: [MKRoute]?
    ) async throws -> (routes: [MKRoute], usedFastestFallback: Bool) {
        // Alternates and offset-via probes start together. A cached Fastest
        // leg is the baseline, so the probes do not wait for that request
        // to be made again. A style change cancels this task; the probe
        // task is cancelled with it and its result is not published.
        let viaTask: Task<[[MKRoute]], Never>? = probeOffsetVias
            ? Task { @MainActor in
                await self.viaCorridors(
                    from: origin.coordinate,
                    to: destination.coordinate
                )
            }
            : nil
        defer { viaTask?.cancel() }

        let direct: [MKRoute]
        let avoided: [MKRoute]
        if avoidHighwayAlternates {
            async let directTask = calculateRoutes(
                from: origin.coordinate,
                to: destination.coordinate,
                avoidsHighways: false,
                avoidsTolls: false,
                alternates: true
            )
            async let avoidedTask = calculateRoutes(
                from: origin.coordinate,
                to: destination.coordinate,
                avoidsHighways: true,
                avoidsTolls: false,
                alternates: true
            )
            do {
                direct = try await directTask
            } catch {
                _ = try? await avoidedTask
                throw error
            }
            avoided = (try? await avoidedTask) ?? []
        } else {
            direct = try await calculateRoutes(
                from: origin.coordinate,
                to: destination.coordinate,
                avoidsHighways: false,
                avoidsTolls: false,
                alternates: true
            )
            avoided = []
        }
        guard !Task.isCancelled else { throw CancellationError() }
        let baseline = direct.first ?? cachedFastest?.first
        guard let baseline else { return ([], false) }

        var pool: [TwistyPoolEntry] = []
        func append(_ routes: [MKRoute]) {
            pool.append(TwistyPoolEntry(
                id: pool.count,
                routes: routes,
                coordinates: Self.joinedCoordinates(routes),
                distance: routes.reduce(0) { $0 + $1.distance }
            ))
        }
        if direct.isEmpty, let cachedFastest, !cachedFastest.isEmpty {
            append(cachedFastest)
        }
        for route in direct {
            append([route])
        }
        let fastestID = 0

        // Non-highway alternates are candidates, not the decision. Scenic
        // would keep the longest of these; Twisty only keeps one if it is
        // actually curvier than Fastest.
        for route in avoided {
            append([route])
        }

        if let chosen = Self.chosenTwisty(in: pool, fastestID: fastestID) {
            return (chosen, false)
        }
        guard probeOffsetVias, let viaTask else { return ([baseline], true) }
        guard !Task.isCancelled else { throw CancellationError() }

        for stitched in await viaTask.value {
            guard !Task.isCancelled else { throw CancellationError() }
            append(stitched)
            if let chosen = Self.chosenTwisty(in: pool, fastestID: fastestID) {
                return (chosen, false)
            }
        }

        return ([baseline], true)
    }

    /// Both offset sides at once. Each side's segments also run together.
    /// Empty when the task was cancelled or MapKit returned nothing.
    private func viaCorridors(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async -> [[MKRoute]] {
        let corridors = TwistyRouting.biasCorridors(from: origin, to: destination)
        guard !corridors.isEmpty, !Task.isCancelled else { return [] }
        if corridors.count == 1 {
            guard let stitched = try? await routeThrough(
                vias: corridors[0].vias,
                from: origin,
                to: destination
            ) else { return [] }
            return [stitched]
        }
        async let left = routeThrough(
            vias: corridors[0].vias,
            from: origin,
            to: destination
        )
        async let right = routeThrough(
            vias: corridors[1].vias,
            from: origin,
            to: destination
        )
        let first = try? await left
        let second = try? await right
        return [first, second].compactMap { $0 }
    }

    /// Routes A → vias → B with ordinary driving preference (highways allowed).
    /// The segments are independent requests, so they run together. The vias
    /// are what leave the fast corridor; curvature scoring decides whether
    /// the resulting roads are actually twistier.
    private func routeThrough(
        vias: [CLLocationCoordinate2D],
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D
    ) async throws -> [MKRoute]? {
        let targets = vias + [destination]
        guard !targets.isEmpty else { return nil }
        var anchors = [origin]
        anchors.append(contentsOf: targets)

        func piece(_ index: Int) async throws -> MKRoute? {
            guard !Task.isCancelled else { throw CancellationError() }
            let routes = try await calculateRoutes(
                from: anchors[index],
                to: anchors[index + 1],
                avoidsHighways: false,
                avoidsTolls: false,
                alternates: false
            )
            guard !Task.isCancelled else { throw CancellationError() }
            return routes.first
        }

        let segmentCount = anchors.count - 1
        let segments: [MKRoute?]
        switch segmentCount {
        case 1:
            segments = [try await piece(0)]
        case 2:
            async let first = piece(0)
            async let second = piece(1)
            segments = [try await first, try await second]
        case 3:
            async let first = piece(0)
            async let second = piece(1)
            async let third = piece(2)
            segments = [try await first, try await second, try await third]
        default:
            var sequential: [MKRoute?] = []
            for index in 0..<segmentCount {
                sequential.append(try await piece(index))
            }
            segments = sequential
        }
        guard segments.allSatisfy({ $0 != nil }) else { return nil }
        return segments.compactMap { $0 }
    }

    private func calculateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        avoidsHighways: Bool,
        avoidsTolls: Bool,
        alternates: Bool
    ) async throws -> [MKRoute] {
        guard origin.isValidLocation, destination.isValidLocation else { return [] }
        return try await directionsProvider.calculateRoutes(
            from: origin,
            to: destination,
            avoidsHighways: avoidsHighways,
            avoidsTolls: avoidsTolls,
            alternates: alternates,
            departure: effectiveDeparture
        )
    }

    /// Corridor search. UI tests skip `MKLocalSearch` and project canned
    /// pumps onto the stub polyline. Live planning keeps `StopSuggestionService`.
    private func searchStops(
        category: StopCategory,
        alongLegs legs: [MKRoute],
        sampleDistances: [CLLocationDistance]? = nil,
        corridorRadiusMeters: CLLocationDistance? = nil,
        generation: Int = 0,
        maxSearches: Int? = nil
    ) async -> CorridorSearchResult {
        // Copy the polyline before the search hops off the main actor.
        // `MKPolyline` reads from that hop can be empty, and every stop
        // then stores 0 m ("~0 ft from start").
        let routePolylines = suggestionRoutePolylines
        if let stopSearchOverride {
            return await stopSearchOverride.findStops(
                category: category,
                alongLegs: legs,
                sampleDistances: sampleDistances,
                corridorRadiusMeters: corridorRadiusMeters,
                generation: generation
            )
        }
        var service = suggestionService
        if let maxSearches {
            service.maxSearches = maxSearches
        }
        return await service.findStops(
            category: category,
            alongLegs: legs,
            sampleDistances: sampleDistances,
            corridorRadiusMeters: corridorRadiusMeters,
            generation: generation,
            routePolylines: routePolylines
        )
    }

    private func searchFood(
        near coordinate: CLLocationCoordinate2D,
        alongPolylines legPolylines: [[CLLocationCoordinate2D]]
    ) async -> [SuggestedStop] {
        if let stopSearchOverride {
            return await stopSearchOverride.findFood(
                near: coordinate,
                alongPolylines: legPolylines
            )
        }
        return await suggestionService.findFood(
            near: coordinate,
            alongPolylines: legPolylines
        )
    }

    private static func chosenTwisty(in pool: [TwistyPoolEntry], fastestID: Int) -> [MKRoute]? {
        let selection = TwistyRouting.select(
            candidates: pool.map {
                TwistyRouteCandidate(id: $0.id, coordinates: $0.coordinates, distance: $0.distance)
            },
            fastestID: fastestID
        )
        guard let selection else { return nil }
        return pool.first { $0.id == selection.candidateID }?.routes
    }

    private static func joinedCoordinates(_ routes: [MKRoute]) -> [CLLocationCoordinate2D] {
        var coordinates: [CLLocationCoordinate2D] = []
        for route in routes {
            var leg = RouteGeometry.coordinates(of: route.polyline)
            if let last = coordinates.last, let first = leg.first {
                let gap = CLLocation(latitude: last.latitude, longitude: last.longitude)
                    .distance(from: CLLocation(latitude: first.latitude, longitude: first.longitude))
                if gap < 40 {
                    leg.removeFirst()
                }
            }
            coordinates.append(contentsOf: leg)
        }
        return coordinates
    }

    // MARK: - Weather

    /// Checks the route for rain at the rider's expected time of passing.
    /// Degrades silently (no warning, no spinner) if WeatherKit is unavailable.
    func refreshWeather(generation: Int) async {
        guard !legs.isEmpty else {
            guard generation == weatherGeneration else { return }
            rainForecast = nil
            await weatherNotifier.updateRainWarning(nil)
            return
        }
        guard RouteWeatherService.isEnabled else {
            guard generation == weatherGeneration else { return }
            rainForecast = nil
            await weatherNotifier.updateRainWarning(nil)
            return
        }
        isCheckingWeather = true
        defer {
            if generation == weatherGeneration {
                isCheckingWeather = false
            }
        }
        let forecast = await weatherService.rainForecast(alongLegs: legs, departure: effectiveDeparture)
        guard !Task.isCancelled, generation == weatherGeneration else { return }
        rainForecast = forecast
        // Surface the same warning shown on screen as a local notification so
        // the rider is alerted even if they've stopped looking at the app.
        await weatherNotifier.updateRainWarning(rainWarning)
    }

    // MARK: - Gas stations & automatic fuel planning

    /// Clears every route-derived stop recommendation, so a cleared or failed
    /// route doesn't leave stale pins and rows behind.
    private func clearStopRecommendations() {
        gasStations = []
        travelSideGasStations = []
        gasStopsWithFood = []
        fuelFoodStops = []
        mutateFuelList {
            fuelStops = []
            fuelPlanEntries = []
            hasFuelGap = false
        }
        pairedFuelStopIDs = []
        highlightGeneration += 1
        rideHighlights = []
        isShowingAllGasOnRoute = false
        // A cleared route did not finish a gas search. Leaving `.empty` would
        // say "no gas stations" for a route that never got one, and a leftover
        // gap flag would warn about a route that no longer exists.
        gasLoadState = .pending
        invalidateFuelCoverage()
    }

    /// Finds every gas station along the route (independent of the selected
    /// category) so the rider can pick any of them, then plans which ones to
    /// recommend as fuel stops.
    ///
    /// `generation` is captured by the caller before this function's first
    /// await and checked again immediately before any write.
    ///
    /// On 628dbf0 the replacement search (fuel slider released after geometry
    /// had already cleared `isCalculating`) was the current owner and was not
    /// cancelled, so it was allowed to publish. Its `[]` was every corridor
    /// sample failing — MapKit still finishing the cancelled task's queries and
    /// answering the new ones with `loadingThrottled` — and `findStops` used
    /// that same `[]` for a finished search that found nothing. Only a
    /// `.completed` result with zero stops may become `.empty`. A throttled or
    /// otherwise failed run is `.failed` ("Couldn't load gas — tap to retry").
    /// A superseded run writes nothing.
    func refreshGasStations(generation: Int) async {
        guard gasSearchStillOwns(generation) else {
            gasLog.info("drop gen=\(generation, privacy: .public) current=\(self.gasGeneration, privacy: .public) reason=not-owner-before-start")
            return
        }
        guard !legs.isEmpty else {
            gasLog.info("drop gen=\(generation, privacy: .public) reason=no-legs")
            if gasSearchStillOwns(generation) {
                isSearchingGas = false
            }
            return
        }

        // Tank-interval gas search. Do not also sweep food here — that burned
        // the MKLocalSearch budget on a long interstate before later samples
        // ran, leaving fuel stops empty even when pumps exist. Food is paired
        // after a recommendation exists.
        isSearchingGas = true
        gasLoadState = .pending
        defer {
            if generation == gasGeneration {
                isSearchingGas = false
            }
        }

        let legsAtSearch = legs
        // Coarse comfort edges first, then densify only a gap still wider
        // than the reserve. A full 25-mile grid is ~110 lookups and MapKit
        // throttles the middle of the ride.
        let result = await searchFuelAdaptively(generation: generation, legs: legsAtSearch)
        guard let result else {
            // A superseded run already lost ownership inside the search and
            // must not write. Still owning with no result means the retry
            // wait ended the run — retry, not a spinner stuck on `.pending`.
            guard gasSearchStillOwns(generation) else { return }
            gasLoadState = .failed
            invalidateFuelCoverage()
            gasLog.info("publish gen=\(generation, privacy: .public) decision=failed reason=no-result stops=0")
            gasLog.info("fuel gap gen=\(generation, privacy: .public) planGap=false trusted=false show=false reason=search-failed")
            return
        }
        // Re-read the owner immediately before writing. No await between
        // this check and the publishes below.
        let decision = GasPublish.decide(
            generation: generation,
            currentGeneration: gasGeneration,
            taskCancelled: Task.isCancelled,
            status: result.status,
            stopCount: result.stops.count
        )
        gasLog.info("publish gen=\(generation, privacy: .public) decision=\(decision.logName, privacy: .public) stops=\(result.stops.count, privacy: .public) ok=\(result.succeeded, privacy: .public) failed=\(result.failed, privacy: .public) throttled=\(result.throttled, privacy: .public)")
        guard gasSearchStillOwns(generation) else { return }
        switch decision {
        case .drop:
            return
        case .failed:
            gasLoadState = .failed
            invalidateFuelCoverage()
            gasLog.info("fuel gap gen=\(generation, privacy: .public) planGap=false trusted=false show=false reason=search-failed")
        case .empty:
            gasCoverageTrusted = Self.gasCoverageIsTrusted(
                status: result.status,
                failed: result.failed,
                throttled: result.throttled
            )
            unsearchedFuelDistances = result.failedSampleDistances
            gasStations = []
            gasStopsWithFood = []
            applyFuelCandidatePool()
            gasLoadState = gasStations.isEmpty ? .empty : .loaded
            await refreshFoodNearFuelStops()
        case .loaded:
            gasCoverageTrusted = Self.gasCoverageIsTrusted(
                status: result.status,
                failed: result.failed,
                throttled: result.throttled
            )
            unsearchedFuelDistances = result.failedSampleDistances
            gasStations = result.stops
            gasStopsWithFood = []
            applyFuelCandidatePool()
            gasLoadState = gasStations.isEmpty ? .empty : .loaded
            await refreshFoodNearFuelStops()
        }
    }

    /// Comfort-edge search, a retry of any sample that never returned, then
    /// at most two densify passes where known stations are still farther
    /// apart than the reserve. A failed sample is left unsearched so the
    /// planner does not hop across it.
    private func searchFuelAdaptively(
        generation: Int,
        legs: [MKRoute]
    ) async -> CorridorSearchResult? {
        let coarse = Self.fuelSearchDistances(
            totalDistance: totalDistanceMeters,
            range: fuelRangeMeters
        )
        guard var result = await runGasCorridorSearch(
            generation: generation,
            sampleDistances: coarse,
            legs: legs
        ) else { return nil }

        if !result.failedSampleDistances.isEmpty {
            let missed = result.failedSampleDistances
            guard let retry = await runGasCorridorSearch(
                generation: generation,
                sampleDistances: missed,
                legs: legs
            ) else { return nil }
            result = Self.mergedCorridorSearch(result, with: retry, retried: missed)
        }

        let limit = fuelRangeMeters * Self.fuelSafetyFactor
        var searched = coarse
        for _ in 0..<2 {
            let dense = Self.fuelDensifySearchDistances(
                totalDistance: totalDistanceMeters,
                limit: limit,
                stationDistances: result.stops.map(\.distanceAlongRoute),
                alreadySearched: searched,
                unsearched: result.failedSampleDistances
            )
            if dense.isEmpty { break }
            guard let more = await runGasCorridorSearch(
                generation: generation,
                sampleDistances: dense,
                legs: legs
            ) else { return nil }
            result = Self.mergedCorridorSearch(result, with: more, retried: [])
            searched.append(contentsOf: dense)
            if !more.failedSampleDistances.isEmpty { break }
        }
        return result
    }

    /// Unions two corridor passes. A retried sample that comes back is no
    /// longer an unsearched mile. Stations from either pass stay.
    nonisolated static func mergedCorridorSearch(
        _ base: CorridorSearchResult,
        with next: CorridorSearchResult,
        retried: [CLLocationDistance]
    ) -> CorridorSearchResult {
        if base.status == .cancelled || next.status == .cancelled {
            return CorridorSearchResult(
                stops: [],
                status: .cancelled,
                succeeded: base.succeeded + next.succeeded,
                failed: base.failed + next.failed,
                throttled: base.throttled + next.throttled,
                failedSampleDistances: []
            )
        }
        let stops = mergedGasCandidates([base.stops, next.stops])
        var unresolved = base.failedSampleDistances.filter { sample in
            let wasRetried = retried.contains { abs($0 - sample) < 1 }
            if !wasRetried { return true }
            return next.failedSampleDistances.contains { abs($0 - sample) < 1 }
        }
        for sample in next.failedSampleDistances where !unresolved.contains(where: { abs($0 - sample) < 1 }) {
            unresolved.append(sample)
        }
        let succeeded = base.succeeded + next.succeeded
        var tally = GasSampleTally(succeeded: succeeded, throttled: unresolved.count)
        // A pass that returned stations is a result even if the counter was
        // zero. A fully searched corridor with no stations is empty, not failed.
        if tally.succeeded == 0, !stops.isEmpty || unresolved.isEmpty {
            tally.succeeded = 1
        }
        let status = GasSearchStatus.resolve(tally, stopCount: stops.count)
        return CorridorSearchResult(
            stops: status == .completed ? stops : [],
            status: status,
            succeeded: succeeded,
            failed: 0,
            throttled: unresolved.count,
            failedSampleDistances: unresolved
        )
    }

    /// Runs the corridor search, and if every sample failed, waits and tries
    /// once more — unless this generation was cancelled in the meantime.
    /// Returns nil when this run must not publish (superseded or cancelled).
    private func runGasCorridorSearch(
        generation: Int,
        sampleDistances: [CLLocationDistance],
        legs: [MKRoute]
    ) async -> CorridorSearchResult? {
        let attempts = 2
        var latest: CorridorSearchResult?
        for attempt in 0..<attempts {
            if attempt > 0 {
                gasLog.info("backoff gen=\(generation, privacy: .public) attempt=\(attempt, privacy: .public)")
                let waited = await Self.pauseForGasRetry()
                if !waited || !gasSearchStillOwns(generation) {
                    gasLog.info("drop gen=\(generation, privacy: .public) reason=backoff-cancelled")
                    return nil
                }
            }
            guard gasSearchStillOwns(generation) else {
                gasLog.info("drop gen=\(generation, privacy: .public) current=\(self.gasGeneration, privacy: .public) reason=not-owner")
                return nil
            }
            gasLog.info("search start gen=\(generation, privacy: .public) attempt=\(attempt, privacy: .public) samples=\(sampleDistances.count, privacy: .public)")
            let result = await searchStops(
                category: .gas,
                alongLegs: legs,
                sampleDistances: sampleDistances,
                corridorRadiusMeters: Self.fuelSearchCorridorMeters,
                generation: generation
            )
            latest = result
            gasLog.info("search end gen=\(generation, privacy: .public) status=\(String(describing: result.status), privacy: .public) stops=\(result.stops.count, privacy: .public) ok=\(result.succeeded, privacy: .public) failed=\(result.failed, privacy: .public) throttled=\(result.throttled, privacy: .public)")
            if result.status != .failed { break }
        }
        guard gasSearchStillOwns(generation) else {
            gasLog.info("drop gen=\(generation, privacy: .public) current=\(self.gasGeneration, privacy: .public) reason=not-owner-after-search")
            return nil
        }
        return latest
    }

    /// Exhaustive catch: `Task.sleep` can throw, and this function does not.
    /// `false` means the retry was cancelled and the caller must publish nothing.
    private static func pauseForGasRetry() async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(1200))
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    /// Merges every gas list we already have, prefers travel-side pumps, and
    /// falls back to the full list so an interstate filter cannot zero out recs.
    func applyFuelCandidatePool() {
        let extraGas = suggestedStops.filter { $0.category == .gas }
        gasStations = Self.mergedGasCandidates([gasStations, extraGas])
        let travelSide = travelSideStations(from: gasStations)
        travelSideGasStations = Self.preferredFuelPool(from: gasStations, travelSide: travelSide)
        // A finished empty corridor can gain chip hits afterwards. Those
        // stations are a real list, so the sheet must not keep saying none.
        if gasLoadState == .empty, !gasStations.isEmpty {
            gasLoadState = .loaded
        }
        replanFuelStops()
    }

    /// De-duplicates gas stops by name + rounded coordinate.
    nonisolated static func mergedGasCandidates(_ lists: [[SuggestedStop]]) -> [SuggestedStop] {
        var seen = Set<String>()
        var merged: [SuggestedStop] = []
        for stop in lists.flatMap({ $0 }) {
            let coord = stop.coordinate
            let key = "\(stop.name)|\(round(coord.latitude * 1000))|\(round(coord.longitude * 1000))"
            guard seen.insert(key).inserted else { continue }
            merged.append(stop)
        }
        return merged.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
    }

    /// Travel-side pumps when any exist; otherwise the unfiltered list so a
    /// long divided-highway ride still gets tank-interval recommendations.
    nonisolated static func preferredFuelPool(
        from stations: [SuggestedStop],
        travelSide: [SuggestedStop]
    ) -> [SuggestedStop] {
        travelSide.isEmpty ? stations : travelSide
    }

    /// True when the published fuel list still has a pump to add and this
    /// tap is not replanning from the station pool.
    private nonisolated static func hasSelectableFuel(_ input: FuelSelectionInput) -> Bool {
        let onRoute = Set(input.waypoints.map(\.key))
        return input.existingFuelStops.contains { stop in
            stop.isGas
                && !input.pastRangeIDs.contains(stop.id)
                && !input.pastRangeKeys.contains(stop.key)
                && !onRoute.contains(stop.key)
        }
    }

    /// Travel side, fuel plan, within-tank filter, distances, and the
    /// waypoint order. The polyline is measured once. Nothing here is
    /// isolated to the main actor.
    private nonisolated static func computeFuelSelection(
        _ input: FuelSelectionInput
    ) -> FuelSelectionOutput {
        let route: RouteGeometry.MeasuredRoute? = input.polylines.contains(where: { $0.count > 1 })
            ? RouteGeometry.MeasuredRoute(polylines: input.polylines)
            : nil
        var distances: [UUID: CLLocationDistance] = [:]
        distances.reserveCapacity(input.queries.count)
        for query in input.queries {
            distances[query.id] = projectedDistance(
                latitude: query.latitude,
                longitude: query.longitude,
                known: query.known,
                on: route
            )
        }

        var stationByID: [UUID: FuelSelectionStation] = [:]
        for station in input.stations {
            stationByID[station.id] = station
        }
        for stop in input.existingFuelStops where stationByID[stop.id] == nil {
            stationByID[stop.id] = stop
        }
        func cached(_ station: FuelSelectionStation) -> CLLocationDistance {
            distances[station.id] ?? station.distance
        }

        let preKeys = Set(input.waypoints.map(\.key))
        var pool = input.stations
        var draft = FuelPlanDraft(recommendedIDs: [], entries: [], hasGap: false)
        var chosen: [FuelSelectionStation] = []

        if input.replan {
            if let route {
                let travel = input.stations.filter { station in
                    let coordinate = CLLocationCoordinate2D(
                        latitude: station.latitude,
                        longitude: station.longitude
                    )
                    return RouteGeometry.isOnTravelSide(
                        coordinate,
                        on: route,
                        drivesOnRight: input.drivesOnRight
                    )
                }
                pool = travel.isEmpty ? input.stations : travel
            }
            draft = fuelPlanDraft(
                from: pool.map {
                    FuelCandidate(
                        id: $0.id,
                        distanceAlongRoute: $0.distance,
                        detourMeters: $0.detour
                    )
                },
                totalDistance: input.totalDistance,
                range: input.tank,
                filledAt: plannedFillDistances(input, distances: distances),
                preferringFoodAt: input.foodIDs,
                departure: input.departure,
                totalTravelTime: input.totalTravelTime,
                unsearched: input.unsearched
            )
            var pastIDs = Set<UUID>()
            var pastKeys = Set<String>()
            for entry in draft.entries {
                guard case .pastRange(let id) = entry else { continue }
                pastIDs.insert(id)
                if let key = stationByID[id]?.key {
                    pastKeys.insert(key)
                }
            }
            let recommended = draft.recommendedIDs.compactMap { stationByID[$0] }
            let selectable = recommended.filter { station in
                station.isGas
                    && !pastIDs.contains(station.id)
                    && !pastKeys.contains(station.key)
                    && !preKeys.contains(station.key)
            }
            let anchors = selectionAnchors(
                input: input,
                distances: distances,
                keys: preKeys,
                extra: recommended
            )
            let reachable = reachableStopIDs(
                candidates: selectable.map { TankCandidate(id: $0.id, distance: cached($0)) },
                onRoute: anchors,
                tank: input.tank
            )
            for station in selectable.sorted(by: { cached($0) < cached($1) }) {
                guard reachable.contains(station.id) else { break }
                chosen.append(station)
            }
        } else {
            let selectable = input.existingFuelStops.filter { station in
                station.isGas
                    && !input.pastRangeIDs.contains(station.id)
                    && !input.pastRangeKeys.contains(station.key)
                    && !preKeys.contains(station.key)
            }
            chosen = selectable.sorted { cached($0) < cached($1) }
        }

        let placements = placedSelections(chosen, on: input, route: route)
        let hasInserts = placements.contains { placement in
            if case .insert = placement { return true }
            return false
        }
        let clearFuel = hasInserts && input.hasLegs
        var postKeys = Set<String>()
        if hasInserts {
            for placement in placements {
                switch placement {
                case .keep(let id):
                    if let waypoint = input.waypoints.first(where: { $0.id == id }) {
                        postKeys.insert(waypoint.key)
                    }
                case .insert(let id):
                    if let station = stationByID[id] {
                        postKeys.insert(station.key)
                    }
                }
            }
        } else {
            postKeys = preKeys
        }

        var kept: [UUID] = []
        if hasInserts {
            let insertedKeys = Set(chosen.map(\.key))
            for stop in input.buffered {
                if insertedKeys.contains(stop.key) || postKeys.contains(stop.key) {
                    continue
                }
                kept.append(stop.id)
            }
        }

        let remaining: [FuelSelectionStation]
        if clearFuel {
            remaining = []
        } else if input.replan {
            remaining = draft.recommendedIDs.compactMap { stationByID[$0] }
        } else {
            remaining = input.existingFuelStops
        }
        let rows: [FuelPlanRow]
        if clearFuel {
            rows = []
        } else if input.replan {
            rows = draftRows(draft, stations: stationByID, distances: distances)
        } else {
            rows = input.existingRows.map { row in
                guard row.kind != .gap, let distance = distances[row.stopID] else { return row }
                var copy = row
                copy.distance = distance
                return copy
            }
        }
        let anchors = publishedFillDistances(
            input: input,
            distances: distances,
            postKeys: postKeys,
            chosen: hasInserts ? chosen : [],
            remaining: remaining
        )
        let snapshot = fuelPlanSnapshot(FuelPlanInputs(
            rows: rows,
            onRouteKeys: postKeys,
            onRouteGasDistances: anchors,
            showsGap: hasInserts ? false : input.showsGap,
            tank: input.tank
        ))
        let visibleIDs = clearFuel ? [] : snapshot.visibleEntryIDs
        let labels = Self.fuelLabels(
            for: visibleIDs,
            rows: rows,
            stations: stationByID,
            distances: distances,
            anchors: anchors,
            legs: input.driveLegs,
            checkedIDs: Set(kept),
            usesMetric: input.usesMetric
        )
        return FuelSelectionOutput(
            didReplan: input.replan,
            hasInserts: hasInserts,
            clearFuel: clearFuel,
            poolIDs: pool.map(\.id),
            recommendedIDs: draft.recommendedIDs,
            draft: draft,
            placements: hasInserts ? placements : [],
            keptBufferedIDs: kept,
            distances: distances,
            onRouteKeys: postKeys,
            fuelPlanKeys: clearFuel ? [] : snapshot.fuelPlanKeys,
            onRouteGasDistances: anchors,
            visibleEntryIDs: visibleIDs,
            planHasGap: draft.hasGap,
            labels: labels
        )
    }

    /// Labels for the visible fuel rows, from the sendable plan. Runs with
    /// the rest of the selection, off the main actor.
    private nonisolated static func fuelLabels(
        for visibleIDs: [String],
        rows: [FuelPlanRow],
        stations: [UUID: FuelSelectionStation],
        distances: [UUID: CLLocationDistance],
        anchors: [CLLocationDistance],
        legs: [FuelStopRidingTime.Leg],
        checkedIDs: Set<UUID>,
        usesMetric: Bool
    ) -> FuelRowLabelSet {
        var byEntry: [String: FuelPlanRow] = [:]
        for row in rows {
            byEntry[row.entryID] = row
        }
        var recommended: [(id: UUID, name: String, key: String, distance: CLLocationDistance)] = []
        var pastRange: [(id: UUID, name: String, key: String, distance: CLLocationDistance)] = []
        for entryID in visibleIDs {
            guard let row = byEntry[entryID], let station = stations[row.stopID] else { continue }
            let distance = distances[row.stopID] ?? station.distance
            let item = (id: station.id, name: station.name, key: station.key, distance: distance)
            switch row.kind {
            case .recommended:
                recommended.append(item)
            case .pastRange:
                pastRange.append(item)
            case .gap:
                break
            }
        }
        return fuelRowLabels(
            recommended: recommended,
            pastRange: pastRange,
            anchors: anchors,
            legs: legs,
            checkedIDs: checkedIDs,
            usesMetric: usesMetric
        )
    }

    private nonisolated static func projectedDistance(
        latitude: Double,
        longitude: Double,
        known: CLLocationDistance,
        on route: RouteGeometry.MeasuredRoute?
    ) -> CLLocationDistance {
        guard let route else { return known }
        let projected = RouteGeometry.distanceAlongRoute(
            of: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            on: route
        )
        return RouteGeometry.preferredDistanceAlongRoute(projected: projected, known: known)
    }

    /// Gas-fill waypoints the planner treats as already filled. Missing
    /// cache entries are 0, matching `gasFillDistances`.
    private nonisolated static func plannedFillDistances(
        _ input: FuelSelectionInput,
        distances: [UUID: CLLocationDistance]
    ) -> [CLLocationDistance] {
        guard input.countsGasFills else { return [] }
        return input.waypoints.compactMap { waypoint in
            guard waypoint.isGasFill else { return nil }
            return distances[waypoint.id] ?? 0
        }
    }

    /// Anchors for the within-tank walk: fills already on the route, plus
    /// any newly planned stop that sits on a waypoint.
    private nonisolated static func selectionAnchors(
        input: FuelSelectionInput,
        distances: [UUID: CLLocationDistance],
        keys: Set<String>,
        extra: [FuelSelectionStation]
    ) -> [CLLocationDistance] {
        var anchors = plannedFillDistances(input, distances: distances)
        func append(_ station: FuelSelectionStation) {
            guard keys.contains(station.key) else { return }
            anchors.append(distances[station.id] ?? station.distance)
        }
        for station in input.stations {
            append(station)
        }
        for stop in extra {
            append(stop)
        }
        return anchors
    }

    /// Mile marks stored with the fuel snapshot after the insert.
    private nonisolated static func publishedFillDistances(
        input: FuelSelectionInput,
        distances: [UUID: CLLocationDistance],
        postKeys: Set<String>,
        chosen: [FuelSelectionStation],
        remaining: [FuelSelectionStation]
    ) -> [CLLocationDistance] {
        var anchors = plannedFillDistances(input, distances: distances)
        if input.countsGasFills {
            for station in chosen {
                anchors.append(distances[station.id] ?? station.distance)
            }
        }
        for station in input.stations where postKeys.contains(station.key) {
            anchors.append(distances[station.id] ?? station.distance)
        }
        for stop in remaining where postKeys.contains(stop.key) {
            anchors.append(distances[stop.id] ?? stop.distance)
        }
        return anchors
    }

    /// Ride order for one assignment. Middle waypoints share one measurement.
    private nonisolated static func placedSelections(
        _ chosen: [FuelSelectionStation],
        on input: FuelSelectionInput,
        route: RouteGeometry.MeasuredRoute?
    ) -> [FuelPlacement] {
        let waypoints = input.waypoints
        guard waypoints.count >= 2 else {
            var occupied = Set(waypoints.map(\.key))
            var placements = waypoints.map { FuelPlacement.keep($0.id) }
            for station in chosen.sorted(by: { $0.distance < $1.distance }) {
                guard occupied.insert(station.key).inserted else { continue }
                placements.append(.insert(station.id))
            }
            return placements
        }
        var placed: [(distance: CLLocationDistance, placement: FuelPlacement)] = []
        for (index, waypoint) in waypoints.enumerated() {
            let distance: CLLocationDistance
            if index == 0 {
                distance = 0
            } else if index == waypoints.count - 1 {
                distance = .greatestFiniteMagnitude
            } else if let route {
                distance = RouteGeometry.distanceAlongRoute(
                    of: CLLocationCoordinate2D(
                        latitude: waypoint.latitude,
                        longitude: waypoint.longitude
                    ),
                    on: route
                )
            } else if input.polylines.isEmpty {
                distance = input.totalDistance * Double(index) / Double(max(waypoints.count, 1))
            } else {
                distance = 0
            }
            placed.append((distance, .keep(waypoint.id)))
        }
        var occupied = Set(waypoints.map(\.key))
        for station in chosen.sorted(by: { $0.distance < $1.distance }) {
            guard occupied.insert(station.key).inserted else { continue }
            let index = placed.firstIndex { $0.distance > station.distance } ?? placed.count
            placed.insert((station.distance, .insert(station.id)), at: index)
        }
        return placed.map(\.placement)
    }

    private nonisolated static func draftRows(
        _ draft: FuelPlanDraft,
        stations: [UUID: FuelSelectionStation],
        distances: [UUID: CLLocationDistance]
    ) -> [FuelPlanRow] {
        draft.entries.compactMap { entry in
            switch entry {
            case .recommended(let id):
                guard let station = stations[id] else { return nil }
                return FuelPlanRow(
                    entryID: "rec-\(id.uuidString)",
                    stopID: id,
                    key: station.key,
                    distance: distances[id] ?? station.distance,
                    kind: .recommended
                )
            case .pastRange(let id):
                guard let station = stations[id] else { return nil }
                return FuelPlanRow(
                    entryID: "past-\(id.uuidString)",
                    stopID: id,
                    key: station.key,
                    distance: distances[id] ?? station.distance,
                    kind: .pastRange
                )
            case .gap(let from, let to, _):
                return FuelPlanRow(
                    entryID: "gap-\(Int(from.rounded()))-\(Int(to.rounded()))",
                    stopID: UUID(),
                    key: "",
                    distance: 0,
                    kind: .gap
                )
            }
        }
    }

    /// Stations on the rider's side of the current line. The polyline is
    /// copied on the caller, then the scan runs off the main thread.
    private func travelSideStations(from stations: [SuggestedStop]) -> [SuggestedStop] {
        guard !stations.isEmpty else { return [] }
        let polylines = legs.map { RouteGeometry.coordinates(of: $0.polyline) }
        guard polylines.contains(where: { $0.count > 1 }) else { return stations }
        let queries = stations.enumerated().map { index, stop in
            RouteGeometry.StationProjectionQuery(
                index: index,
                latitude: stop.coordinate.latitude,
                longitude: stop.coordinate.longitude
            )
        }
        let indices = Self.travelSideIndicesOffMain(queries: queries, polylines: polylines)
        let keep = Set(indices)
        return stations.enumerated().compactMap { keep.contains($0.offset) ? $0.element : nil }
    }

    /// The scan is nonisolated and only receives sendable values, so it can
    /// run off the main actor without capturing the view model or map items.
    private nonisolated static func travelSideIndicesOffMain(
        queries: [RouteGeometry.StationProjectionQuery],
        polylines: [[CLLocationCoordinate2D]]
    ) -> [Int] {
        DispatchQueue.global(qos: .userInitiated).sync { @Sendable in
            RouteGeometry.travelSideIndices(queries: queries, polylines: polylines)
        }
    }

    /// Recommended stops the button may insert. Each hop is measured from
    /// the latest fuel the rider can already reach: the start, a pump
    /// already on the route, or a stop this tap is inserting. A search
    /// result is not flagged `isGasFill`, so the pump the rider already
    /// added still has to count — otherwise the next station is measured
    /// from the origin and dropped even when the leg after that pump fits
    /// in the tank. A station past the tank from every reachable fill stays
    /// off the route, including one planned on the far side of a dry gap.
    private func fuelStopsWithinTank(from stops: [SuggestedStop]) -> [SuggestedStop] {
        let candidates = stops.map { stop in
            TankCandidate(id: stop.id, distance: cachedDistance(for: stop))
        }
        let ids = Self.reachableStopIDs(
            candidates: candidates,
            onRoute: onRouteGasDistances,
            tank: fuelRangeMeters
        )
        var chosen: [SuggestedStop] = []
        for stop in stops.sorted(by: { cachedDistance(for: $0) < cachedDistance(for: $1) }) {
            guard ids.contains(stop.id) else { break }
            chosen.append(stop)
        }
        return chosen
    }

    /// Changes stops and entries together, then publishes one fuel list.
    /// Callers that already hold `suppressDistanceRebuild` still get a
    /// single snapshot when the outer batch ends.
    private func mutateFuelList(_ body: () -> Void) {
        fuelListMutationDepth += 1
        let wasSuppressed = suppressDistanceRebuild
        suppressDistanceRebuild = true
        body()
        suppressDistanceRebuild = wasSuppressed
        fuelListMutationDepth -= 1
        if fuelListMutationDepth == 0, !suppressDistanceRebuild {
            publishFuelPlanSnapshot()
        }
    }

    /// Stores the visible rows and their labels in one assignment. The mile
    /// marks were already measured. View bodies read this value and do not
    /// rebuild a caption per row.
    private func publishFuelPlanSnapshot() {
        guard fuelListMutationDepth == 0, !suppressDistanceRebuild else { return }
        let inputs = fuelPlanInputs()
        let snapshot = Self.fuelPlanSnapshot(inputs)
        onRouteCoordinateKeys = snapshot.onRouteKeys
        fuelPlanCoordinateKeys = snapshot.fuelPlanKeys
        onRouteGasDistances = snapshot.onRouteGasDistances
        let visible: [FuelPlanEntry]
        if snapshot.visibleEntryIDs.isEmpty {
            visible = []
        } else {
            var byID: [String: FuelPlanEntry] = [:]
            byID.reserveCapacity(fuelPlanEntries.count)
            for entry in fuelPlanEntries {
                byID[entry.id] = entry
            }
            visible = snapshot.visibleEntryIDs.compactMap { byID[$0] }
        }
        fuelListPresentation = FuelListPresentation(
            visibleEntries: visible,
            labels: labels(for: visible)
        )
    }

    /// Riding captions for the rows about to be shown. Formatting only —
    /// the mile marks are already measured.
    private func labels(for entries: [FuelPlanEntry]) -> FuelRowLabelSet {
        var recommended: [(id: UUID, name: String, key: String, distance: CLLocationDistance)] = []
        var pastRange: [(id: UUID, name: String, key: String, distance: CLLocationDistance)] = []
        for entry in entries {
            switch entry {
            case .recommended(let stop):
                recommended.append((
                    stop.id,
                    stop.name,
                    Self.coordinateKey(stop.coordinate),
                    cachedDistance(for: stop)
                ))
            case .pastRange(let stop):
                pastRange.append((
                    stop.id,
                    stop.name,
                    Self.coordinateKey(stop.coordinate),
                    cachedDistance(for: stop)
                ))
            case .gap:
                break
            }
        }
        let checked = Set(bufferedGasStops.map(\.id))
        var anchors = gasFillDistances
        anchors.append(contentsOf: recommended.map(\.distance))
        anchors.append(contentsOf: pastRange.map(\.distance))
        return Self.fuelRowLabels(
            recommended: recommended,
            pastRange: pastRange,
            anchors: anchors,
            legs: cachedDriveLegs,
            checkedIDs: checked,
            usesMetric: AppSettings.usesMetricUnits
        )
    }

    /// Formats each fuel row's title and mile caption. The two strings are
    /// one value, so the list cannot show "Fuel stop 12" with another
    /// station's "~164 mi from start" line.
    private nonisolated static func fuelRowLabels(
        recommended: [(id: UUID, name: String, key: String, distance: CLLocationDistance)],
        pastRange: [(id: UUID, name: String, key: String, distance: CLLocationDistance)],
        anchors: [CLLocationDistance],
        legs: [FuelStopRidingTime.Leg],
        checkedIDs: Set<UUID>,
        usesMetric: Bool
    ) -> FuelRowLabelSet {
        var set = FuelRowLabelSet()
        func store(_ label: FuelRowLabel, id: UUID, key: String) {
            set.byID[id] = label
            if !key.isEmpty {
                set.byKey[key] = label
            }
        }
        for (number, stop) in recommended.enumerated() {
            let title = "Fuel stop \(number + 1): \(stop.name)"
            let caption = FuelStopRidingTime.caption(
                distanceMeters: stop.distance,
                anchors: anchors,
                legs: legs,
                usesMetric: usesMetric
            )
            let checked = checkedIDs.contains(stop.id)
            store(
                FuelRowLabel(
                    title: title,
                    caption: caption,
                    accessibilityLabel: "\(title), \(caption)",
                    identifier: AccessibilityID.fuelStop(stop.name, checked: checked),
                    pastFullTank: false
                ),
                id: stop.id,
                key: stop.key
            )
        }
        for stop in pastRange {
            let caption = FuelStopRidingTime.caption(
                distanceMeters: stop.distance,
                anchors: anchors,
                legs: legs,
                usesMetric: usesMetric
            )
            let checked = checkedIDs.contains(stop.id)
            let note = pastFullTankNotice
            store(
                FuelRowLabel(
                    title: stop.name,
                    caption: caption,
                    accessibilityLabel: "\(stop.name), \(caption), \(note)",
                    identifier: AccessibilityID.fuelStop(stop.name, checked: checked),
                    pastFullTank: true
                ),
                id: stop.id,
                key: stop.key
            )
        }
        return set
    }

    /// One pass over stations and waypoints. Coordinate keys are formatted
    /// here so the background pass does not touch map items.
    private func fuelPlanInputs() -> FuelPlanInputs {
        let onRouteKeys = Set(waypoints.map { Self.coordinateKey($0.coordinate) })
        var onRouteDistances = gasFillDistances
        for station in gasStations where onRouteKeys.contains(Self.coordinateKey(station.coordinate)) {
            onRouteDistances.append(cachedDistance(for: station))
        }
        for stop in fuelStops where onRouteKeys.contains(Self.coordinateKey(stop.coordinate)) {
            onRouteDistances.append(cachedDistance(for: stop))
        }
        let rows = fuelPlanEntries.map { entry -> FuelPlanRow in
            switch entry {
            case .recommended(let stop):
                return FuelPlanRow(
                    entryID: entry.id,
                    stopID: stop.id,
                    key: Self.coordinateKey(stop.coordinate),
                    distance: cachedDistance(for: stop),
                    kind: .recommended
                )
            case .pastRange(let stop):
                return FuelPlanRow(
                    entryID: entry.id,
                    stopID: stop.id,
                    key: Self.coordinateKey(stop.coordinate),
                    distance: cachedDistance(for: stop),
                    kind: .pastRange
                )
            case .gap:
                return FuelPlanRow(
                    entryID: entry.id,
                    stopID: UUID(),
                    key: "",
                    distance: 0,
                    kind: .gap
                )
            }
        }
        return FuelPlanInputs(
            rows: rows,
            onRouteKeys: onRouteKeys,
            onRouteGasDistances: onRouteDistances,
            showsGap: showsFuelGapWarning,
            tank: fuelRangeMeters
        )
    }

    private nonisolated static func fuelPlanSnapshot(
        _ inputs: FuelPlanInputs
    ) -> FuelPlanSnapshot {
        let recommended = inputs.rows.compactMap { row -> TankCandidate? in
            guard row.kind == .recommended else { return nil }
            return TankCandidate(id: row.stopID, distance: row.distance)
        }
        let reachable = reachableStopIDs(
            candidates: recommended,
            onRoute: inputs.onRouteGasDistances,
            tank: inputs.tank
        )
        var visible: [String] = []
        var keys = Set<String>()
        visible.reserveCapacity(inputs.rows.count)
        for row in inputs.rows {
            switch row.kind {
            case .recommended:
                guard reachable.contains(row.stopID), !inputs.onRouteKeys.contains(row.key) else { continue }
                visible.append(row.entryID)
                keys.insert(row.key)
            case .pastRange:
                guard inputs.showsGap, !inputs.onRouteKeys.contains(row.key) else { continue }
                visible.append(row.entryID)
                keys.insert(row.key)
            case .gap:
                if inputs.showsGap {
                    visible.append(row.entryID)
                }
            }
        }
        return FuelPlanSnapshot(
            visibleEntryIDs: visible,
            fuelPlanKeys: keys,
            onRouteKeys: inputs.onRouteKeys,
            onRouteGasDistances: inputs.onRouteGasDistances
        )
    }

    /// Stops the tank can reach, in ride order. The first stop past the tank
    /// ends the walk, matching the selection the rider can insert.
    private nonisolated static func reachableStopIDs(
        candidates: [TankCandidate],
        onRoute: [CLLocationDistance],
        tank: CLLocationDistance
    ) -> Set<UUID> {
        let onRoute = onRoute.filter(\.isFinite)
        let tolerance = FuelStopRidingTime.sameStopToleranceMeters
        var reachable: [CLLocationDistance] = [0]

        func alreadyReached(_ distance: CLLocationDistance) -> Bool {
            reachable.contains { abs($0 - distance) <= tolerance }
        }

        func withinTank(_ distance: CLLocationDistance) -> Bool {
            let prior = reachable.filter { $0 <= distance + tolerance }
            guard let anchor = prior.max() else { return false }
            let hop = distance - anchor
            guard hop.isFinite else { return false }
            if hop < 0 { return -hop <= tolerance }
            return hop <= tank
        }

        func absorbOnRouteFuel() {
            var added = true
            while added {
                added = false
                for distance in onRoute where !alreadyReached(distance) {
                    guard withinTank(distance) else { continue }
                    reachable.append(distance)
                    added = true
                }
            }
        }

        absorbOnRouteFuel()
        var ids = Set<UUID>()
        for stop in candidates.sorted(by: { $0.distance < $1.distance }) {
            guard stop.distance.isFinite, withinTank(stop.distance) else { break }
            ids.insert(stop.id)
            if !alreadyReached(stop.distance) {
                reachable.append(stop.distance)
            }
            absorbOnRouteFuel()
        }
        return ids
    }

    /// Re-selects the recommended fuel stops from the already-computed
    /// travel-side gas stations, e.g. after a fill is added. Cheap when the
    /// tank-interval search has already run — no network.
    func replanFuelStops(pairingFood: Bool = true) {
        guard totalDistanceMeters > fuelRangeMeters else {
            fuelFoodStops = []
            pairedFuelStopIDs = []
            mutateFuelList {
                fuelStops = []
                fuelPlanEntries = []
                hasFuelGap = false
            }
            return
        }
        let plan = Self.fuelPlan(
            from: travelSideGasStations,
            totalDistance: totalDistanceMeters,
            range: fuelRangeMeters,
            filledAt: gasFillDistances,
            preferringFoodAt: gasStopsWithFood,
            departure: effectiveDeparture,
            totalTravelTime: totalExpectedTravelTime,
            unsearched: unsearchedFuelDistances
        )
        // One snapshot after both arrays are in place. Publishing from the
        // first assignment would number old rows against the new stops.
        mutateFuelList {
            fuelStops = plan.stops
            fuelPlanEntries = plan.entries
            // A dry stretch only becomes the rider-facing warning when this pool
            // came from a search that returned every sample. Departure-time meal
            // replans keep that trust bit; they do not invent a gap.
            hasFuelGap = plan.hasGap && gasCoverageTrusted
        }
        gasLog.info("fuel gap gen=\(self.gasGeneration, privacy: .public) planGap=\(plan.hasGap, privacy: .public) trusted=\(self.gasCoverageTrusted, privacy: .public) show=\(self.hasFuelGap, privacy: .public)")
        // Re-pair food when the range slider changes the chosen stops. The
        // identity guard inside makes this a no-op (no network) when the set
        // of stops is unchanged.
        if pairingFood {
            Task { await refreshFoodNearFuelStops() }
        }
    }

    /// Pairs nearby food to each recommended fuel stop with one bounded search
    /// per stop, so cost scales with the number of refuels (typically 1–3) and
    /// not the route length. Skips the work entirely when the set of fuel stops
    /// hasn't changed since the last pairing.
    func refreshFoodNearFuelStops() async {
        let currentIDs = Set(fuelStops.map(\.id))
        guard currentIDs != pairedFuelStopIDs else { return }
        pairedFuelStopIDs = currentIDs

        guard !fuelStops.isEmpty else {
            fuelFoodStops = []
            return
        }

        // Project food onto the same polylines used everywhere else, computed
        // once and reused across the per-stop searches.
        let legPolylines = legs.map { RouteGeometry.coordinates(of: $0.polyline) }
        var paired: [FuelFoodStop] = []
        for stop in fuelStops {
            let food = await searchFood(
                near: stop.coordinate,
                alongPolylines: legPolylines
            )
            // Superseded mid-pairing: reset the identity guard so the next
            // run redoes the (abandoned) pairing, and leave state untouched.
            guard !Task.isCancelled else {
                pairedFuelStopIDs = []
                return
            }
            paired.append(FuelFoodStop(fuelStop: stop, nearbyFood: food))
        }
        fuelFoodStops = paired
    }

    /// Whether a gas station is one of the auto-recommended fuel stops.
    func isRecommendedFuelStop(_ stop: SuggestedStop) -> Bool {
        fuelStops.contains { $0.id == stop.id }
    }

    /// Fraction of the tank range at which a refuel is recommended, leaving a
    /// safety buffer so the rider isn't running on fumes (~85% = ~15% reserve,
    /// about 25 miles on a 170-mile tank).
    nonisolated static let fuelSafetyFactor = 0.85

    /// Hops shorter than this fraction of the tank are skipped when they
    /// don't unlock a station past the current reach. 20% of 170 miles is
    /// 34 miles, so a 29-mile bunch is not a second fuel stop.
    nonisolated static let fuelStopMinimumSeparationFactor = 0.20

    /// How close food must sit to a pump to count as "food at the stop."
    /// Matches `StopSuggestionService.findFood`'s default radius.
    nonisolated static let fuelFoodRadiusMeters: CLLocationDistance = 1_500

    /// Corridor for tank-interval gas/food search. Wider than the chip
    /// suggestion default (~5 mi) so a pump a town off the sample still counts.
    /// Each lookup keeps stations inside this radius of its sample, about 15 miles.
    nonisolated static let fuelSearchCorridorMeters: CLLocationDistance = 24_000

    /// Overlap between neighboring search bubbles, as a fraction of the
    /// diameter. The step stays under two radii so a bend in the highway
    /// still falls inside a lookup.
    nonisolated static let fuelSearchCoverOverlap = 0.15

    /// Along-route spacing of fuel searches. Bubbles of `fuelSearchCorridorMeters`
    /// overlap by `fuelSearchCoverOverlap`.
    nonisolated static let fuelSearchCoverStepMeters: CLLocationDistance =
        fuelSearchCorridorMeters * 2 * (1 - fuelSearchCoverOverlap)

    /// First-pass lookups. One per comfort edge, capped at the MapKit
    /// rate window. The dense 25-mile grid was about 110 requests and the
    /// later ones were throttled, which the planner read as no gas from
    /// mile 560 to 1,904.
    nonisolated static let fuelSearchMaxSamples = MapSearchPace.maxRequestsPerWindow

    /// Distances for the first fuel search: the comfort edge of every tank.
    /// About 14 lookups on a 2,471-mile ride with a 200-mile tank, inside
    /// one rate window. Gaps wider than the reserve are filled afterwards
    /// by `fuelDensifySearchDistances`.
    nonisolated static func fuelSearchDistances(
        totalDistance: CLLocationDistance,
        range: CLLocationDistance,
        safetyFactor: Double = fuelSafetyFactor,
        maxCount: Int = fuelSearchMaxSamples
    ) -> [CLLocationDistance] {
        guard range > 0, totalDistance > 0, maxCount > 0 else { return [] }

        let interval = range * safetyFactor
        guard interval > 0 else { return [] }

        if totalDistance <= range {
            return [min(totalDistance * 0.5, interval)]
        }

        var edges: [CLLocationDistance] = []
        var k = 1
        while true {
            let edge = interval * Double(k)
            if edge < totalDistance {
                edges.append(edge)
            }
            if edge >= totalDistance { break }
            k += 1
            if k > 10_000 { break }
        }

        // More comfort edges than the budget. Thin them, keeping both ends.
        if edges.count >= maxCount {
            return spacedDistances(edges, max: maxCount)
        }
        return edges
    }

    /// Extra lookups between two found stations that are farther apart than
    /// `limit` (the reserve). The open road before the first station and
    /// after the last one stays on the coarse pass. A hop inside the
    /// reserve adds nothing, and a failed sample inside a stretch is not
    /// a hole to fill. Samples stay about `fuelSearchCoverStepMeters`
    /// apart so the 15-mile corridor still overlaps, which is what keeps
    /// Arizona I-10 (Eloy to Quartzsite) inside the reserve.
    nonisolated static func fuelDensifySearchDistances(
        totalDistance: CLLocationDistance,
        limit: CLLocationDistance,
        stationDistances: [CLLocationDistance],
        alreadySearched: [CLLocationDistance] = [],
        unsearched: [CLLocationDistance] = [],
        coverStep: CLLocationDistance = fuelSearchCoverStepMeters,
        radius: CLLocationDistance = fuelSearchCorridorMeters,
        maxCount: Int = MapSearchPace.maxRequestsPerWindow
    ) -> [CLLocationDistance] {
        guard limit > 0, coverStep > 0, radius > 0, totalDistance > limit, maxCount > 0 else {
            return []
        }
        // Only the stretch between two found stations. The ride before the
        // first pump and after the last one is the coarse pass. A hop inside
        // the reserve, and a hop that crosses a failed lookup, adds nothing.
        let stations = stationDistances.filter { $0 > 0 && $0 < totalDistance }.sorted()
        guard stations.count >= 2 else { return [] }

        func covered(_ distance: CLLocationDistance, by points: [CLLocationDistance]) -> Bool {
            points.contains { abs($0 - distance) <= radius }
        }

        var gaps: [(start: CLLocationDistance, end: CLLocationDistance)] = []
        for index in 1..<stations.count {
            let start = stations[index - 1]
            let end = stations[index]
            guard end - start > limit else { continue }
            if unsearched.contains(where: { $0 > start && $0 < end }) { continue }
            gaps.append((start, end))
        }
        // Widest hole first, so one desert does not lose its lookups to
        // a long prefix that already has a station near every tank.
        gaps.sort { ($0.end - $0.start) > ($1.end - $1.start) }

        var samples: [CLLocationDistance] = []
        for gap in gaps {
            if samples.count >= maxCount { break }
            var cursor = gap.start
            while cursor < gap.end, samples.count < maxCount {
                let known = alreadySearched + samples
                if covered(cursor, by: known) {
                    cursor += radius * 0.5
                    continue
                }
                samples.append(cursor)
                cursor += coverStep
            }
            let known = alreadySearched + samples
            if samples.count < maxCount,
               !covered(gap.end, by: known),
               gap.end < totalDistance,
               gap.end > gap.start,
               !samples.contains(where: { abs($0 - gap.end) < 1 }) {
                samples.append(gap.end)
            }
        }
        return samples.sorted()
    }

    /// Highlight lookups spread across the whole ride. A handful, paced
    /// with the fuel search, so a long interstate still gets sights instead
    /// of an empty section after the gas queries have used the rate window.
    nonisolated static func highlightSearchDistances(
        totalDistance: CLLocationDistance,
        maxCount: Int = 12
    ) -> [CLLocationDistance] {
        guard totalDistance > 0, maxCount > 0 else { return [] }
        if maxCount == 1 { return [totalDistance * 0.5] }
        let step = totalDistance / Double(maxCount + 1)
        return (1...maxCount).compactMap { index in
            let distance = step * Double(index)
            return distance < totalDistance ? distance : nil
        }
    }

    /// Spreads `samples` down to `limit` items, keeping the first and last.
    private nonisolated static func spacedDistances(
        _ samples: [CLLocationDistance],
        max limit: Int
    ) -> [CLLocationDistance] {
        guard limit > 0 else { return [] }
        guard samples.count > limit else { return samples }
        guard limit > 1 else { return samples.isEmpty ? [] : [samples[0]] }
        let step = Double(samples.count - 1) / Double(limit - 1)
        return (0..<limit).map { samples[Int((Double($0) * step).rounded())] }
    }

    /// Gas stations that have at least one food stop within `radiusMeters`.
    nonisolated static func gasStopsWithNearbyFood(
        _ gasStops: [SuggestedStop],
        food: [SuggestedStop],
        radiusMeters: CLLocationDistance = fuelFoodRadiusMeters
    ) -> Set<UUID> {
        guard !food.isEmpty else { return [] }
        var ids = Set<UUID>()
        for gas in gasStops {
            let gasLocation = CLLocation(
                latitude: gas.coordinate.latitude,
                longitude: gas.coordinate.longitude
            )
            let nearby = food.contains { stop in
                gasLocation.distance(from: CLLocation(
                    latitude: stop.coordinate.latitude,
                    longitude: stop.coordinate.longitude
                )) <= radiusMeters
            }
            if nearby {
                ids.insert(gas.id)
            }
        }
        return ids
    }

    /// Distances along the current route of rider-added gas waypoints, each
    /// treated as a fill so later recommendations start from that point.
    /// The values were measured when the waypoints or the route changed.
    private var gasFillDistances: [CLLocationDistance] {
        guard !legs.isEmpty || plannedCorridor.contains(where: { $0.count > 1 }) else { return [] }
        return waypoints.compactMap { waypoint in
            guard waypoint.isGasFill else { return nil }
            return distanceAlongRouteByID[waypoint.id] ?? 0
        }
    }

    /// Whether `date` falls in a typical meal window (breakfast / lunch / dinner).
    nonisolated static func isMealTime(
        _ date: Date,
        windows: [MealWindow] = MealWindow.typical,
        calendar: Calendar = .current
    ) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return windows.contains { window in
            if window.startMinutes <= window.endMinutes {
                return minutes >= window.startMinutes && minutes < window.endMinutes
            }
            return minutes >= window.startMinutes || minutes < window.endMinutes
        }
    }

    /// ETA at `distance` along the ride, interpolating travel time by fraction
    /// of total distance. Used to decide whether a tank-interval stop is a meal.
    nonisolated static func etaAlongRoute(
        distance: CLLocationDistance,
        totalDistance: CLLocationDistance,
        departure: Date,
        totalTravelTime: TimeInterval
    ) -> Date {
        guard totalDistance > 0, totalTravelTime > 0 else { return departure }
        let fraction = min(max(distance / totalDistance, 0), 1)
        return departure.addingTimeInterval(totalTravelTime * fraction)
    }

    /// Greedy fuel-stop selection. From the last fill-up (ride start, or a
    /// rider-added gas waypoint in `filledAt`), pick the gas station as far
    /// along as possible whose ridden hop stays within `safetyFactor` of the
    /// tank (so there's a reserve). The ridden hop is the along-route
    /// distance plus the detour back from the previous pump and out to this
    /// one — the leg Select recommended's replan actually rides. Food is
    /// optional: when the tank-interval ETA is near breakfast / lunch /
    /// dinner *and* `preferringFoodAt` lists an in-window pump, that pump
    /// wins over gas-only in the same window. Off-meal or missing food never
    /// skips the stop. That hop, including the leg into the destination,
    /// stays inside the reserve (tank × 0.85) when any station fits there.
    /// When the reserve window is empty, the nearest station still inside
    /// the full tank is the next stop. A station beyond the tank is not a
    /// fuel stop. Planning continues until the distance left fits in the
    /// reserve. A last stretch inside the hard tank with no station is not
    /// a gap.
    ///
    /// A hop shorter than `minimumSeparationFactor` of the tank is skipped
    /// when it does not unlock a station past the current reach. A segment
    /// with no useful station inside the hard range is a named gap from the
    /// last reachable station to the next one (or the destination). That
    /// next station is listed as past range, not as "Fuel stop N", and
    /// planning resumes from it so later in-range tanks still appear.
    ///
    /// `range`, `totalDistance`, `filledAt`, and each stop's
    /// `distanceAlongRoute` are meters along the road (polyline length summed
    /// across legs, the same unit as `MKRoute.distance`). The tank slider
    /// stores miles and converts with `AppSettings.metersPerMile` before this
    /// runs.
    nonisolated static func planFuelStops(
        from gasStops: [SuggestedStop],
        totalDistance: CLLocationDistance,
        range: CLLocationDistance,
        filledAt: [CLLocationDistance] = [],
        safetyFactor: Double = fuelSafetyFactor,
        preferringFoodAt: Set<UUID> = [],
        departure: Date? = nil,
        totalTravelTime: TimeInterval = 0,
        mealWindows: [MealWindow] = MealWindow.typical,
        calendar: Calendar = .current
    ) -> (stops: [SuggestedStop], hasGap: Bool) {
        let plan = fuelPlan(
            from: gasStops,
            totalDistance: totalDistance,
            range: range,
            filledAt: filledAt,
            safetyFactor: safetyFactor,
            preferringFoodAt: preferringFoodAt,
            departure: departure,
            totalTravelTime: totalTravelTime,
            mealWindows: mealWindows,
            calendar: calendar
        )
        return (plan.stops, plan.hasGap)
    }

    nonisolated static func fuelPlan(
        from gasStops: [SuggestedStop],
        totalDistance: CLLocationDistance,
        range: CLLocationDistance,
        filledAt: [CLLocationDistance] = [],
        safetyFactor: Double = fuelSafetyFactor,
        minimumSeparationFactor: Double = fuelStopMinimumSeparationFactor,
        preferringFoodAt: Set<UUID> = [],
        departure: Date? = nil,
        totalTravelTime: TimeInterval = 0,
        mealWindows: [MealWindow] = MealWindow.typical,
        calendar: Calendar = .current,
        unsearched: [CLLocationDistance] = []
    ) -> FuelPlan {
        let draft = fuelPlanDraft(
            from: gasStops.map {
                FuelCandidate(
                    id: $0.id,
                    distanceAlongRoute: $0.distanceAlongRoute,
                    detourMeters: $0.detourMeters
                )
            },
            totalDistance: totalDistance,
            range: range,
            filledAt: filledAt,
            safetyFactor: safetyFactor,
            minimumSeparationFactor: minimumSeparationFactor,
            preferringFoodAt: preferringFoodAt,
            departure: departure,
            totalTravelTime: totalTravelTime,
            mealWindows: mealWindows,
            calendar: calendar,
            unsearched: unsearched
        )
        return fuelPlan(from: draft, stops: gasStops)
    }

    /// Maps a background plan back onto the stops the rider is holding.
    fileprivate nonisolated static func fuelPlan(
        from draft: FuelPlanDraft,
        stops: [SuggestedStop]
    ) -> FuelPlan {
        var byID: [UUID: SuggestedStop] = [:]
        byID.reserveCapacity(stops.count)
        for stop in stops where byID[stop.id] == nil {
            byID[stop.id] = stop
        }
        let recommended = draft.recommendedIDs.compactMap { byID[$0] }
        let entries = draft.entries.compactMap { entry -> FuelPlanEntry? in
            switch entry {
            case .recommended(let id):
                guard let stop = byID[id] else { return nil }
                return .recommended(stop)
            case .pastRange(let id):
                guard let stop = byID[id] else { return nil }
                return .pastRange(stop)
            case .gap(let fromMeters, let toMeters, let rangeMeters):
                return .gap(FuelGap(
                    fromMeters: fromMeters,
                    toMeters: toMeters,
                    rangeMeters: rangeMeters
                ))
            }
        }
        return FuelPlan(stops: recommended, entries: entries, hasGap: draft.hasGap)
    }

    fileprivate nonisolated static func fuelPlanDraft(
        from candidates: [FuelCandidate],
        totalDistance: CLLocationDistance,
        range: CLLocationDistance,
        filledAt: [CLLocationDistance] = [],
        safetyFactor: Double = fuelSafetyFactor,
        minimumSeparationFactor: Double = fuelStopMinimumSeparationFactor,
        preferringFoodAt: Set<UUID> = [],
        departure: Date? = nil,
        totalTravelTime: TimeInterval = 0,
        mealWindows: [MealWindow] = MealWindow.typical,
        calendar: Calendar = .current,
        unsearched: [CLLocationDistance] = []
    ) -> FuelPlanDraft {
        guard range > 0, totalDistance > range else {
            return FuelPlanDraft(recommendedIDs: [], entries: [], hasGap: false)
        }

        let comfortRange = range * safetyFactor
        let minimumSeparation = range * minimumSeparationFactor
        let sorted = candidates.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        var recommendedIDs: [UUID] = []
        var entries: [FuelPlanDraftEntry] = []
        var skippedNear = Set<UUID>()
        // Rider-added gas stops count as fills; later pumps plan from the last one.
        var lastRefuel: CLLocationDistance = max(0, filledAt.max() ?? 0)
        // Detour of the pump we just left. The next leg starts there, off the
        // line, so the replan rides this distance again on the way out.
        var lastDetour: CLLocationDistance = 0
        var steps = 0
        let stepLimit = max(sorted.count * 3, 1) + 4

        func finiteDetour(_ stop: FuelCandidate) -> CLLocationDistance {
            let detour = stop.detourMeters
            guard detour.isFinite else { return 0 }
            return max(0, detour)
        }

        /// Along-route progress plus both detours. This is the leg length
        /// after Select recommended inserts the stop and the route replans.
        func riddenHop(to stop: FuelCandidate) -> CLLocationDistance {
            (stop.distanceAlongRoute - lastRefuel) + lastDetour + finiteDetour(stop)
        }

        func crossesUnsearched(_ distance: CLLocationDistance) -> Bool {
            unsearched.contains { sample in
                sample > lastRefuel + 1 && sample < distance - 1
            }
        }

        func inWindow(_ limit: CLLocationDistance) -> [FuelCandidate] {
            sorted.filter {
                $0.distanceAlongRoute > lastRefuel
                    && riddenHop(to: $0) <= limit
                    && !skippedNear.contains($0.id)
                    && !crossesUnsearched($0.distanceAlongRoute)
            }
        }

        // Farthest station within the window. Food is a meal-time preference,
        // not a gate — off-meal we keep the tank-interval gas pick.
        func farthest(_ limit: CLLocationDistance, preferFood: Bool) -> FuelCandidate? {
            let window = inWindow(limit)
            let withFood = (preferFood && !preferringFoodAt.isEmpty)
                ? window.filter { preferringFoodAt.contains($0.id) }
                : []
            let pool = withFood.isEmpty ? window : withFood
            return pool.max(by: { $0.distanceAlongRoute < $1.distanceAlongRoute })
        }

        /// Closest station still inside the tank. Used only when the reserve
        /// window is empty.
        func nearest(_ limit: CLLocationDistance) -> FuelCandidate? {
            inWindow(limit).min(by: { $0.distanceAlongRoute < $1.distanceAlongRoute })
        }

        /// A short hop is worth taking when the destination, or some later
        /// station, sits past the current tank but inside the tank measured
        /// from this stop.
        func extendsReach(_ stop: FuelCandidate) -> Bool {
            let unlockedStart = lastRefuel + range
            let unlockedEnd = stop.distanceAlongRoute + range
            if totalDistance > unlockedStart, totalDistance <= unlockedEnd {
                return true
            }
            return sorted.contains {
                $0.id != stop.id
                    && $0.distanceAlongRoute > unlockedStart
                    && $0.distanceAlongRoute <= unlockedEnd
            }
        }

        func nextStation(after distance: CLLocationDistance) -> FuelCandidate? {
            sorted.first { $0.distanceAlongRoute > distance }
        }

        func appendGap(from start: CLLocationDistance, to end: CLLocationDistance) {
            guard end - start > range else { return }
            entries.append(.gap(fromMeters: start, toMeters: end, rangeMeters: range))
        }

        // Keep refueling until the remaining distance fits in the reserve.
        // The nearest station inside the tank is the fallback when that
        // window is empty, including the stretch to the destination.
        while totalDistance - lastRefuel > comfortRange {
            steps += 1
            if steps > stepLimit { break }

            let targetDistance = min(lastRefuel + comfortRange, totalDistance)
            let preferFoodForMeal: Bool
            if let departure, totalTravelTime > 0 {
                let eta = etaAlongRoute(
                    distance: targetDistance,
                    totalDistance: totalDistance,
                    departure: departure,
                    totalTravelTime: totalTravelTime
                )
                preferFoodForMeal = isMealTime(eta, windows: mealWindows, calendar: calendar)
            } else {
                preferFoodForMeal = false
            }

            // Reserve first: the farthest station inside 0.85 × tank.
            // When that window is empty, the nearest station still inside
            // the tank, so the rider fuels as soon as possible. A station
            // past the tank is not a stop.
            if let stop = farthest(comfortRange, preferFood: preferFoodForMeal)
                ?? nearest(range) {
                let hop = stop.distanceAlongRoute - lastRefuel
                if hop < minimumSeparation, !extendsReach(stop) {
                    skippedNear.insert(stop.id)
                    // Nothing else inside the tank. The dry stretch starts
                    // after this last reachable station, not after the
                    // previous fill that made the hop look short.
                    if nearest(range) == nil {
                        let next = nextStation(after: stop.distanceAlongRoute)
                        if let next, crossesUnsearched(next.distanceAlongRoute) {
                            break
                        }
                        let end = next?.distanceAlongRoute ?? totalDistance
                        appendGap(from: stop.distanceAlongRoute, to: end)
                        if let next {
                            entries.append(.pastRange(next.id))
                            lastRefuel = next.distanceAlongRoute
                            lastDetour = finiteDetour(next)
                            skippedNear.removeAll()
                            continue
                        }
                        break
                    }
                    continue
                }
                recommendedIDs.append(stop.id)
                entries.append(.recommended(stop.id))
                lastRefuel = stop.distanceAlongRoute
                lastDetour = finiteDetour(stop)
                skippedNear.removeAll()
                continue
            }

            // The destination is still inside the tank, and no station in
            // the reserve window can shorten the last stretch. Arriving
            // on the reserve is not a dry gap.
            if totalDistance - lastRefuel <= range {
                break
            }

            // Nothing within range of the last fill. A sample that never
            // returned is not that stretch: don't resume on the far side
            // and call the hop a fuel stop. Name a real dry stretch and
            // keep the far station on the list as past range, then plan
            // the tanks after it. Recommending it as "Fuel stop N" is how
            // a 100-mile tank showed its first stop at mile 801.
            let next = nextStation(after: lastRefuel)
            if let next, crossesUnsearched(next.distanceAlongRoute) {
                break
            }
            let end = next?.distanceAlongRoute ?? totalDistance
            appendGap(from: lastRefuel, to: end)
            if let next {
                entries.append(.pastRange(next.id))
                lastRefuel = next.distanceAlongRoute
                lastDetour = finiteDetour(next)
                skippedNear.removeAll()
                continue
            }
            break
        }

        let hasGap = entries.contains { entry in
            if case .gap = entry { return true }
            return false
        }
        return FuelPlanDraft(recommendedIDs: recommendedIDs, entries: entries, hasGap: hasGap)
    }

    // MARK: - Ride highlights (places of interest)

    /// Finds places of interest along the route and picks a handful worth
    /// stopping at — low-detour sights spread across the ride. Mirrors the
    /// fuel-stop pipeline: search wide, then select with pure logic.
    func refreshHighlights() async {
        highlightGeneration += 1
        let generation = highlightGeneration
        guard !legs.isEmpty else {
            rideHighlights = []
            return
        }

        // Reuse already-loaded sights when the rider is browsing that
        // category. Otherwise sample the whole ride, paced with the fuel
        // search. Half of the old 25-mile walk ran after a throttled gas
        // grid and came back empty, so the section never mounted.
        let searched: [SuggestedStop]
        if selectedCategory == .attraction, !suggestedStops.isEmpty {
            searched = suggestedStops
        } else {
            let found = await searchStops(
                category: .attraction,
                alongLegs: legs,
                sampleDistances: Self.highlightSearchDistances(totalDistance: totalDistanceMeters),
                corridorRadiusMeters: 8_000,
                generation: generation
            )
            // A cancelled highlight pass publishes nothing. A throttled or
            // failed lookup is not an empty ride: landmarks on the line
            // still appear.
            guard !Task.isCancelled, generation == highlightGeneration else { return }
            searched = found.status == .completed ? found.stops : []
        }

        let landmarks = Self.landmarkHighlights(
            alongPolylines: suggestionRoutePolylines,
            totalDistance: totalDistanceMeters
        )
        let candidates = searched + landmarks.filter { landmark in
            !searched.contains { candidate in
                candidate.name.compare(landmark.name, options: .caseInsensitive) == .orderedSame
                    || Self.sameCoordinate(candidate.coordinate, landmark.coordinate)
            }
        }

        let picked = applyingKnownPlaceDescriptions(Self.selectHighlights(
            from: candidates,
            totalDistance: totalDistanceMeters
        ))
        rideHighlights = picked
        let enriched = await attachingPlaceDescriptions(picked)
        guard generation == highlightGeneration, !Task.isCancelled else { return }
        rideHighlights = enriched
    }

    /// Copies Apple Maps prose onto scenic and sights stops before the row
    /// is shown. When that prose is missing or only engagement stats, a
    /// landmark with a known sentence (Cadillac Ranch) still gets it.
    /// Every other place with no prose stays nil.
    private func applyingKnownPlaceDescriptions(_ stops: [SuggestedStop]) -> [SuggestedStop] {
        stops.map { stop in
            guard stop.category.showsPlaceDescription, stop.placeDescription == nil else { return stop }
            if let text = PlaceDescriptionReader.appleMapsText(from: stop.mapItem) {
                return stop.withPlaceDescription(text)
            }
            if let known = PlaceDescriptionReader.knownPlaceDescription(name: stop.name) {
                return stop.withPlaceDescription(known)
            }
            return stop
        }
    }

    /// Cadillac Ranch sits just south of I-40 west of Amarillo. A dozen
    /// highlight samples on a coast-to-coast ride miss it unless one lands
    /// nearby. When the published line passes within the sights corridor,
    /// the ranch is a candidate and already carries its description.
    nonisolated static func landmarkHighlights(
        alongPolylines polylines: [[CLLocationCoordinate2D]],
        totalDistance: CLLocationDistance,
        corridorMeters: CLLocationDistance = 8_000
    ) -> [SuggestedStop] {
        guard totalDistance > 0, polylinesAreMeasurable(polylines) else { return [] }
        let coordinate = PlaceDescriptionReader.cadillacRanchCoordinate
        let detour = RouteGeometry.distanceFromRoute(of: coordinate, alongPolylines: polylines)
        guard detour.isFinite, detour <= corridorMeters else { return [] }
        let along = RouteGeometry.distanceAlongRoute(of: coordinate, alongPolylines: polylines)
        guard along > 1, along < totalDistance - 1 else { return [] }
        let stop = SuggestedStop(
            name: "Cadillac Ranch",
            coordinate: coordinate,
            category: .attraction,
            distanceAlongRoute: along,
            detourMeters: detour
        )
        return [stop.withPlaceDescription(PlaceDescriptionReader.cadillacRanchDescription)]
    }

    /// Fills in a place's own page description when Apple Maps had no prose.
    /// Queries are sendable copies; the map item stays on the main actor.
    private func attachingPlaceDescriptions(_ stops: [SuggestedStop]) async -> [SuggestedStop] {
        let queries = stops.compactMap { stop -> PlaceDescriptionQuery? in
            guard stop.category.showsPlaceDescription, stop.placeDescription == nil else { return nil }
            let query = stop.placeDescriptionQuery()
            guard let url = query.websiteURL, PlaceDescriptionReader.isPlaceWebsite(url) else { return nil }
            return query
        }
        guard !queries.isEmpty else { return stops }
        let found = await PlaceDescriptionLoader.resolve(queries)
        guard !found.isEmpty else { return stops }
        return stops.map { stop in
            guard let text = found[stop.id] else { return stop }
            return stop.withPlaceDescription(text)
        }
    }

    /// Whether a stop is one of the auto-recommended ride highlights.
    func isRideHighlight(_ stop: SuggestedStop) -> Bool {
        rideHighlights.contains { $0.id == stop.id }
    }

    /// Pure selection of ride highlights from the places of interest found
    /// near the route. A sight farther than the search corridor is dropped,
    /// as are ones essentially at the start or destination. The rest are
    /// taken smallest-detour-first, keeping stops at least
    /// `minSeparationMeters` apart so the picks spread across the ride.
    /// Returned in ride order. The section header is the highlight list;
    /// an empty pick (a throttled search, or nothing inside the corridor)
    /// leaves the section off the sheet.
    nonisolated static func selectHighlights(
        from candidates: [SuggestedStop],
        totalDistance: CLLocationDistance,
        maxCount: Int = 4,
        maxDetourMeters: CLLocationDistance = 8_000,
        minSeparationMeters: CLLocationDistance = 15_000
    ) -> [SuggestedStop] {
        guard maxCount > 0, totalDistance > 0 else { return [] }

        // Ignore sights basically at the origin or destination.
        let endMargin = min(5_000, totalDistance * 0.05)
        let eligible = candidates.filter {
            $0.detourMeters <= maxDetourMeters
                && $0.distanceAlongRoute > endMargin
                && $0.distanceAlongRoute < totalDistance - endMargin
        }

        var chosen: [SuggestedStop] = []
        for stop in eligible.sorted(by: { $0.detourMeters < $1.detourMeters }) {
            guard chosen.count < maxCount else { break }
            let farEnough = chosen.allSatisfy {
                abs($0.distanceAlongRoute - stop.distanceAlongRoute) >= minSeparationMeters
            }
            if farEnough {
                chosen.append(stop)
            }
        }

        return chosen.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
    }

    // MARK: - Suggestions

    /// Meters from the ride start for one suggestion row. This is the cached
    /// measurement. Projecting here walked the whole polyline once per row.
    func distanceFromStart(of stop: SuggestedStop) -> CLLocationDistance {
        cachedDistance(for: stop)
    }

    /// Cached mile mark. A miss uses the distance stored on the stop, which
    /// is what search already measured. It does not scan the polyline.
    private func cachedDistance(for stop: SuggestedStop) -> CLLocationDistance {
        distanceAlongRouteByID[stop.id] ?? stop.distanceAlongRoute
    }

    /// Measures every current station and waypoint once.
    /// A short route stays on the caller so a unit test can read mile marks
    /// immediately. A long polyline is projected off the main actor, then
    /// published once — `DispatchQueue.sync` here blocked the tap for seconds.
    private func rebuildDistanceCache() {
        guard !suppressDistanceRebuild else { return }
        let queries = distanceQueries()
        let polylines = suggestionRoutePolylines
        let points = polylines.reduce(0) { $0 + $1.count }
        if points <= 2_000, queries.count <= 400 {
            distanceAlongRouteByID = Self.projectDistances(
                queries: queries,
                on: measuredRoute(for: polylines)
            )
            publishFuelPlanSnapshot()
            return
        }
        let generation = routeGeometryGeneration
        Task { @MainActor in
            guard !self.suppressDistanceRebuild, generation == self.routeGeometryGeneration else { return }
            let route = await Self.measureRouteAsync(polylines)
            let distances = await Self.projectDistancesOffMain(queries: queries, on: route)
            guard !self.suppressDistanceRebuild, generation == self.routeGeometryGeneration else { return }
            self.distanceAlongRouteByID = distances
            self.publishFuelPlanSnapshot()
        }
    }

    /// Same measurement as `rebuildDistanceCache`, awaited so the main actor
    /// can draw the fuel spinner while a long polyline is projected.
    private func rebuildDistanceCacheOffMain() async {
        let queries = distanceQueries()
        let polylines = suggestionRoutePolylines
        let route = await measuredRouteOffMain(for: polylines)
        distanceAlongRouteByID = await Self.projectDistancesOffMain(queries: queries, on: route)
        publishFuelPlanSnapshot()
    }

    private func distanceQueries() -> [AlongRouteQuery] {
        var queries: [AlongRouteQuery] = []
        var seen = Set<UUID>()
        func append(id: UUID, coordinate: CLLocationCoordinate2D, known: CLLocationDistance) {
            guard seen.insert(id).inserted else { return }
            queries.append(AlongRouteQuery(
                id: id,
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                known: known
            ))
        }
        for stop in gasStations {
            append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
        }
        for stop in travelSideGasStations {
            append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
        }
        for stop in fuelStops {
            append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
        }
        for entry in fuelPlanEntries {
            switch entry {
            case .recommended(let stop), .pastRange(let stop):
                append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
            case .gap:
                break
            }
        }
        for stop in suggestedStops {
            append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
        }
        for stop in rideHighlights {
            append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
        }
        for stop in bufferedGasStops {
            append(id: stop.id, coordinate: stop.coordinate, known: stop.distanceAlongRoute)
        }
        for waypoint in waypoints {
            append(id: waypoint.id, coordinate: waypoint.coordinate, known: 0)
        }
        return queries
    }

    /// The polyline is measured once per route change. Later station edits
    /// only project onto that measurement.
    private func measuredRoute(
        for polylines: [[CLLocationCoordinate2D]]
    ) -> RouteGeometry.MeasuredRoute? {
        guard polylines.contains(where: { $0.count > 1 }) else {
            cachedMeasuredRoute = nil
            measuredRouteGeneration = routeGeometryGeneration
            return nil
        }
        if measuredRouteGeneration == routeGeometryGeneration, let cachedMeasuredRoute {
            return cachedMeasuredRoute
        }
        let route = Self.measureRouteOffMain(polylines)
        cachedMeasuredRoute = route
        measuredRouteGeneration = routeGeometryGeneration
        return route
    }

    /// Cache hit stays on the caller. A miss measures off the main actor
    /// and suspends, so the sheet can draw while the polyline is walked.
    private func measuredRouteOffMain(
        for polylines: [[CLLocationCoordinate2D]]
    ) async -> RouteGeometry.MeasuredRoute? {
        guard polylines.contains(where: { $0.count > 1 }) else {
            cachedMeasuredRoute = nil
            measuredRouteGeneration = routeGeometryGeneration
            return nil
        }
        if measuredRouteGeneration == routeGeometryGeneration, let cachedMeasuredRoute {
            return cachedMeasuredRoute
        }
        let route = await Self.measureRouteAsync(polylines)
        cachedMeasuredRoute = route
        measuredRouteGeneration = routeGeometryGeneration
        return route
    }

    private nonisolated static func measureRouteAsync(
        _ polylines: [[CLLocationCoordinate2D]]
    ) async -> RouteGeometry.MeasuredRoute {
        await Task.detached(priority: .userInitiated) {
            RouteGeometry.MeasuredRoute(polylines: polylines)
        }.value
    }

    /// Vertex distances for one polyline. Not main-actor isolated.
    private nonisolated static func measureRouteOffMain(
        _ polylines: [[CLLocationCoordinate2D]]
    ) -> RouteGeometry.MeasuredRoute {
        DispatchQueue.global(qos: .userInitiated).sync { @Sendable in
            RouteGeometry.MeasuredRoute(polylines: polylines)
        }
    }

    /// One projection per id against a route that was already measured.
    /// A missing route keeps the distance stored on the stop.
    private nonisolated static func projectDistances(
        queries: [AlongRouteQuery],
        on route: RouteGeometry.MeasuredRoute?
    ) -> [UUID: CLLocationDistance] {
        guard !queries.isEmpty, route != nil else {
            return knownDistances(queries)
        }
        return DispatchQueue.global(qos: .userInitiated).sync { @Sendable in
            Self.projectedDistances(queries: queries, on: route)
        }
    }

    /// Projection that suspends the main actor instead of blocking it.
    private nonisolated static func projectDistancesOffMain(
        queries: [AlongRouteQuery],
        on route: RouteGeometry.MeasuredRoute?
    ) async -> [UUID: CLLocationDistance] {
        guard !queries.isEmpty, route != nil else {
            return knownDistances(queries)
        }
        return await Task.detached(priority: .userInitiated) {
            Self.projectedDistances(queries: queries, on: route)
        }.value
    }

    private nonisolated static func knownDistances(
        _ queries: [AlongRouteQuery]
    ) -> [UUID: CLLocationDistance] {
        var known: [UUID: CLLocationDistance] = [:]
        for query in queries {
            known[query.id] = query.known
        }
        return known
    }

    private nonisolated static func projectedDistances(
        queries: [AlongRouteQuery],
        on route: RouteGeometry.MeasuredRoute?
    ) -> [UUID: CLLocationDistance] {
        guard let route else { return knownDistances(queries) }
        var measured: [UUID: CLLocationDistance] = [:]
        measured.reserveCapacity(queries.count)
        for query in queries {
            let coordinate = CLLocationCoordinate2D(
                latitude: query.latitude,
                longitude: query.longitude
            )
            let projected = RouteGeometry.distanceAlongRoute(of: coordinate, on: route)
            measured[query.id] = RouteGeometry.preferredDistanceAlongRoute(
                projected: projected,
                known: query.known
            )
        }
        return measured
    }

    nonisolated static func distanceFromStart(
        of stop: SuggestedStop,
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> CLLocationDistance {
        guard polylinesAreMeasurable(polylines) else { return stop.distanceAlongRoute }
        let projected = RouteGeometry.distanceAlongRoute(
            of: stop.coordinate,
            alongPolylines: polylines
        )
        return RouteGeometry.preferredDistanceAlongRoute(
            projected: projected,
            known: stop.distanceAlongRoute
        )
    }

    /// Copies each suggested stop with its projected distance from the
    /// start and returns them in ride order. Ids stay put. An
    /// unmeasurable route leaves the stored distances alone.
    nonisolated static func projectingDistancesFromStart(
        _ stops: [SuggestedStop],
        alongPolylines polylines: [[CLLocationCoordinate2D]]
    ) -> [SuggestedStop] {
        guard polylinesAreMeasurable(polylines) else { return stops }
        return stops.map { stop in
            let projected = RouteGeometry.distanceAlongRoute(
                of: stop.coordinate,
                alongPolylines: polylines
            )
            return stop.withDistanceAlongRoute(
                RouteGeometry.preferredDistanceAlongRoute(
                    projected: projected,
                    known: stop.distanceAlongRoute
                )
            )
        }
        .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
    }

    nonisolated private static func polylinesAreMeasurable(
        _ polylines: [[CLLocationCoordinate2D]]
    ) -> Bool {
        polylines.contains { RouteGeometry.length(of: $0) > 1 }
    }

    func refreshSuggestions() async {
        guard !legs.isEmpty else { return }
        suggestionGeneration += 1
        let generation = suggestionGeneration
        if selectedCategory == .gas {
            await refreshGasCategorySuggestions(generation: generation)
            return
        }
        isLoadingSuggestions = true
        defer {
            if generation == suggestionGeneration {
                isLoadingSuggestions = false
            }
        }
        let found = await searchStops(
            category: selectedCategory,
            alongLegs: legs
        )
        // A throttle or a cancel must not replace the list with [] and read
        // as "no stops". Only a completed search publishes.
        guard generation == suggestionGeneration, !Task.isCancelled, found.status == .completed else { return }
        let projected = Self.projectingDistancesFromStart(
            found.stops,
            alongPolylines: suggestionRoutePolylines
        )
        let published = applyingKnownPlaceDescriptions(projected)
        suggestedStops = published
        // The corridor search is done. Page descriptions fill in afterwards
        // and must not keep the "searching" row on screen.
        if generation == suggestionGeneration {
            isLoadingSuggestions = false
        }
        let enriched = await attachingPlaceDescriptions(published)
        guard generation == suggestionGeneration, !Task.isCancelled else { return }
        suggestedStops = enriched
    }

    /// Suggested Gas rows come from the same tank-interval corridor as the
    /// fuel recommendations (`fuelSearchDistances` + `fuelSearchCorridorMeters`),
    /// not a second search that MapKit throttles down to the origin. Mile
    /// marks are the projection onto the published line.
    private func refreshGasCategorySuggestions(generation: Int) async {
        var stations = gasStations.filter { $0.category == .gas }
        if stations.isEmpty {
            isLoadingSuggestions = true
            defer {
                if generation == suggestionGeneration {
                    isLoadingSuggestions = false
                }
            }
            let found = await searchStops(
                category: .gas,
                alongLegs: legs,
                sampleDistances: Self.fuelSearchDistances(
                    totalDistance: totalDistanceMeters,
                    range: fuelRangeMeters
                ),
                corridorRadiusMeters: Self.fuelSearchCorridorMeters,
                generation: generation
            )
            guard generation == suggestionGeneration, !Task.isCancelled, found.status == .completed else { return }
            gasStations = found.stops
            stations = found.stops
            showFuelCorridorInSuggestedGasList(stations)
            applyFuelCandidatePool()
            return
        }
        guard generation == suggestionGeneration, !Task.isCancelled else { return }
        showFuelCorridorInSuggestedGasList(stations)
    }

    /// Copies the fuel-corridor stations onto the suggestion list with mile
    /// marks measured along the route. A stored 0 does not stay "~0 mi".
    func showFuelCorridorInSuggestedGasList(_ stations: [SuggestedStop]? = nil) {
        let pool = stations ?? gasStations.filter { $0.category == .gas }
        suggestedStops = Self.projectingDistancesFromStart(
            pool,
            alongPolylines: suggestionRoutePolylines
        )
    }

    func selectCategory(_ category: StopCategory) {
        selectedCategory = category
        // The in-flight plan already refreshes suggestions when it finishes.
        // A second search here races MKLocalSearch and can come back empty.
        guard !isCalculating, !isSearchingGas else { return }
        suggestionTask?.cancel()
        suggestionTask = Task { await refreshSuggestions() }
    }

    // MARK: - Sharing

    /// True once there's a complete ride (start + destination) worth sharing.
    var canShareRoute: Bool {
        waypoints.count >= 2
    }

    /// A serializable snapshot of the current ride — waypoints plus the
    /// suggested stops currently on screen — for sharing with other riders.
    var sharedRoute: SharedRoute {
        SharedRoute(waypoints: waypoints, suggestedStops: suggestedStops)
    }

    /// Loads a ride received from another rider via a `perfectrouter://` link,
    /// or a `.gpx` file (Files / Open In). Replaces the current waypoints.
    /// Deep-link imports preserve the sender's suggested stops; GPX imports
    /// map `<wpt>` into plan waypoints and recalculate suggestions.
    /// Returns `false` if the URL isn't a valid shared route or GPX.
    @discardableResult
    func importRoute(from url: URL) -> Bool {
        if let shared = SharedRoute(url: url) {
            return applyImportedRoute(
                waypoints: shared.waypoints,
                suggestedStops: shared.suggestedStops,
                category: shared.suggestionCategory
            )
        }
        return importGPX(from: url)
    }

    /// Writes the current plan to a temporary `.gpx` for the share sheet.
    /// Includes a `<trk>` when route legs already have a polyline; otherwise
    /// waypoints-only. Returns `nil` when the plan isn't shareable.
    func makeGPXFileURL(date: Date = Date()) -> URL? {
        guard canShareRoute else { return nil }
        let track = legs.flatMap { RouteGeometry.coordinates(of: $0.polyline) }
        let data = GPXCodec.encode(
            waypoints: waypoints,
            trackCoordinates: track,
            name: defaultRouteName,
            date: date
        )
        let filename = GPXCodec.suggestedFilename(date: date)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Loads plan waypoints from a GPX file URL (security-scoped when needed).
    @discardableResult
    func importGPX(from url: URL) -> Bool {
        let accessed = url.startAccessingSecurityScopedResource()
        defer {
            if accessed { url.stopAccessingSecurityScopedResource() }
        }
        guard let data = try? Data(contentsOf: url) else { return false }
        return importGPX(data: data)
    }

    /// Loads plan waypoints from GPX bytes. Used by file import and unit tests.
    @discardableResult
    func importGPX(data: Data) -> Bool {
        guard let document = try? GPXCodec.decode(data) else { return false }
        return applyImportedRoute(waypoints: document.waypoints, suggestedStops: [], category: nil)
    }

    /// Shared apply path for deep-link and GPX imports.
    @discardableResult
    private func applyImportedRoute(
        waypoints imported: [Waypoint],
        suggestedStops importedSuggestions: [SuggestedStop],
        category: StopCategory?
    ) -> Bool {
        // Drop any malformed (invalid / NaN) coordinates; a ride still needs a
        // start and a destination to be routable.
        let importedWaypoints = imported.filter { $0.coordinate.isValidLocation }
        guard importedWaypoints.count >= 2 else { return false }
        waypoints = importedWaypoints
        let importedStops = importedSuggestions.filter { $0.coordinate.isValidLocation }
        if let category {
            selectedCategory = category
        }
        let preserveImportedSuggestions = !importedStops.isEmpty
        scheduleRecalculation(refreshingSuggestions: !preserveImportedSuggestions)
        if preserveImportedSuggestions {
            let planned = routeTask
            let calcGen = calculatingGeneration
            Task { @MainActor in
                await planned?.value
                guard calcGen == calculatingGeneration, !Task.isCancelled else { return }
                self.suggestedStops = importedStops
            }
        }
        return true
    }

    // MARK: - Saved routes

    /// A default name for the current ride, derived from its start and end.
    var defaultRouteName: String {
        guard waypoints.count >= 2,
              let start = waypoints.first?.name,
              let end = waypoints.last?.name else {
            return "My Route"
        }
        return "\(start) → \(end)"
    }

    /// Saves the current ride under `name` (falling back to a start→end name)
    /// so the rider can reload it later. Persists immediately.
    func saveCurrentRoute(name: String) {
        guard canShareRoute else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = SavedRoute(
            name: trimmed.isEmpty ? defaultRouteName : trimmed,
            savedAt: Date(),
            route: sharedRoute
        )
        savedRoutes.insert(saved, at: 0)
        savedRouteStore.save(savedRoutes)
    }

    /// Records the current ride in the history log when the rider hands off to
    /// navigation, then captures an offline route snapshot in the background.
    func logCurrentRide() {
        guard waypoints.count >= 2, !legs.isEmpty else { return }
        let entry = RideLogEntry(
            name: defaultRouteName,
            date: Date(),
            distanceMeters: totalDistanceMeters,
            durationSeconds: totalExpectedTravelTime,
            stopCount: waypoints.count
        )
        rideLogStore.append(entry)

        let legsToCapture = legs
        let entryID = entry.id
        let store = rideLogStore
        Task {
            if let filename = await RouteSnapshotter.captureSnapshot(legs: legsToCapture) {
                store.updateSnapshot(id: entryID, filename: filename)
            }
        }
    }

    /// Loads a previously saved ride, replacing the current waypoints. Its
    /// suggested stops are restored as-is; if none were saved, fresh ones are
    /// generated. Mirrors `importRoute(from:)`.
    func loadSavedRoute(_ saved: SavedRoute) {
        let loadedWaypoints = saved.route.waypoints.filter { $0.coordinate.isValidLocation }
        guard loadedWaypoints.count >= 2 else { return }
        waypoints = loadedWaypoints
        let savedStops = saved.route.suggestedStops.filter { $0.coordinate.isValidLocation }
        if let category = saved.route.suggestionCategory {
            selectedCategory = category
        }
        let preserveSavedSuggestions = !savedStops.isEmpty
        scheduleRecalculation(refreshingSuggestions: !preserveSavedSuggestions)
        if preserveSavedSuggestions {
            let planned = routeTask
            let calcGen = calculatingGeneration
            Task { @MainActor in
                await planned?.value
                guard calcGen == calculatingGeneration, !Task.isCancelled else { return }
                suggestedStops = savedStops
            }
        }
    }

    func deleteSavedRoutes(at offsets: IndexSet) {
        savedRoutes.remove(atOffsets: offsets)
        savedRouteStore.save(savedRoutes)
    }

    // MARK: - Rider groups

    /// Creates a new, empty rider group with the given name (falling back to a
    /// default) and persists it. Returns the created group.
    @discardableResult
    func createRiderGroup(name: String) -> RiderGroup {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = RiderGroup(name: trimmed.isEmpty ? "New Group" : trimmed)
        riderGroups.append(group)
        riderGroupStore.save(riderGroups)
        return group
    }

    func deleteRiderGroups(at offsets: IndexSet) {
        riderGroups.remove(atOffsets: offsets)
        riderGroupStore.save(riderGroups)
    }

    /// Renames the group with the given id, ignoring blank names.
    func renameRiderGroup(id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = riderGroups.firstIndex(where: { $0.id == id }) else { return }
        riderGroups[index].name = trimmed
        riderGroupStore.save(riderGroups)
    }

    /// Adds a rider to the group with the given id, skipping exact duplicate
    /// phone numbers so the same person isn't messaged twice.
    func addRider(_ rider: Rider, toGroup id: UUID) {
        guard let index = riderGroups.firstIndex(where: { $0.id == id }) else { return }
        let normalized = rider.phoneNumber.filter(\.isNumber)
        let alreadyPresent = riderGroups[index].riders.contains {
            $0.phoneNumber.filter(\.isNumber) == normalized
        }
        guard !alreadyPresent else { return }
        riderGroups[index].riders.append(rider)
        riderGroupStore.save(riderGroups)
    }

    func removeRiders(at offsets: IndexSet, fromGroup id: UUID) {
        guard let index = riderGroups.firstIndex(where: { $0.id == id }) else { return }
        riderGroups[index].riders.remove(atOffsets: offsets)
        riderGroupStore.save(riderGroups)
    }

    /// The current state of a group by id (groups can be edited while a detail
    /// view is open), or `nil` if it has since been deleted.
    func riderGroup(id: UUID) -> RiderGroup? {
        riderGroups.first { $0.id == id }
    }

    /// The body for a Messages invite: the route summary plus the deep link.
    func rideInviteMessage() -> String {
        let route = sharedRoute
        guard let url = route.shareURL else { return route.shareMessage }
        return "\(route.shareMessage)\n\(url.absoluteString)"
    }

    // MARK: - Search (for adding waypoints by name)

    func searchPlaces(query: String, near region: MKCoordinateRegion) async -> [MKMapItem] {
        if let placeSearchOverride {
            return await placeSearchOverride.searchPlaces(query: query, near: region)
        }
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region
        let response = try? await MKLocalSearch(request: request).start()
        return response?.mapItems ?? []
    }

    // MARK: - Contacts

    /// Forward-geocodes a postal address picked from the rider's contacts and
    /// adds it as a waypoint. Surfaces an error (rather than failing silently)
    /// when the address can't be located. Returns the added waypoint, or `nil`.
    @discardableResult
    func addWaypoint(named name: String, at postalAddress: CNPostalAddress) async -> Waypoint? {
        let query = ContactLabel.mailingAddress(postalAddress)
        guard !query.isEmpty else {
            errorMessage = "That contact has no usable address."
            return nil
        }
        // Structured postal geocode first; fall back to the formatted string
        // so sparse simulator contacts still resolve.
        let geocoder = CLGeocoder()
        var placemarks = try? await geocoder.geocodePostalAddress(postalAddress)
        if placemarks?.contains(where: { $0.location?.coordinate.isValidLocation == true }) != true {
            placemarks = try? await geocoder.geocodeAddressString(query)
        }
        guard let coordinate = placemarks?.first?.location?.coordinate,
              coordinate.isValidLocation else {
            errorMessage = "Couldn't find a location for \(name)."
            return nil
        }
        let waypoint = Waypoint(name: name, coordinate: coordinate)
        addWaypoint(waypoint)
        return waypoint
    }
}
