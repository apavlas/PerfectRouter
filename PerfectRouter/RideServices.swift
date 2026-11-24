import CoreLocation
import Foundation
import MapKit
import os

/// Driving directions for one leg. The live provider calls MapKit. UI tests
/// install a stub so `xcodebuild test` does not depend on the network.
@MainActor
protocol DirectionsProviding: AnyObject {
    func calculateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        avoidsHighways: Bool,
        avoidsTolls: Bool,
        alternates: Bool,
        departure: Date
    ) async throws -> [MKRoute]
}

/// Corridor stop search. The live path stays on `StopSuggestionService`.
/// UI tests replace it so gas and food lookups return canned places.
@MainActor
protocol StopSearching: AnyObject {
    func findStops(
        category: StopCategory,
        alongLegs legs: [MKRoute],
        sampleDistances: [CLLocationDistance]?,
        corridorRadiusMeters: CLLocationDistance?,
        generation: Int
    ) async -> CorridorSearchResult

    func findFood(
        near coordinate: CLLocationCoordinate2D,
        alongPolylines legPolylines: [[CLLocationCoordinate2D]]
    ) async -> [SuggestedStop]
}

/// Place search behind the planning sheet's text field.
@MainActor
protocol PlaceSearching: AnyObject {
    func searchPlaces(query: String, near region: MKCoordinateRegion) async -> [MKMapItem]
}

/// MapKit-backed directions. Behavior matches the planner's previous
/// in-line `MKDirections` request.
@MainActor
final class MapKitDirectionsProvider: DirectionsProviding {
    func calculateRoutes(
        from origin: CLLocationCoordinate2D,
        to destination: CLLocationCoordinate2D,
        avoidsHighways: Bool,
        avoidsTolls: Bool,
        alternates: Bool,
        departure: Date
    ) async throws -> [MKRoute] {
        guard origin.isValidLocation, destination.isValidLocation else { return [] }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination))
        request.transportType = .automobile
        request.departureDate = departure
        request.highwayPreference = avoidsHighways ? .avoid : .any
        request.tollPreference = avoidsTolls ? .avoid : .any
        request.requestsAlternateRoutes = alternates
        return try await DirectionsThrottleRetry.run {
            try await MKDirections(request: request).calculate().routes
        }
    }
}

/// Retries a directions request that MapKit refused with
/// `MKError.loadingThrottled`. Long multi-stop rides and Twisty replans send
/// the most directions requests, and without this one throttled leg failed
/// the whole plan. Uses the same 2, 4, 8 second backoff as corridor search.
/// Other errors and cancellation pass straight through.
enum DirectionsThrottleRetry {

    /// Tries after the first request. Four requests total, about 14 seconds
    /// of waiting at most, before the throttle error reaches the planner.
    static let maxRetries = 3

    private static let log = Logger(subsystem: "com.apavlas.PerfectRouter", category: "directions")

    static func run<T>(
        maxRetries: Int = maxRetries,
        pause: (Duration) async -> Bool = Self.sleep,
        _ request: () async throws -> T
    ) async throws -> T {
        var retry = 0
        while true {
            do {
                return try await request()
            } catch {
                guard StopSuggestionService.isMapSearchThrottled(error), retry < maxRetries else { throw error }
                retry += 1
                log.error("directions throttled, retry \(retry, privacy: .public) of \(maxRetries, privacy: .public)")
                guard await pause(MapSearchPace.throttleBackoff(attempt: retry)), !Task.isCancelled else {
                    throw CancellationError()
                }
            }
        }
    }

    /// `false` when the wait was cancelled.
    static func sleep(_ duration: Duration) async -> Bool {
        do {
            try await Task.sleep(for: duration)
            return true
        } catch {
            return false
        }
    }
}
