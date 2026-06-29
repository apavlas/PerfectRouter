import Foundation
import MapKit

/// Finds recommended stops (gas, food, etc.) along a calculated route.
///
/// Strategy:
/// 1. Sample points along the route polyline every `sampleIntervalMeters`.
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

    /// Find stops of one category along the given routes (one route per leg).
    func findStops(
        category: StopCategory,
        alongLegs legs: [MKRoute]
    ) async -> [SuggestedStop] {
        // Spread a bounded number of searches across the ENTIRE route, so gas
        // (and other) stops are still found on long rides instead of only near
        // the start. Capping protects against MKLocalSearch throttling.
        let samples = evenlySpaced(samplePoints(alongLegs: legs), max: maxSearches)
        // Extract each leg's polyline coordinates once and reuse them for every
        // stop's distance-along-route projection (instead of rebuilding them per
        // result), which matters on long routes with many results.
        let legPolylines = legs.map { RouteGeometry.coordinates(of: $0.polyline) }
        var seen = Set<String>()          // de-dup by name + rounded coords
        var results: [SuggestedStop] = []

        for (index, sample) in samples.enumerated() {
            if index > 0 {
                try? await Task.sleep(for: interSearchDelay)
            }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = category.searchQuery
            request.resultTypes = .pointOfInterest
            request.region = MKCoordinateRegion(
                center: sample.coordinate,
                latitudinalMeters: corridorRadiusMeters * 2,
                longitudinalMeters: corridorRadiusMeters * 2
            )

            guard let response = try? await MKLocalSearch(request: request).start() else {
                continue
            }

            for item in response.mapItems {
                let coord = item.placemark.coordinate
                // Skip results with no usable coordinate (invalid / NaN), which
                // would otherwise crash MapKit when drawn as a map annotation.
                guard coord.isValidLocation else { continue }
                // Enforce the corridor: discard results too far from the sample.
                let distFromSample = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
                    .distance(from: CLLocation(latitude: sample.coordinate.latitude,
                                               longitude: sample.coordinate.longitude))
                guard distFromSample <= corridorRadiusMeters else { continue }

                let key = "\(item.name ?? "")|\(round(coord.latitude * 1000))|\(round(coord.longitude * 1000))"
                guard seen.insert(key).inserted else { continue }

                // Use the stop's true position along the route rather than the
                // coarse sample distance, so fuel-stop spacing and "X mi from
                // start" labels are accurate.
                results.append(SuggestedStop(
                    mapItem: item,
                    category: category,
                    distanceAlongRoute: RouteGeometry.distanceAlongRoute(of: coord, alongPolylines: legPolylines)
                ))
            }
        }

        return results.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
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
                distanceAlongRoute: RouteGeometry.distanceAlongRoute(of: coord, alongPolylines: legPolylines)
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

    // MARK: - Polyline sampling

    private struct RouteSample {
        let coordinate: CLLocationCoordinate2D
    }

    /// Picks at most `max` items spread evenly across `samples` (always
    /// including the first and last). Keeps coverage spanning the whole route
    /// when there are more sample points than the search budget allows.
    private func evenlySpaced(_ samples: [RouteSample], max limit: Int) -> [RouteSample] {
        guard limit > 0 else { return [] }
        guard samples.count > limit else { return samples }
        guard limit > 1 else { return samples.isEmpty ? [] : [samples[0]] }

        let step = Double(samples.count - 1) / Double(limit - 1)
        var picked: [RouteSample] = []
        for i in 0..<limit {
            picked.append(samples[Int((Double(i) * step).rounded())])
        }
        return picked
    }

    /// Walk every leg's polyline and emit a point every `sampleIntervalMeters`.
    private func samplePoints(alongLegs legs: [MKRoute]) -> [RouteSample] {
        var samples: [RouteSample] = []
        var distanceSinceLastSample: CLLocationDistance = sampleIntervalMeters // emit first point

        for route in legs {
            let polyline = route.polyline
            let count = polyline.pointCount
            guard count > 1 else { continue }

            var coords = [CLLocationCoordinate2D](repeating: .init(), count: count)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: count))

            for i in 1..<count {
                let prev = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                let curr = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                distanceSinceLastSample += curr.distance(from: prev)

                if distanceSinceLastSample >= sampleIntervalMeters {
                    samples.append(RouteSample(coordinate: coords[i]))
                    distanceSinceLastSample = 0
                }
            }
        }
        return samples
    }
}
