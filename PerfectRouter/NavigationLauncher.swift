import Foundation
import MapKit
import UIKit

/// Hands a planned ride off to a turn-by-turn navigation app. PerfectRouter plans
/// the ride; the actual guidance is delegated to Apple or Google Maps.
enum NavigationLauncher {

    /// Opens the multi-stop route in Apple Maps with driving directions.
    static func openInAppleMaps(_ waypoints: [Waypoint]) {
        guard waypoints.count >= 2 else { return }
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
