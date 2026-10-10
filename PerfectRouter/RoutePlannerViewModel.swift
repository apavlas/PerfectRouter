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
    var waypoints: [Waypoint] = []

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
    var legs: [MKRoute] = []

    /// Recommended stops for the currently selected category.
    var suggestedStops: [SuggestedStop] = []

    var selectedCategory: StopCategory = .gas
    var isCalculating = false
    /// Rider-facing line under the route spinner so a long Twisty plan
    /// doesn't look frozen.
    var calculationStatus: String?
    /// True while the tank-interval gas search is in flight.
    var isSearchingGas = false
    var isLoadingSuggestions = false
    var errorMessage: String?

    /// Gas stops the rider has checked but not applied. The recommendation
    /// list stays put until `applyBufferedGasStops()`.
    private(set) var bufferedGasStops: [SuggestedStop] = []

    /// Rider's fuel range in meters (default ~100 miles).
    var fuelRangeMeters: CLLocationDistance = 160_900

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
    private var plannedCorridor: [[CLLocationCoordinate2D]] = []

    private var suggestionService = StopSuggestionService()

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
    /// must not clear `isCalculating` or publish legs.
    private var calculatingGeneration = 0

    /// Bumped whenever a gas search is replaced. A superseded search must
    /// not publish an empty station list or drop `isSearchingGas`.
    private var gasGeneration = 0

    /// Distinct from "searching". Only `.empty` may say there are no stations.
    /// A cancel leaves this alone (the replacement search owns the screen).
    private(set) var gasLoadState: GasLoadState = .pending

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
            fuelStops = []
            fuelPlanEntries = []
            fuelFoodStops = []
            pairedFuelStopIDs = []
            hasFuelGap = false
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
        startTrackingIfAuthorized()

