import Foundation
import MapKit
import UIKit

/// Hands a planned ride off to a turn-by-turn navigation app. PerfectRouter plans
/// the ride; the actual guidance is delegated to Apple or Google Maps.
enum NavigationLauncher {

    /// Opens the multi-stop route in Apple Maps with driving directions.
    ///
    /// `MKMapItem.openMaps(with:launchOptions:)` only routes between the first
    /// two items — extra items are dropped as route stops — so rides with
    /// intermediate stops go through the Maps URL scheme instead, which keeps
    /// every stop (at the cost of showing coordinates rather than stop names).
    static func openInAppleMaps(_ waypoints: [Waypoint]) {
        guard waypoints.count >= 2 else { return }
        if waypoints.count > 2, let url = appleMapsMultiStopURL(waypoints) {
            UIApplication.shared.open(url)
            return
        }
        let items = waypoints.map { waypoint -> MKMapItem in
            let item = MKMapItem(placemark: MKPlacemark(coordinate: waypoint.coordinate))
            item.name = waypoint.name
            return item
        }
        MKMapItem.openMaps(
            with: items,
            launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving]
        )
    }

    /// A maps.apple.com driving-directions URL routing through every waypoint.
    /// Destinations are chained in `daddr` with `+to:` — absent from Apple's
    /// URL scheme reference but long supported by Maps, and the only URL form
    /// that preserves mid-ride stops. If Maps ever stops honoring the chain it
    /// degrades to directions to the first destination, no worse than the
    /// `openMaps` path.
    static func appleMapsMultiStopURL(_ waypoints: [Waypoint]) -> URL? {
        guard waypoints.count >= 2, let origin = waypoints.first else { return nil }
        let coordinateText = { (waypoint: Waypoint) in
            "\(waypoint.coordinate.latitude),\(waypoint.coordinate.longitude)"
        }
        let destinations = waypoints.dropFirst().map(coordinateText).joined(separator: "+to:")

        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "saddr", value: coordinateText(origin)),
            URLQueryItem(name: "daddr", value: destinations),
            URLQueryItem(name: "dirflg", value: "d"),
        ]
        return components?.url
    }

    /// Whether Google Maps is installed (requires `comgooglemaps` in the
    /// Info.plist `LSApplicationQueriesSchemes`).
    static var isGoogleMapsAvailable: Bool {
        guard let url = URL(string: "comgooglemaps://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    /// Opens the route in Google Maps, if installed.
    static func openInGoogleMaps(_ waypoints: [Waypoint]) {
        guard let url = googleMapsURL(waypoints) else { return }
        UIApplication.shared.open(url)
    }

    /// A `comgooglemaps://` directions URL for the route, or nil if invalid.
    static func googleMapsURL(_ waypoints: [Waypoint]) -> URL? {
        guard waypoints.count >= 2,
              let origin = waypoints.first,
              let destination = waypoints.last else { return nil }

        let intermediate = waypoints.dropFirst().dropLast()
            .map { "\($0.coordinate.latitude),\($0.coordinate.longitude)" }
            .joined(separator: "|")

        var components = URLComponents()
        components.scheme = "comgooglemaps"
        components.host = ""
        components.queryItems = [
            URLQueryItem(name: "saddr", value: "\(origin.coordinate.latitude),\(origin.coordinate.longitude)"),
            URLQueryItem(name: "daddr", value: "\(destination.coordinate.latitude),\(destination.coordinate.longitude)"),
            URLQueryItem(name: "directionsmode", value: "driving"),
        ]
        if !intermediate.isEmpty {
            components.queryItems?.append(URLQueryItem(name: "waypoints", value: intermediate))
        }
        return components.url
    }

    /// A shareable Apple Maps web link for a one-shot location share.
    ///
    /// Note: this is a single snapshot of the rider's position, not continuous
    /// live tracking. Real-time group location requires a backend and is a
    /// future enhancement.
    static func currentLocationShareURL(_ coordinate: CLLocationCoordinate2D) -> URL? {
        URL(string: "https://maps.apple.com/?ll=\(coordinate.latitude),\(coordinate.longitude)&q=My%20Location")
    }
}
