import Foundation
import MapKit
import os

/// Console log for corridor searches. Subsystem `com.apavlas.PerfectRouter`,
/// category `gas` — filter the Xcode console on that category.
private let gasLog = Logger(subsystem: "com.apavlas.PerfectRouter", category: "gas")

/// How a corridor search ended. An empty stop list is not a status: cancellation
/// and an all-failed (including throttled) run must not look like "no stations".
enum GasSearchStatus: Equatable {
    /// Every sample returned, or a partial run still found stations.
    /// Zero stops here means the corridor was fully searched and had none.
    case completed
    /// Nothing to publish: every sample errored, a partial run found no
    /// stations, or there was nothing to search. Not an empty corridor.
    case failed
    /// The task was cancelled or superseded. The caller must publish nothing.
    case cancelled

    /// `stopCount` is required. One successful response among throttled
    /// samples is not a finished corridor: if it contributed no stations,
    /// the run failed. Stations from a partial run are a real result.
    static func resolve(_ tally: GasSampleTally, stopCount: Int) -> GasSearchStatus {
        if tally.cancelled { return .cancelled }
        let incomplete = tally.failed > 0 || tally.throttled > 0
        if stopCount > 0, tally.succeeded > 0 {
            return .completed
        }
        if tally.succeeded > 0, !incomplete {
            return .completed
        }
        // No stations, and at least one sample never returned (throttle,
        // transport error, or nothing to search). That is not an empty road.
        return .failed
    }
}

struct GasSampleTally: Equatable {
    var succeeded: Int = 0
    var failed: Int = 0
    var throttled: Int = 0
    var cancelled: Bool = false
}

/// What the current gas-search owner is allowed to write. A mismatched
/// generation or a cancel is `.drop` even when the stop list is empty —
/// that empty list is not an answer.
enum GasPublish: Equatable {
    case drop
    case loaded
    case empty
    case failed

    var logName: String {
        switch self {
        case .drop: return "drop"
        case .loaded: return "loaded"
        case .empty: return "empty"
        case .failed: return "failed"
        }
    }

    static func decide(
        generation: Int,
        currentGeneration: Int,
        taskCancelled: Bool,
        status: GasSearchStatus,
        stopCount: Int
    ) -> GasPublish {
        if taskCancelled || generation != currentGeneration || status == .cancelled {
            return .drop
        }
        switch status {
        case .cancelled:
            return .drop
        case .failed:
            return .failed
        case .completed:
            return stopCount == 0 ? .empty : .loaded
        }
    }
}

struct CorridorSearchResult {
    var stops: [SuggestedStop]
    var status: GasSearchStatus
    var succeeded: Int
    var failed: Int
    var throttled: Int
    /// Sample mile-marks that errored or were throttled after retries.
    /// Those stretches were not searched. They are not empty road.
    var failedSampleDistances: [CLLocationDistance] = []

    init(
        stops: [SuggestedStop],
        status: GasSearchStatus,
        succeeded: Int,
        failed: Int,
        throttled: Int,
        failedSampleDistances: [CLLocationDistance] = []
    ) {
        self.stops = stops
        self.status = status
        self.succeeded = succeeded
        self.failed = failed
        self.throttled = throttled
        self.failedSampleDistances = failedSampleDistances
    }
}

/// MKLocalSearch allows about 50 requests per minute. A coast-to-coast
/// fuel grid that fires faster than that loses the later samples, and the
/// planner then treats the hole as a road with no gas.
enum MapSearchPace {
    static let maxRequestsPerWindow = 40
    static let window: TimeInterval = 60

    /// How long to wait before another request. Zero while the rolling
    /// window still has room.
    static func delay(
        recent: [Date],
        now: Date,
        limit: Int = maxRequestsPerWindow,
        window: TimeInterval = window
    ) -> TimeInterval {
        guard limit > 0, window > 0 else { return 0 }
        let alive = recent.filter { now.timeIntervalSince($0) < window }
        guard alive.count >= limit, let oldest = alive.min() else { return 0 }
        return max(0, window - now.timeIntervalSince(oldest)) + 0.05
    }