#if targetEnvironment(simulator)
        // The simulator has no GPS fix unless one is set in Features ▸ Location,
        // leaving the rider unable to auto-route from "here". Seed a sensible
        // default so route planning works out of the box on the simulator. A
        // real (simulated) location update overrides this as soon as it arrives.
        if currentLocation == nil {
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
    var gasStations: [SuggestedStop] = []

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
    var fuelStops: [SuggestedStop] = []

    /// Recommended stops, inline gap warnings, and past-range stations, in
    /// ride order. The sheet shows gap and past-range rows only when the
    /// coverage that produced them is trusted.
    var fuelPlanEntries: [FuelPlanEntry] = []

    /// Fuel rows the sheet should draw. A cancelled or throttled search
    /// keeps in-range recommendations and hides the named gap. A stop
    /// already on the route is omitted so Apply cannot add it twice.
    var visibleFuelPlanEntries: [FuelPlanEntry] {
        fuelPlanEntries.compactMap { entry in
            switch entry {
            case .recommended(let stop):
                return isStopOnRoute(stop) ? nil : entry
            case .pastRange(let stop):
                guard showsFuelGapWarning, !isStopOnRoute(stop) else { return nil }
                return entry
            case .gap:
                return showsFuelGapWarning ? entry : nil
            }
        }
    }

    /// Category suggestions the rider can still add. Places already on the
    /// route (including an applied gas stop) are left off the list.
    var addableSuggestions: [SuggestedStop] {
        suggestedStops.filter { !isStopOnRoute($0) }
    }

    /// Gas stations on the rider's side of travel (no crossing oncoming
    /// traffic). Candidate pool for `fuelStops`; recomputed when the route
    /// or tank-interval search changes.
    private var travelSideGasStations: [SuggestedStop] = []

    /// Travel-side gas stations that have food within `fuelFoodRadiusMeters`.
    /// Fed into `planFuelStops` so a pump with food wins over a gas-only
    /// neighbor in the same tank window.
    private var gasStopsWithFood: Set<UUID> = []

    /// True when the ride is longer than one tank but the route has a stretch
    /// longer than the fuel range with no gas station found.
    var hasFuelGap = false

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
    var rideHighlights: [SuggestedStop] = []

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
    private var gasCoverageTrusted = false

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

    /// True when a waypoint already sits on this place. Matching is the
    /// coordinate rounded to three decimals (~111 m), so a re-fetched pin
    /// with a new name still counts as the stop the rider applied.
    func isStopOnRoute(_ stop: SuggestedStop) -> Bool {
        waypoints.contains { Self.sameCoordinate($0.coordinate, stop.coordinate) }
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
        var placed: [(distance: CLLocationDistance, waypoint: Waypoint)] = []
        for (index, waypoint) in waypoints.enumerated() {
            let distance: CLLocationDistance
            if index == 0 {
                distance = 0
            } else if index == waypoints.count - 1 {
                distance = .greatestFiniteMagnitude
            } else if polylines.isEmpty {
                distance = totalDistance * Double(index) / Double(waypoints.count)
            } else {
                distance = RouteGeometry.distanceAlongRoute(of: waypoint.coordinate, alongPolylines: polylines)
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
        suggestedStops = []
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
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        // Let MapKit factor predicted traffic for the planned departure
        // into the route choice and travel-time estimates.
        request.departureDate = effectiveDeparture
        request.highwayPreference = avoidsHighways ? .avoid : .any
        request.tollPreference = avoidsTolls ? .avoid : .any
        request.requestsAlternateRoutes = alternates
        return try await MKDirections(request: request).calculate().routes
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
        fuelStops = []
        fuelPlanEntries = []
        hasFuelGap = false
        fuelFoodStops = []
        pairedFuelStopIDs = []
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

        let sampleDistances = Self.fuelSearchDistances(
            totalDistance: totalDistanceMeters,
            range: fuelRangeMeters
        )
        let legsAtSearch = legs
        // One extra full pass after a throttle storm. The per-sample retry
        // already waited once; this covers the case where every sample failed.
        let result = await runGasCorridorSearch(
            generation: generation,
            sampleDistances: sampleDistances,
            legs: legsAtSearch
        )
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
            gasStations = result.stops
            gasStopsWithFood = []
            applyFuelCandidatePool()
            gasLoadState = gasStations.isEmpty ? .empty : .loaded
            await refreshFoodNearFuelStops()
        }
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
            let result = await suggestionService.findStops(
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
        let travelSide = gasStations.filter {
            RouteGeometry.isOnTravelSide($0.coordinate, along: legs)
        }
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

    /// Re-selects the recommended fuel stops from the already-computed
    /// travel-side gas stations, e.g. after a fill is added. Cheap when the
    /// tank-interval search has already run — no network.
    func replanFuelStops() {
        guard totalDistanceMeters > fuelRangeMeters else {
            fuelStops = []
            fuelPlanEntries = []
            hasFuelGap = false
            fuelFoodStops = []
            pairedFuelStopIDs = []
            return
        }
        let plan = Self.fuelPlan(
            from: travelSideGasStations,
            totalDistance: totalDistanceMeters,
            range: fuelRangeMeters,
            filledAt: gasFillDistances,
            preferringFoodAt: gasStopsWithFood,
            departure: effectiveDeparture,
            totalTravelTime: totalExpectedTravelTime
        )
        fuelStops = plan.stops
        fuelPlanEntries = plan.entries
        // A dry stretch only becomes the rider-facing warning when this pool
        // came from a search that returned every sample. Departure-time meal
        // replans keep that trust bit; they do not invent a gap.
        hasFuelGap = plan.hasGap && gasCoverageTrusted
        gasLog.info("fuel gap gen=\(self.gasGeneration, privacy: .public) planGap=\(plan.hasGap, privacy: .public) trusted=\(self.gasCoverageTrusted, privacy: .public) show=\(self.hasFuelGap, privacy: .public)")
        // Re-pair food when the range slider changes the chosen stops. The
        // identity guard inside makes this a no-op (no network) when the set
        // of stops is unchanged.
        Task { await refreshFoodNearFuelStops() }
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
            let food = await suggestionService.findFood(
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
    nonisolated static let fuelSearchCorridorMeters: CLLocationDistance = 24_000

    /// How many lookups to keep inside each tank window after every tank
    /// edge along the route has a sample.
    nonisolated static let fuelSearchSamplesPerTank = 3

    /// Distances along the route at which to search for gas and food.
    /// Every tank interval on the ride gets at least one sample (the comfort
    /// edge). Remaining budget fills intra-window points. Later tanks are
    /// never dropped to make room for extra samples on earlier tanks.
    nonisolated static func fuelSearchDistances(
        totalDistance: CLLocationDistance,
        range: CLLocationDistance,
        safetyFactor: Double = fuelSafetyFactor,
        maxCount: Int = 32,
        samplesPerTank: Int = fuelSearchSamplesPerTank
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

        // One sample per tank along the whole route first. Only if that
        // already exceeds the cap do we thin — still keeping first and last.
        if edges.count >= maxCount {
            return spacedDistances(edges, max: maxCount)
        }

        var extras: [CLLocationDistance] = []
        let divisions = max(samplesPerTank, 1)
        for edge in edges {
            let start = edge - interval
            if divisions > 1 {
                for i in 1..<divisions {
                    let d = start + interval * Double(i) / Double(divisions)
                    if d > 0, d < totalDistance {
                        extras.append(d)
                    }
                }
            }
        }
        if let last = edges.last, last < totalDistance {
            let tail = (last + totalDistance) / 2
            extras.append(tail)
        }

        var picked = edges
        for extra in extras {
            guard picked.count < maxCount else { break }
            picked.append(extra)
        }
        return picked.sorted()
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
    private var gasFillDistances: [CLLocationDistance] {
        guard !legs.isEmpty else { return [] }
        return waypoints
            .filter(\.isGasFill)
            .map { RouteGeometry.distanceAlongRoute(of: $0.coordinate, along: legs) }
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
    /// along as possible but still within `safetyFactor` of the tank range
    /// (so there's a reserve). Food is optional: when the tank-interval ETA
    /// is near breakfast / lunch / dinner *and* `preferringFoodAt` lists an
    /// in-window pump, that pump wins over gas-only in the same window.
    /// Off-meal or missing food never skips the stop. If the comfort window
    /// is empty, fall back to the hard range.
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
        calendar: Calendar = .current
    ) -> FuelPlan {
        guard range > 0, totalDistance > range else {
            return FuelPlan(stops: [], entries: [], hasGap: false)
        }

        let comfortRange = range * safetyFactor
        let minimumSeparation = range * minimumSeparationFactor
        let sorted = gasStops.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        var recommended: [SuggestedStop] = []
        var entries: [FuelPlanEntry] = []
        var skippedNear = Set<UUID>()
        // Rider-added gas stops count as fills; later pumps plan from the last one.
        var lastRefuel: CLLocationDistance = max(0, filledAt.max() ?? 0)
        var steps = 0
        let stepLimit = max(sorted.count * 3, 1) + 4

        func inWindow(_ limit: CLLocationDistance) -> [SuggestedStop] {
            sorted.filter {
                $0.distanceAlongRoute > lastRefuel
                    && $0.distanceAlongRoute <= lastRefuel + limit
                    && !skippedNear.contains($0.id)
            }
        }

        // Farthest station within the window. Food is a meal-time preference,
        // not a gate — off-meal we keep the tank-interval gas pick.
        func farthest(_ limit: CLLocationDistance, preferFood: Bool) -> SuggestedStop? {
            let window = inWindow(limit)
            let withFood = (preferFood && !preferringFoodAt.isEmpty)
                ? window.filter { preferringFoodAt.contains($0.id) }
                : []
            let pool = withFood.isEmpty ? window : withFood
            return pool.max(by: { $0.distanceAlongRoute < $1.distanceAlongRoute })
        }

        /// A short hop is worth taking when the destination, or some later
        /// station, sits past the current tank but inside the tank measured
        /// from this stop.
        func extendsReach(_ stop: SuggestedStop) -> Bool {
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

        func nextStation(after distance: CLLocationDistance) -> SuggestedStop? {
            sorted.first { $0.distanceAlongRoute > distance }
        }

        func appendGap(from start: CLLocationDistance, to end: CLLocationDistance) {
            guard end - start > range else { return }
            entries.append(.gap(FuelGap(fromMeters: start, toMeters: end, rangeMeters: range)))
        }

        // Keep refueling until the remaining distance fits within one tank.
        while totalDistance - lastRefuel > range {
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

            if let stop = farthest(comfortRange, preferFood: preferFoodForMeal)
                ?? farthest(range, preferFood: preferFoodForMeal) {
                let hop = stop.distanceAlongRoute - lastRefuel
                if hop < minimumSeparation, !extendsReach(stop) {
                    skippedNear.insert(stop.id)
                    // Nothing else inside the tank. The dry stretch starts
                    // after this last reachable station, not after the
                    // previous fill that made the hop look short.
                    if farthest(range, preferFood: false) == nil {
                        let next = nextStation(after: stop.distanceAlongRoute)
                        let end = next?.distanceAlongRoute ?? totalDistance
                        appendGap(from: stop.distanceAlongRoute, to: end)
                        if let next {
                            entries.append(.pastRange(next))
                            lastRefuel = next.distanceAlongRoute
                            skippedNear.removeAll()
                            continue
                        }
                        break
                    }
                    continue
                }
                recommended.append(stop)
                entries.append(.recommended(stop))
                lastRefuel = stop.distanceAlongRoute
                skippedNear.removeAll()
                continue
            }

            // Nothing within range of the last fill. Name the stretch and
            // keep the far station on the list as past range, then plan
            // the tanks after it. Recommending it as "Fuel stop N" is how
            // a 100-mile tank showed its first stop at mile 801.
            let next = nextStation(after: lastRefuel)
            let end = next?.distanceAlongRoute ?? totalDistance
            appendGap(from: lastRefuel, to: end)
            if let next {
                entries.append(.pastRange(next))
                lastRefuel = next.distanceAlongRoute
                skippedNear.removeAll()
                continue
            }
            break
        }

        let hasGap = entries.contains { entry in
            if case .gap = entry { return true }
            return false
        }
        return FuelPlan(stops: recommended, entries: entries, hasGap: hasGap)
    }

    // MARK: - Ride highlights (places of interest)

    /// Finds places of interest along the route and picks a handful worth
    /// stopping at — low-detour sights spread across the ride. Mirrors the
    /// fuel-stop pipeline: search wide, then select with pure logic.
    func refreshHighlights() async {
        guard !legs.isEmpty else {
            rideHighlights = []
            return
        }

        // Reuse already-loaded sights when the rider is browsing that
        // category; otherwise run a dedicated (smaller) search — highlights
        // are a bonus, so they get half the usual search budget to keep the
        // per-route MKLocalSearch load down.
        let candidates: [SuggestedStop]
        if selectedCategory == .attraction, !suggestedStops.isEmpty {
            candidates = suggestedStops
        } else {
            var service = suggestionService
            service.maxSearches = suggestionService.maxSearches / 2
            let found = await service.findStops(category: .attraction, alongLegs: legs)
            guard !Task.isCancelled, found.status == .completed else { return }
            candidates = found.stops
        }

        rideHighlights = Self.selectHighlights(
            from: candidates,
            totalDistance: totalDistanceMeters
        )
    }

    /// Whether a stop is one of the auto-recommended ride highlights.
    func isRideHighlight(_ stop: SuggestedStop) -> Bool {
        rideHighlights.contains { $0.id == stop.id }
    }

    /// Pure selection of ride highlights from the places of interest found
    /// near the route. A good stop is one that barely interrupts the ride:
    /// candidates more than `maxDetourMeters` off the route are dropped, as
    /// are ones essentially at the start or destination (the rider is already
    /// there). The rest are taken smallest-detour-first, keeping stops at
    /// least `minSeparationMeters` apart so the picks spread across the ride
    /// instead of clustering in one town. Returned in ride order.
    nonisolated static func selectHighlights(
        from candidates: [SuggestedStop],
        totalDistance: CLLocationDistance,
        maxCount: Int = 4,
        maxDetourMeters: CLLocationDistance = 3_000,
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

    func refreshSuggestions() async {
        guard !legs.isEmpty else { return }
        suggestionGeneration += 1
        let generation = suggestionGeneration
        isLoadingSuggestions = true
        defer {
            if generation == suggestionGeneration {
                isLoadingSuggestions = false
            }
        }
        let found = await suggestionService.findStops(
            category: selectedCategory,
            alongLegs: legs
        )
        // A throttle or a cancel must not replace the list with [] and read
        // as "no stops". Only a completed search publishes.
        guard generation == suggestionGeneration, !Task.isCancelled, found.status == .completed else { return }
        suggestedStops = found.stops
        // Gas-chip hits (often the only pumps MapKit returns on a long
        // interstate) feed the same tank-interval planner as the fuel search.
        if selectedCategory == .gas {
            applyFuelCandidatePool()
        }
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
