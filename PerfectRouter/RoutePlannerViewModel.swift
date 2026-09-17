import Contacts
import Foundation
import MapKit
import Observation
import SwiftUI

@MainActor
@Observable
final class RoutePlannerViewModel: NSObject, CLLocationManagerDelegate {

    // MARK: - Published state

    /// Ordered ride: first = start, last = destination, middle = stops.
    var waypoints: [Waypoint] = []

    /// The rider's most recent known coordinate, used to auto-seed the ride
    /// start. `nil` until a location fix arrives (or if permission is denied).
    private(set) var currentLocation: CLLocationCoordinate2D?

    /// One MKRoute per leg (waypoint i -> waypoint i+1).
    var legs: [MKRoute] = []

    /// Recommended stops for the currently selected category.
    var suggestedStops: [SuggestedStop] = []

    var selectedCategory: StopCategory = .gas
    var isCalculating = false
    var isLoadingSuggestions = false
    var errorMessage: String?

    /// Rider's fuel range in meters (default ~100 miles).
    var fuelRangeMeters: CLLocationDistance = 160_900

    /// How routes are biased — fastest, avoiding highways, or scenic (Apple alternates).
    var routeStyle: RouteStyle = .fastest

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

    /// Cancels any in-flight recalculation and starts a fresh one.
    private func scheduleRecalculation(refreshingSuggestions: Bool = true) {
        routeTask?.cancel()
        routeTask = Task { await recalculateRoute(refreshingSuggestions: refreshingSuggestions) }
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
            // Tank miles changed the search grid — find gas/food at the new
            // intervals instead of re-picking from a 25-mile sample set.
            Task { await refreshGasStations() }
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
        legs.reduce(0) { $0 + $1.distance }
    }

    var totalExpectedTravelTime: TimeInterval {
        legs.reduce(0) { $0 + $1.expectedTravelTime }
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
    /// Travel-side only.
    var fuelStops: [SuggestedStop] = []

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

    /// Sets when the rider plans to leave (`nil` = now) and re-checks the
    /// route's weather against the new time of passing each point. Also
    /// re-picks fuel stops so meal-time food preference follows the new ETAs.
    func setDeparture(_ date: Date?) {
        guard date != departureDate else { return }
        departureDate = date
        replanFuelStops()
        Task { await refreshWeather() }
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
        // Insert before the final destination so the ride still ends
        // where the rider intended.
        let waypoint = Waypoint(
            name: suggestion.name,
            coordinate: suggestion.coordinate,
            isGasFill: suggestion.category == .gas
        )
        if waypoints.count >= 2 {
            waypoints.insert(waypoint, at: waypoints.count - 1)
        } else {
            waypoints.append(waypoint)
        }
        scheduleRecalculation()
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

    /// One MKDirections request per consecutive pair of waypoints,
    /// giving a full multi-stop route.
    func recalculateRoute(refreshingSuggestions: Bool = true) async {
        suggestedStops = []
        errorMessage = nil
        rainForecast = nil

        guard waypoints.count >= 2 else {
            legs = []
            clearStopRecommendations()
            await weatherNotifier.updateRainWarning(nil)
            return
        }

        isCalculating = true
        defer { isCalculating = false }

        var newLegs: [MKRoute] = []

        for i in 0..<(waypoints.count - 1) {
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[i].coordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: waypoints[i + 1].coordinate))
            request.transportType = .automobile
            // Let MapKit factor predicted traffic for the planned departure
            // into the route choice and travel-time estimates.
            request.departureDate = effectiveDeparture
            // Bias the route to the rider's chosen style.
            request.highwayPreference = routeStyle.avoidsHighways ? .avoid : .any
            request.tollPreference = routeStyle.avoidsTolls ? .avoid : .any
            // Scenic rides ask for alternates so we can pick the most scenic one.
            request.requestsAlternateRoutes = routeStyle.prefersAlternates

            do {
                let response = try await MKDirections(request: request).calculate()
                // MKDirections isn't cancellation-aware, so a superseded
                // recalculation still gets its response — drop it here rather
                // than let stale legs overwrite the newer plan's results.
                guard !Task.isCancelled else { return }
                guard let route = Self.preferredRoute(from: response.routes, style: routeStyle) else {
                    errorMessage = "No route found between \(waypoints[i].name) and \(waypoints[i + 1].name)."
                    legs = []
                    clearStopRecommendations()
                    return
                }
                newLegs.append(route)
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "Routing failed: \(error.localizedDescription)"
                legs = []
                clearStopRecommendations()
                return
            }
        }

        guard !Task.isCancelled else { return }
        legs = newLegs
        // Fuel first so the tank-interval gas search is not starved by the
        // category-chip MKLocalSearch budget (16 lookups at searchIntervalMiles).
        await refreshGasStations()
        if refreshingSuggestions {
            await refreshSuggestions()
        }
        await refreshHighlights()
        await refreshWeather()
    }