    /// Backoff after `MKError.loadingThrottled`. Attempt 1 waits 2 seconds,
    /// then 4, then 8. A 120 ms pause does not clear Apple's window.
    static func throttleBackoff(attempt: Int) -> Duration {
        let seconds = min(8.0, pow(2.0, Double(max(attempt, 1))))
        return .seconds(seconds)
    }
}

/// Serial gate so gas, densify, and highlight lookups share one rate window.
private actor MapSearchGate {
    static let shared = MapSearchGate()
    private var attempts: [Date] = []

    func prepare() async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let wait = MapSearchPace.delay(recent: attempts, now: Date())
            if wait <= 0 { break }
            let nanos = UInt64(min(wait, 120) * 1_000_000_000)
            do {
                try await Task.sleep(nanoseconds: nanos)
            } catch {
                return false
            }
        }
        attempts.append(Date())
        let cutoff = Date().addingTimeInterval(-(MapSearchPace.window + 1))
        attempts.removeAll { $0 < cutoff }
        return !Task.isCancelled
    }
}

/// Finds recommended stops (gas, food, etc.) along a calculated route.
///
/// Strategy:
/// 1. Sample points along the route polyline — either every
///    `sampleIntervalMeters` (Settings suggestion density) or at caller-supplied
///    tank-interval distances (fuel planning).
/// 2. Run an MKLocalSearch for the category around each sampled point.
/// 3. Keep results within `corridorRadiusMeters` of the route and de-duplicate.
struct StopSuggestionService {

    /// How far apart route sample points are (meters). Larger = fewer searches.
    var sampleIntervalMeters: CLLocationDistance = 40_000   // ~25 mi

    /// How far off the route a result may be and still count (meters).
    var corridorRadiusMeters: CLLocationDistance = 8_000    // ~5 mi

    /// Upper bound on MKLocalSearch requests per category lookup. Caps load on
    /// long rides (MKLocalSearch throttles rapid-fire requests), but unlike a
    /// head-of-route truncation the searches are spread across the whole route.
    var maxSearches = 16

    /// Pause between searches to stay under MKLocalSearch's rate limit.
    var interSearchDelay: Duration = .milliseconds(120)

