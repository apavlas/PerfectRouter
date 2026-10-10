import CoreLocation
import Foundation
import MapKit

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
        return try await MKDirections(request: request).calculate().routes
    }
}
