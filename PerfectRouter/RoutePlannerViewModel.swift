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

    /// How routes are biased — fastest, avoiding highways, or scenic back roads.
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
    /// adjustment isn't overwritten.
    func applySettings() {
        suggestionService.sampleIntervalMeters = AppSettings.searchIntervalMeters
        // Pick up a route style changed in Settings and re-plan if it differs.
        let newStyle = AppSettings.defaultRouteStyle
        if newStyle != routeStyle {
            routeStyle = newStyle
            Task { await recalculateRoute() }
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
        Task { @MainActor in currentLocation = coordinate }
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

    /// The subset of `gasStations` automatically recommended as fuel stops —
    /// roughly one per tank of fuel (`fuelRangeMeters`, ~100 mi) and limited to
    /// the side of the road matching the direction of travel.
    var fuelStops: [SuggestedStop] = []

    /// Gas stations on the rider's side of travel (no crossing oncoming
    /// traffic). Candidate pool for `fuelStops`; recomputed when the route
    /// changes, then reused when the tank range changes.
    private var travelSideGasStations: [SuggestedStop] = []

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
        waypoints.append(waypoint)
        Task { await recalculateRoute() }
    }

    /// Sets an explicit ride origin as the first waypoint. Used when there's
    /// no location fix to auto-seed the start (e.g. on the simulator, or before
    /// location permission is granted), so the rider can still plot a route.
    func addStart(_ waypoint: Waypoint) {
        guard waypoint.coordinate.isValidLocation else { return }
        waypoints.insert(waypoint, at: 0)
        Task { await recalculateRoute() }
    }

    func addStop(from suggestion: SuggestedStop) {
        guard suggestion.coordinate.isValidLocation else { return }
        // Insert before the final destination so the ride still ends
        // where the rider intended.
        let waypoint = Waypoint(name: suggestion.name, coordinate: suggestion.coordinate)
        if waypoints.count >= 2 {
            waypoints.insert(waypoint, at: waypoints.count - 1)
        } else {
            waypoints.append(waypoint)
        }
        Task { await recalculateRoute() }
    }

    func removeWaypoint(at offsets: IndexSet) {
        waypoints.remove(atOffsets: offsets)
        Task { await recalculateRoute() }
    }

    func moveWaypoint(from source: IndexSet, to destination: Int) {
        waypoints.move(fromOffsets: source, toOffset: destination)
        Task { await recalculateRoute() }
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
            // Bias the route to the rider's chosen style.
            request.highwayPreference = routeStyle.avoidsHighways ? .avoid : .any
            request.tollPreference = routeStyle.avoidsTolls ? .avoid : .any
            // Scenic rides ask for alternates so we can pick the most scenic one.
            request.requestsAlternateRoutes = routeStyle.prefersAlternates

            do {
                let response = try await MKDirections(request: request).calculate()
                guard let route = Self.preferredRoute(from: response.routes, style: routeStyle) else {
                    errorMessage = "No route found between \(waypoints[i].name) and \(waypoints[i + 1].name)."
                    legs = []
                    return
                }
                newLegs.append(route)
            } catch {
                errorMessage = "Routing failed: \(error.localizedDescription)"
                legs = []
                return
            }
        }

        legs = newLegs
        if refreshingSuggestions {
            await refreshSuggestions()
        }
        await refreshGasStations()
        await refreshWeather()
    }

    /// Changes the route style, remembers it as the rider's new default, and
    /// re-plans the current ride so the change is reflected immediately.
    func setRouteStyle(_ style: RouteStyle) {
        guard style != routeStyle else { return }
        routeStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: AppSettings.Keys.routeStyle)
        Task { await recalculateRoute() }
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
    /// Degrades silently (no warning) if WeatherKit is unavailable.
    func refreshWeather() async {
        guard !legs.isEmpty else {
            rainForecast = nil
            await weatherNotifier.updateRainWarning(nil)
            return
        }
        isCheckingWeather = true
        defer { isCheckingWeather = false }
        rainForecast = await weatherService.rainForecast(alongLegs: legs, departure: Date())
        // Surface the same warning shown on screen as a local notification so
        // the rider is alerted even if they've stopped looking at the app.
        await weatherNotifier.updateRainWarning(rainWarning)
    }

    // MARK: - Gas stations & automatic fuel planning

    /// Finds every gas station along the route (independent of the selected
    /// category) so the rider can pick any of them, then plans which ones to
    /// recommend as fuel stops.
    func refreshGasStations() async {
        guard !legs.isEmpty else {
            gasStations = []
            travelSideGasStations = []
            fuelStops = []
            hasFuelGap = false
            fuelFoodStops = []
            pairedFuelStopIDs = []
            return
        }

        // Reuse already-loaded gas suggestions when the rider is browsing gas;
        // otherwise run a dedicated gas search.
        if selectedCategory == .gas, !suggestedStops.isEmpty {
            gasStations = suggestedStops
        } else {
            gasStations = await suggestionService.findStops(category: .gas, alongLegs: legs)
        }

        // Recommendations only consider stops on the rider's side of travel.
        travelSideGasStations = gasStations.filter {
            RouteGeometry.isOnTravelSide($0.coordinate, along: legs)
        }

        replanFuelStops()
        await refreshFoodNearFuelStops()
    }

    /// Re-selects the recommended fuel stops from the already-computed
    /// travel-side gas stations, e.g. after the rider changes their tank
    /// range. Cheap — runs no network search.
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
            range: fuelRangeMeters
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

    /// Greedy fuel-stop selection. From the last fill-up, prefer the gas
    /// station as far along as possible but still within `safetyFactor` of the
    /// tank range (so there's a reserve). If no station falls in that comfort
    /// window, fall back to one within the full hard range rather than skip a
    /// refuel; only when nothing is reachable at all is a fuel gap flagged.
    /// Refuels are planned one per tank until the destination is in range.
    nonisolated static func planFuelStops(
        from gasStops: [SuggestedStop],
        totalDistance: CLLocationDistance,
        range: CLLocationDistance,
        safetyFactor: Double = fuelSafetyFactor
    ) -> (stops: [SuggestedStop], hasGap: Bool) {
        guard range > 0, totalDistance > range else { return ([], false) }

        let comfortRange = range * safetyFactor
        let sorted = gasStops.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        var chosen: [SuggestedStop] = []
        var hasGap = false
        var lastRefuel: CLLocationDistance = 0   // distance of the last fill-up

        // Keep refueling until the remaining distance fits within one tank.
        while totalDistance - lastRefuel > range {
            // Prefer the farthest station within the comfort window (~85%);
            // fall back to the hard range only if the comfort window is empty.
            let farthest: (CLLocationDistance) -> SuggestedStop? = { limit in
                sorted
                    .filter { $0.distanceAlongRoute > lastRefuel && $0.distanceAlongRoute <= lastRefuel + limit }
                    .max(by: { $0.distanceAlongRoute < $1.distanceAlongRoute })
            }

            guard let stop = farthest(comfortRange) ?? farthest(range) else {
                // No reachable gas station in this stretch — fuel gap.
                hasGap = true
                break
            }

            chosen.append(stop)
            lastRefuel = stop.distanceAlongRoute
        }

        return (chosen, hasGap)
    }

    // MARK: - Suggestions

    func refreshSuggestions() async {
        guard !legs.isEmpty else { return }
        isLoadingSuggestions = true
        defer { isLoadingSuggestions = false }
        suggestedStops = await suggestionService.findStops(
            category: selectedCategory,
            alongLegs: legs
        )
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
        Task {
            await recalculateRoute(refreshingSuggestions: importedStops.isEmpty)
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
        Task {
            await recalculateRoute(refreshingSuggestions: savedStops.isEmpty)
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
        let placemarks = try? await CLGeocoder().geocodePostalAddress(postalAddress)
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