    /// `MKError.loadingThrottled`. A long ride fires dozens of corridor
    /// queries; MapKit refuses the rest. That refusal is not "no results".
    static func isMapSearchThrottled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == MKErrorDomain
            && nsError.code == MKError.Code.loadingThrottled.rawValue
    }

    /// Find stops of one category along the given routes (one route per leg).
    ///
    /// When `sampleDistances` is provided, searches run at those route
    /// distances (fuel planning already capped per tank). Those points are
    /// not downsampled again by `maxSearches`, so later tanks stay covered.
    /// Otherwise samples use `sampleIntervalMeters` (Settings density).
    ///
    /// An empty `stops` array is not an answer by itself. Callers must read
    /// `status`: `.cancelled` and `.failed` (every sample errored, or a
    /// partial run that found nothing) must not be shown as "no stations".
    func findStops(
        category: StopCategory,
        alongLegs legs: [MKRoute],
        sampleDistances: [CLLocationDistance]? = nil,
        corridorRadiusMeters: CLLocationDistance? = nil,
        generation: Int = 0,
        routePolylines: [[CLLocationCoordinate2D]]? = nil
    ) async -> CorridorSearchResult {
        let corridor = corridorRadiusMeters ?? self.corridorRadiusMeters
        // Prefer coordinates the caller already copied on the main actor.
        // Reading `MKPolyline` again from this search can return an empty
        // line, and every stop then projects to 0 m.
        let supplied = routePolylines ?? []
        let legPolylines = supplied.contains(where: { RouteGeometry.length(of: $0) > 1 })
            ? supplied
            : legs.map { RouteGeometry.coordinates(of: $0.polyline) }
        let samples: [RouteSample]
        if let sampleDistances {
            // Caller chose the grid (one set of points per tank along the
            // whole route). Searching all of them keeps later windows filled.
            let targets = sampleDistances.filter { $0 >= 0 }.sorted()
            let coords = RouteGeometry.coordinates(
                alongPolylines: legPolylines,
                atDistances: targets
            )
            let count = min(coords.count, targets.count)
            let routeOrder = (0..<count).map {
                RouteSample(coordinate: coords[$0], distanceAlongRoute: targets[$0])
            }
            // Start and end before the middle. A throttle storm then drops
            // the center of the ride, not the last tanks on a coast-to-coast run.
            samples = Self.endsFirst(routeOrder)
        } else {
            // Walk the polyline copied on the main actor. Reading `MKPolyline`
            // again from this search can come back empty, and every sample
            // then sits on the origin ("~0 mi from start").
            let alongRoute = samplePoints(alongPolylines: legPolylines)
            let walked = alongRoute.isEmpty ? samplePoints(alongLegs: legs) : alongRoute
            samples = evenlySpaced(walked, max: maxSearches)
        }
        var seen = Set<String>()          // de-dup by name + rounded coords
        var results: [SuggestedStop] = []
        var tally = GasSampleTally()
        var failedSampleDistances: [CLLocationDistance] = []

        if samples.isEmpty {
            gasLog.error("search has no samples gen=\(generation, privacy: .public) category=\(category.rawValue, privacy: .public)")
            return CorridorSearchResult(
                stops: [],
                status: .failed,
                succeeded: 0,
                failed: 0,
                throttled: 0
            )
        }

        for (index, sample) in samples.enumerated() {
            if Task.isCancelled {
                tally.cancelled = true
                break
            }
            if index > 0 {
                let paused = await Self.pause(interSearchDelay)
                if !paused {
                    tally.cancelled = true
                    break
                }
            }
            if Task.isCancelled {
                tally.cancelled = true
                break
            }

            let outcome = await Self.querySample(
                category: category,
                coordinate: sample.coordinate,
                corridor: corridor,
                index: index,
                generation: generation
            )
            switch outcome {
            case .cancelled:
                tally.cancelled = true
            case .throttled:
                tally.throttled += 1
                failedSampleDistances.append(sample.distanceAlongRoute)
            case .failed:
                tally.failed += 1
                failedSampleDistances.append(sample.distanceAlongRoute)
            case .hit(let response):
                tally.succeeded += 1
                let keptBefore = results.count
                let sampleLocation = CLLocation(latitude: sample.coordinate.latitude,
                                                longitude: sample.coordinate.longitude)
                let nearestKm = response.mapItems.map {
                    CLLocation(latitude: $0.placemark.coordinate.latitude,
                               longitude: $0.placemark.coordinate.longitude).distance(from: sampleLocation)
                }.min().map { Int($0 / 1000) } ?? -1
                var items = response.mapItems
                var usedPOIFallback = false
                // MKLocalSearch treats the region as a hint: near the rider's own
                // location it can return 25 pumps around the rider instead of the
                // sample (seen 84 mi out of Atlanta: 25 items, 0 inside the
                // corridor). A points-of-interest request is bounded by radius.
                if category == .gas, nearestKm < 0 || Double(nearestKm) * 1000 > corridor {
                    if let fallback = await Self.gasPointsOfInterest(near: sample.coordinate, radius: corridor) {
                        // Merge, never replace: the corridor filter below
                        // drops whatever is off-route from either answer.
                        items = response.mapItems + fallback
                        usedPOIFallback = true
                    }
                }
                defer {
                    gasLog.info("sample hit gen=\(generation, privacy: .public) mi=\(Int(sample.distanceAlongRoute / 1609.344), privacy: .public) at=\(sample.coordinate.latitude, privacy: .public),\(sample.coordinate.longitude, privacy: .public) items=\(response.mapItems.count, privacy: .public) nearestKm=\(nearestKm, privacy: .public) poiFallback=\(usedPOIFallback, privacy: .public) poiItems=\(usedPOIFallback ? items.count - response.mapItems.count : 0, privacy: .public) kept=\(results.count - keptBefore, privacy: .public) keptMi=[\(results[keptBefore...].map { String(Int($0.distanceAlongRoute / 1609.344)) }.joined(separator: ","), privacy: .public)]")
                }
                for item in items {
                    let coord = item.placemark.coordinate
                    // Skip results with no usable coordinate (invalid / NaN), which
                    // would otherwise crash MapKit when drawn as a map annotation.
                    guard coord.isValidLocation else { continue }
                    // Enforce the corridor: discard results too far from the sample.
                    let distFromSample = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                        .distance(from: CLLocation(latitude: sample.coordinate.latitude,
                                                   longitude: sample.coordinate.longitude))
                    guard distFromSample <= corridor else { continue }

                    let key = "\(item.name ?? "")|\(round(coord.latitude * 1000))|\(round(coord.longitude * 1000))"
                    guard seen.insert(key).inserted else { continue }

                    // Use the stop's true position along the route rather than the
                    // coarse sample distance, so fuel-stop spacing and "X mi from
                    // start" labels are accurate. The detour (distance off the
                    // route line) feeds the ride-highlight ranking.
                    let projected = RouteGeometry.distanceAlongRoute(of: coord, alongPolylines: legPolylines)
                    results.append(SuggestedStop(
                        mapItem: item,
                        category: category,
                        distanceAlongRoute: RouteGeometry.preferredDistanceAlongRoute(
                            projected: projected,
                            known: sample.distanceAlongRoute
                        ),
                        detourMeters: RouteGeometry.distanceFromRoute(of: coord, alongPolylines: legPolylines)
                    ))
                }
            }
            if tally.cancelled { break }
        }

        let status = GasSearchStatus.resolve(tally, stopCount: results.count)
        gasLog.info("samples done gen=\(generation, privacy: .public) status=\(String(describing: status), privacy: .public) stops=\(results.count, privacy: .public) ok=\(tally.succeeded, privacy: .public) failed=\(tally.failed, privacy: .public) throttled=\(tally.throttled, privacy: .public)")
        // A cancelled run must not hand back a partial list for someone to publish.
        let stops = status == .completed
            ? results.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
            : []
        return CorridorSearchResult(
            stops: stops,
            status: status,
            succeeded: tally.succeeded,
            failed: tally.failed,
            throttled: tally.throttled,
            failedSampleDistances: failedSampleDistances
        )
    }

    /// `false` when the pause was cancelled. Any other error also stops the
    /// search: this function does not throw, so the catch has to be exhaustive.
    private static func pause(_ delay: Duration) async -> Bool {
        do {
            try await Task.sleep(for: delay)
            return !Task.isCancelled
        } catch {
            return false
        }
    }

    private enum SampleQuery {
        case hit(MKLocalSearch.Response)
        case throttled
        case failed
        case cancelled
    }

    /// One corridor query. Throttle retries wait out Apple's window.
    /// Cancellation never becomes a hit or a quiet failure. A sample that
    /// still fails is a miss, not an empty stretch of road.
    /// Radius-bounded gas lookup used when the text search answered for
    /// somewhere else. `nil` when the request fails or is throttled.
    private static func gasPointsOfInterest(
        near coordinate: CLLocationCoordinate2D,
        radius: CLLocationDistance
    ) async -> [MKMapItem]? {
        guard await MapSearchGate.shared.prepare(), !Task.isCancelled else { return nil }
        let request = MKLocalPointsOfInterestRequest(center: coordinate, radius: min(radius, MKLocalPointsOfInterestRequest.maxRadius))
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.gasStation])
        return try? await MKLocalSearch(request: request).start().mapItems
    }

    private static func querySample(
        category: StopCategory,
        coordinate: CLLocationCoordinate2D,
        corridor: CLLocationDistance,
        index: Int,
        generation: Int
    ) async -> SampleQuery {
        var throttleAttempt = 0
        while true {
            if Task.isCancelled { return .cancelled }
            let paced = await MapSearchGate.shared.prepare()
            if !paced || Task.isCancelled { return .cancelled }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = category.searchQuery
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(
                center: coordinate,
                latitudinalMeters: corridor * 2,
                longitudinalMeters: corridor * 2
            )
            do {
                let response = try await MKLocalSearch(request: request).start()
                return .hit(response)
            } catch is CancellationError {
                return .cancelled
            } catch {
                let nsError = error as NSError
                let throttled = isMapSearchThrottled(error)
                gasLog.error("sample gen=\(generation, privacy: .public) index=\(index, privacy: .public) domain=\(nsError.domain, privacy: .public) code=\(nsError.code, privacy: .public) throttled=\(throttled, privacy: .public)")
                if throttled, throttleAttempt < 3 {
                    throttleAttempt += 1
                    let paused = await pause(MapSearchPace.throttleBackoff(attempt: throttleAttempt))
                    if !paused || Task.isCancelled { return .cancelled }
                    continue
                }
                return throttled ? .throttled : .failed
            }
        }
    }

    /// Finds food near a single coordinate (e.g. a chosen fuel stop), within a
    /// short detour radius — "right there", not a route-wide sweep. Results are
    /// sorted nearest-first to the given coordinate and capped at `maxResults`.
    ///
    /// Pass the route's leg polylines so each result's `distanceAlongRoute` is
    /// projected the same way `findStops` does it, keeping "X mi in" labels
    /// consistent across the app.
    func findFood(
        near coordinate: CLLocationCoordinate2D,
        alongPolylines legPolylines: [[CLLocationCoordinate2D]],
        radiusMeters: CLLocationDistance = 1_500,
        maxResults: Int = 3
    ) async -> [SuggestedStop] {
        guard coordinate.isValidLocation else { return [] }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = StopCategory.food.searchQuery
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )

        guard let response = try? await MKLocalSearch(request: request).start() else {
            return []
        }

        let candidates = response.mapItems.compactMap { item -> SuggestedStop? in
            let coord = item.placemark.coordinate
            guard coord.isValidLocation else { return nil }
            return SuggestedStop(
                mapItem: item,
                category: .food,
                distanceAlongRoute: RouteGeometry.distanceAlongRoute(of: coord, alongPolylines: legPolylines),
                detourMeters: RouteGeometry.distanceFromRoute(of: coord, alongPolylines: legPolylines)
            )
        }

        return Self.rankFood(candidates, near: coordinate, radiusMeters: radiusMeters, maxResults: maxResults)
    }

    /// Pure selection logic for `findFood`: keep food within `radiusMeters` of
    /// the origin, de-duplicate by name + rounded coordinate, sort nearest-first,
    /// and cap at `maxResults`. Networking-free so it can be unit-tested.
    static func rankFood(
        _ candidates: [SuggestedStop],
        near origin: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        maxResults: Int
    ) -> [SuggestedStop] {
        let originLocation = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
        var seen = Set<String>()
        var withinRadius: [(stop: SuggestedStop, distance: CLLocationDistance)] = []

        for stop in candidates {
            let coord = stop.coordinate
            let distance = originLocation.distance(
                from: CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            )
            guard distance <= radiusMeters else { continue }

            let key = "\(stop.name)|\(round(coord.latitude * 1000))|\(round(coord.longitude * 1000))"
            guard seen.insert(key).inserted else { continue }

            withinRadius.append((stop, distance))
        }

        return withinRadius
            .sorted { $0.distance < $1.distance }
            .prefix(maxResults)
            .map { $0.stop }
    }

    /// Lodging around one coordinate (the evening's clock point), not a
    /// sweep of the whole route. Nil when the lookup was cancelled or
    /// MapKit returned an error — that is not an empty road. An empty array
    /// is a finished search with no places inside `radiusMeters`.
    ///
    /// A result with no name is dropped. A place Apple tagged as something
    /// other than a hotel is dropped. Phone, URL, and description stay on
    /// the map item; nothing is filled in here.
    func findLodging(
        near coordinate: CLLocationCoordinate2D,
        radiusMeters: CLLocationDistance,
        alongPolylines legPolylines: [[CLLocationCoordinate2D]]
    ) async -> [SuggestedStop]? {
        guard coordinate.isValidLocation, radiusMeters > 0 else { return [] }
        if Task.isCancelled { return nil }
        let paced = await MapSearchGate.shared.prepare()
        if !paced || Task.isCancelled { return nil }

        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = StopCategory.lodging.searchQuery
        request.pointOfInterestFilter = MKPointOfInterestFilter(including: [.hotel])
        request.resultTypes = .pointOfInterest
        request.region = MKCoordinateRegion(
            center: coordinate,
            latitudinalMeters: radiusMeters * 2,
            longitudinalMeters: radiusMeters * 2
        )

        let response: MKLocalSearch.Response
        do {
            response = try await MKLocalSearch(request: request).start()
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
        if Task.isCancelled { return nil }

        return response.mapItems.compactMap { item -> SuggestedStop? in
            guard let name = item.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                return nil
            }
            if let category = item.pointOfInterestCategory, category != .hotel {
                return nil
            }
            let coord = item.placemark.coordinate
            guard coord.isValidLocation else { return nil }
            let detour = RouteGeometry.distanceFromRoute(of: coord, alongPolylines: legPolylines)
            guard detour <= radiusMeters else { return nil }
            return SuggestedStop(
                mapItem: item,
                category: .lodging,
                distanceAlongRoute: RouteGeometry.distanceAlongRoute(of: coord, alongPolylines: legPolylines),
                detourMeters: detour
            )
        }
    }

    // MARK: - Polyline sampling

    private struct RouteSample {
        let coordinate: CLLocationCoordinate2D
        /// Meters from the ride start to this sample, measured while walking
        /// the polyline. Used when a later projection collapses to a few feet.
        let distanceAlongRoute: CLLocationDistance
    }

    /// Query order for a caller-supplied fuel grid: index 0, then the last,
    /// then 1, then the second to last, and so on. Generic so the order can
    /// be unit-tested without a route.
    static func endsFirst<T>(_ samples: [T]) -> [T] {
        guard samples.count > 2 else { return samples }
        var ordered: [T] = []
        ordered.reserveCapacity(samples.count)
        var low = 0
        var high = samples.count - 1
        while low <= high {
            ordered.append(samples[low])
            low += 1
            if low <= high {
                ordered.append(samples[high])
                high -= 1
            }
        }
        return ordered
    }

    /// Picks at most `max` items spread evenly across `samples` (always
    /// including the first and last). Keeps coverage spanning the whole route
    /// when there are more sample points than the search budget allows.
    /// Generic (and internal) so the selection logic is unit-testable.
    func evenlySpaced<T>(_ samples: [T], max limit: Int) -> [T] {
        guard limit > 0 else { return [] }
        guard samples.count > limit else { return samples }
        guard limit > 1 else { return samples.isEmpty ? [] : [samples[0]] }

        let step = Double(samples.count - 1) / Double(limit - 1)
        var picked: [T] = []
        for i in 0..<limit {
            picked.append(samples[Int((Double(i) * step).rounded())])
        }
        return picked
    }

    /// Walk a polyline already copied on the main actor. Same spacing as
    /// `samplePoints(alongLegs:)`, without another `MKPolyline` read.
    private func samplePoints(alongPolylines polylines: [[CLLocationCoordinate2D]]) -> [RouteSample] {
        var samples: [RouteSample] = []
        var distanceSinceLastSample: CLLocationDistance = sampleIntervalMeters
        var traveled: CLLocationDistance = 0

        for coords in polylines {
            guard coords.count > 1 else { continue }
            for index in 1..<coords.count {
                let segment = CLLocation(latitude: coords[index - 1].latitude, longitude: coords[index - 1].longitude)
                    .distance(from: CLLocation(latitude: coords[index].latitude, longitude: coords[index].longitude))
                distanceSinceLastSample += segment
                traveled += segment
                if distanceSinceLastSample >= sampleIntervalMeters {
                    samples.append(RouteSample(coordinate: coords[index], distanceAlongRoute: traveled))
                    distanceSinceLastSample = 0
                }
            }
        }
        return samples
    }

    /// Walk every leg's polyline and emit a point every `sampleIntervalMeters`.
    private func samplePoints(alongLegs legs: [MKRoute]) -> [RouteSample] {
        var samples: [RouteSample] = []
        var distanceSinceLastSample: CLLocationDistance = sampleIntervalMeters // emit first point
        var traveled: CLLocationDistance = 0

        for route in legs {
            let polyline = route.polyline
            let count = polyline.pointCount
            guard count > 1 else { continue }

            var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))

            for i in 1..<count {
                let prev = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                let curr = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                let segment = curr.distance(from: prev)
                distanceSinceLastSample += segment
                traveled += segment

                if distanceSinceLastSample >= sampleIntervalMeters {
                    samples.append(RouteSample(coordinate: coords[i], distanceAlongRoute: traveled))
                    distanceSinceLastSample = 0
                }
            }
        }
        return samples
    }
}
