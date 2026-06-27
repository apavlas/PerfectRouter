import Foundation
import CoreLocation

/// A portable, serializable snapshot of a planned ride that can be shared
/// with other riders via a link and reconstructed into waypoints on import.
struct SharedRoute: Codable, Equatable {

    /// One shared stop: a name plus its coordinate. Stored as plain
    /// `Double`s because `CLLocationCoordinate2D` is not `Codable`.
    struct Stop: Codable, Equatable {
        var name: String
        var latitude: CLLocationDegrees
        var longitude: CLLocationDegrees
    }

    /// One shared suggestion: a stop recommended along the route, including
    /// its category and how far into the ride it sits, so the recipient sees
    /// the same picks (and fuel-stop warnings) as the sender.
    struct Suggestion: Codable, Equatable {
        var name: String
        var latitude: CLLocationDegrees
        var longitude: CLLocationDegrees
        var category: String
        var distanceAlongRoute: CLLocationDistance
    }

    var stops: [Stop]
    var suggestions: [Suggestion]

    // MARK: - Conversion to/from waypoints

    init(waypoints: [Waypoint], suggestedStops: [SuggestedStop] = []) {
        stops = waypoints.map {
            Stop(name: $0.name,
                 latitude: $0.coordinate.latitude,
                 longitude: $0.coordinate.longitude)
        }
        suggestions = suggestedStops.map {
            Suggestion(name: $0.name,
                       latitude: $0.coordinate.latitude,
                       longitude: $0.coordinate.longitude,
                       category: $0.category.rawValue,
                       distanceAlongRoute: $0.distanceAlongRoute)
        }
    }

    var waypoints: [Waypoint] {
        stops.map {
            Waypoint(name: $0.name,
                     coordinate: CLLocationCoordinate2D(latitude: $0.latitude,
                                                        longitude: $0.longitude))
        }
    }

    /// The shared suggestions rebuilt into `SuggestedStop`s the app can display.
    /// Drops any entry whose category is unknown to this app version.
    var suggestedStops: [SuggestedStop] {
        suggestions.compactMap { suggestion in
            guard let category = StopCategory(rawValue: suggestion.category) else { return nil }
            return SuggestedStop(
                name: suggestion.name,
                coordinate: CLLocationCoordinate2D(latitude: suggestion.latitude,
                                                   longitude: suggestion.longitude),
                category: category,
                distanceAlongRoute: suggestion.distanceAlongRoute
            )
        }
    }

    /// The category the shared suggestions belong to, if any — used so the
    /// recipient's UI opens on the same category the sender was viewing.
    var suggestionCategory: StopCategory? {
        suggestions.first.flatMap { StopCategory(rawValue: $0.category) }
    }

    // MARK: - Deep link

    /// Custom URL scheme other riders' copies of the app can open.
    static let scheme = "motoroute"
    static let host = "route"

    /// A `motoroute://route?data=<base64url-json>` link that, when opened on a
    /// device with the app installed, reconstructs this exact ride.
    var shareURL: URL? {
        guard let json = try? JSONEncoder().encode(self) else { return nil }
        let encoded = json.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [URLQueryItem(name: "data", value: encoded)]
        return components.url
    }

    /// Rebuilds a `SharedRoute` from a link produced by `shareURL`.
    /// Returns `nil` if the URL isn't a valid MotoRoute link.
    init?(url: URL) {
        guard url.scheme == Self.scheme, url.host == Self.host,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let encoded = components.queryItems?.first(where: { $0.name == "data" })?.value
        else { return nil }

        var base64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Restore base64 padding stripped from the URL-safe form.
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }

        guard let data = Data(base64Encoded: base64),
              let decoded = try? JSONDecoder().decode(SharedRoute.self, from: data)
        else { return nil }

        self = decoded
    }

    // MARK: - Human-readable summary

    /// Short text shown alongside the link when sharing (e.g. in Messages).
    var shareMessage: String {
        guard let start = stops.first?.name, let end = stops.last?.name, stops.count >= 2 else {
            return "Check out my ride on MotoRoute."
        }
        let viaCount = stops.count - 2
        let via = viaCount > 0 ? " via \(viaCount) stop\(viaCount == 1 ? "" : "s")" : ""
        return "Ride with me on MotoRoute: \(start) → \(end)\(via). Tap the link to load this route."
    }
}