    /// Changes the route style, remembers it as the rider's new default, and
    /// re-plans the current ride so the change is reflected immediately.
    func setRouteStyle(_ style: RouteStyle) {
        guard style != routeStyle else { return }
        routeStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: AppSettings.Keys.routeStyle)
        scheduleRecalculation()
    }

    /// Picks which of MapKit's returned routes to use for a leg. For scenic
    /// rides we prefer a route that avoids highways, and among those the longest
    /// — back-roads detours tend to be the more scenic option. Otherwise we take
    /// MapKit's top recommendation.
    nonisolated static func preferredRoute(from routes: [MKRoute], style: RouteStyle) -> MKRoute? {
        guard style.prefersAlternates else { return routes.first }
        let withoutHighways = routes.filter { !$0.hasHighways }
        let candidates = withoutHighways.isEmpty ? routes : withoutHighways
        return candidates.max(by: { $0.distance < $1.distance }) ?? routes.first
    }

    // MARK: - Weather

    /// Checks the route for rain at the rider's expected time of passing.
    /// Degrades silently (no warning, no spinner) if WeatherKit is unavailable.
    func refreshWeather() async {
        guard !legs.isEmpty else {
            rainForecast = nil
            await weatherNotifier.updateRainWarning(nil)
            return
        }
        guard RouteWeatherService.isEnabled else {
            rainForecast = nil
            await weatherNotifier.updateRainWarning(nil)
            return
        }
        isCheckingWeather = true
        defer { isCheckingWeather = false }
        let forecast = await weatherService.rainForecast(alongLegs: legs, departure: effectiveDeparture)
        guard !Task.isCancelled else { return }
        rainForecast = forecast
        // Surface the same warning shown on screen as a local notification so
        // the rider is alerted even if they've stopped looking at the app.
        await weatherNotifier.updateRainWarning(rainWarning)
    }

    // MARK: - Gas stations & automatic fuel planning

    /// Finds every gas station along the route (independent of the selected
    /// category) so the rider can pick any of them, then plans which ones to
    /// recommend as fuel stops.
    /// Clears every route-derived stop recommendation, so a cleared or failed
    /// route doesn't leave stale pins and rows behind.
    private func clearStopRecommendations() {
        gasStations = []
        travelSideGasStations = []
        gasStopsWithFood = []
        fuelStops = []
        hasFuelGap = false
        fuelFoodStops = []
        pairedFuelStopIDs = []
        rideHighlights = []
        isShowingAllGasOnRoute = false
    }

    func refreshGasStations() async {
        guard !legs.isEmpty else {
            gasStations = []
            travelSideGasStations = []
            gasStopsWithFood = []
            fuelStops = []
            hasFuelGap = false
            fuelFoodStops = []
            pairedFuelStopIDs = []
            return
        }

        // Search gas (and food) in every tank window along the whole route.
        // Wider corridor than the chip-suggestion 5 mi so pumps not sitting
        // on the exact interval point still enter the candidate pool.
        let sampleDistances = Self.fuelSearchDistances(
            totalDistance: totalDistanceMeters,
            range: fuelRangeMeters
        )
        let found = await suggestionService.findStops(
            category: .gas,
            alongLegs: legs,
            sampleDistances: sampleDistances,
            corridorRadiusMeters: Self.fuelSearchCorridorMeters
        )
        guard !Task.isCancelled else { return }
        gasStations = found

        // Recommendations only consider stops on the rider's side of travel.
        travelSideGasStations = gasStations.filter {
            RouteGeometry.isOnTravelSide($0.coordinate, along: legs)
        }

        let foodAlongRoute = await suggestionService.findStops(
            category: .food,
            alongLegs: legs,
            sampleDistances: sampleDistances,
            corridorRadiusMeters: Self.fuelSearchCorridorMeters
        )
        guard !Task.isCancelled else { return }
        gasStopsWithFood = Self.gasStopsWithNearbyFood(
            travelSideGasStations,
            food: foodAlongRoute
        )

        replanFuelStops()
        await refreshFoodNearFuelStops()
    }

    /// Re-selects the recommended fuel stops from the already-computed
    /// travel-side gas stations, e.g. after a fill is added. Cheap when the
    /// tank-interval search has already run — no network.
    func replanFuelStops() {
        guard totalDistanceMeters > fuelRangeMeters else {
            fuelStops = []
            hasFuelGap = false
            fuelFoodStops = []
            pairedFuelStopIDs = []
            return
        }
        let plan = Self.planFuelStops(
            from: travelSideGasStations,
            totalDistance: totalDistanceMeters,
            range: fuelRangeMeters,
            filledAt: gasFillDistances,
            preferringFoodAt: gasStopsWithFood,
            departure: effectiveDeparture,
            totalTravelTime: totalExpectedTravelTime
        )
        fuelStops = plan.stops
        hasFuelGap = plan.hasGap
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
    /// safety buffer so the rider isn't running on fumes (~85% = ~15% reserve).
    nonisolated static let fuelSafetyFactor = 0.85

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
    /// is empty, fall back to the hard range. A dry stretch flags `hasGap`
    /// and advances one tank so later windows along the route are still planned.
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
        guard range > 0, totalDistance > range else { return ([], false) }

        let comfortRange = range * safetyFactor
        let sorted = gasStops.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        var chosen: [SuggestedStop] = []
        var hasGap = false
        // Rider-added gas stops count as fills; later pumps plan from the last one.
        var lastRefuel: CLLocationDistance = max(0, filledAt.max() ?? 0)

        // Keep refueling until the remaining distance fits within one tank.
        while totalDistance - lastRefuel > range {
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

            // Farthest station within the comfort window (~85%); hard range
            // only if that window is empty. Food is a meal-time preference,
            // not a gate — off-meal we keep the tank-interval gas pick.
            let farthest: (CLLocationDistance) -> SuggestedStop? = { limit in
                let inWindow = sorted.filter {
                    $0.distanceAlongRoute > lastRefuel && $0.distanceAlongRoute <= lastRefuel + limit
                }
                let withFood = (preferFoodForMeal && !preferringFoodAt.isEmpty)
                    ? inWindow.filter { preferringFoodAt.contains($0.id) }
                    : []
                let pool = withFood.isEmpty ? inWindow : withFood
                return pool.max(by: { $0.distanceAlongRoute < $1.distanceAlongRoute })
            }

            if let stop = farthest(comfortRange) ?? farthest(range) {
                chosen.append(stop)
                lastRefuel = stop.distanceAlongRoute
                continue
            }

            // Dry stretch — keep walking tank-by-tank so a later pump is
            // still recommended instead of stopping at the first gap.
            hasGap = true
            let jump = lastRefuel + range
            guard jump > lastRefuel else { break }
            lastRefuel = jump
        }

        return (chosen, hasGap)
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
            guard !Task.isCancelled else { return }
            candidates = found
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
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        let found = await suggestionService.findStops(
            category: selectedCategory,
            alongLegs: legs
        )
        guard !Task.isCancelled else { return }
        suggestedStops = found
    }

    func selectCategory(_ category: StopCategory) {
        selectedCategory = category
        Task { await refreshSuggestions() }
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
    /// replacing the current waypoints. The sender's suggested stops are
    /// preserved as-is; if none were shared, fresh ones are generated.
    /// Returns `false` if the URL isn't a valid shared route.
    @discardableResult
    func importRoute(from url: URL) -> Bool {
        guard let shared = SharedRoute(url: url), shared.stops.count >= 2 else {
            return false
        }
        // Drop any malformed (invalid / NaN) coordinates from the link; a ride
        // still needs a start and a destination to be routable.
        let importedWaypoints = shared.waypoints.filter { $0.coordinate.isValidLocation }
        guard importedWaypoints.count >= 2 else { return false }
        waypoints = importedWaypoints
        let importedStops = shared.suggestedStops.filter { $0.coordinate.isValidLocation }
        if let category = shared.suggestionCategory {
            selectedCategory = category
        }
        routeTask?.cancel()
        routeTask = Task {
            await recalculateRoute(refreshingSuggestions: importedStops.isEmpty)
            guard !Task.isCancelled else { return }
            if !importedStops.isEmpty {
                suggestedStops = importedStops
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
        routeTask?.cancel()
        routeTask = Task {
            await recalculateRoute(refreshingSuggestions: savedStops.isEmpty)
            guard !Task.isCancelled else { return }
            if !savedStops.isEmpty {
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
