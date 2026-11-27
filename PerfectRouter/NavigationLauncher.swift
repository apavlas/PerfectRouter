import Foundation
import MapKit
import UIKit

/// Hands a planned ride off to a turn-by-turn navigation app. PerfectRouter plans
/// the ride; the actual guidance is delegated to Apple or Google Maps.
enum NavigationLauncher {

    /// Opens the multi-stop route in Apple Maps with driving directions.
    ///
    /// `MKMapItem.openMaps(with:launchOptions:)` only routes between the first
    /// two items — extra items become a pin list, not stops — so rides with
    /// intermediate stops use Apple's unified `/directions` URL, which takes
    /// repeated `waypoint` parameters.
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

    /// Official `maps.apple.com/directions` URL for a driving route through
    /// every waypoint (`source`, repeated `waypoint`, `destination`).
    ///
    /// Built with `percentEncodedQuery` so coordinate commas stay literal
    /// (matching Apple's examples). The old `daddr=…+to:…` form was unofficial
    /// and broke when `URLComponents.queryItems` percent-encoded `+` / `:`.
    static func appleMapsMultiStopURL(_ waypoints: [Waypoint]) -> URL? {
        guard waypoints.count >= 2,
              let origin = waypoints.first,
              let destination = waypoints.last else { return nil }
        let coordinateText = { (waypoint: Waypoint) in
            "\(waypoint.coordinate.latitude),\(waypoint.coordinate.longitude)"
        }

        var parts = [
            "source=\(coordinateText(origin))",
            "destination=\(coordinateText(destination))",
            "mode=driving",
        ]
        for stop in waypoints.dropFirst().dropLast() {
            parts.append("waypoint=\(coordinateText(stop))")
        }

        var components = URLComponents(string: "https://maps.apple.com/directions")
        components?.percentEncodedQuery = parts.joined(separator: "&")
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

    /// Most intermediate stops Google Maps takes from a directions link.
    static let googleMapsMaxWaypoints = 9

    /// Google's documented cross-platform directions link. It opens the
    /// Google Maps app when installed and keeps up to 9 middle stops, in
    /// order. The old `comgooglemaps://` scheme has no documented stops
    /// parameter, so Google could drop every middle stop.
    ///
    /// More than 9 middle stops: the first 9 are kept, and
    /// `googleMapsDropsStops` tells the summary to say so.
    static func googleMapsURL(_ waypoints: [Waypoint]) -> URL? {
        guard waypoints.count >= 2,
              let origin = waypoints.first,
              let destination = waypoints.last else { return nil }
        let text = { (waypoint: Waypoint) in
            "\(waypoint.coordinate.latitude),\(waypoint.coordinate.longitude)"
        }
        let middle = waypoints.dropFirst().dropLast().prefix(googleMapsMaxWaypoints).map(text)

        var components = URLComponents(string: "https://www.google.com/maps/dir/")
        var items = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "origin", value: text(origin)),
            URLQueryItem(name: "destination", value: text(destination)),
            URLQueryItem(name: "travelmode", value: "driving"),
        ]
        if !middle.isEmpty {
            items.append(URLQueryItem(name: "waypoints", value: middle.joined(separator: "|")))
        }
        components?.queryItems = items
        return components?.url
    }

    /// True when a Google hand-off has to leave out some of the rider's stops.
    static func googleMapsDropsStops(_ waypoints: [Waypoint]) -> Bool {
        waypoints.count - 2 > googleMapsMaxWaypoints
    }

    // MARK: - Keeping the planned line

    /// Most stops, start and destination included, sent to Apple Maps.
    /// Apple's multi-stop routes take 15; one is kept spare.
    static let appleMapsMaxStops = 14

    /// Most shaping points added to one hand-off. Apple and Google treat each
    /// as a stop ("Arrived"), so a few keep the line without a prompt every
    /// few miles.
    static let maxShapingPoints = 6

    /// Legs shorter than this get no shaping point: the nav app's own route
    /// between two close stops is the same road.
    static let minimumShapedLegMeters: CLLocationDistance = 5_000

    /// The stops to hand off so the navigation app follows the planned line,
    /// not its own fastest route. Every rider stop is kept, in order. Spare
    /// stop slots (up to `maxTotal`) go to points on the planned line,
    /// shared between legs by length and spaced evenly along each.
    ///
    /// Fastest needs none: the nav app would pick the same line. For other
    /// styles the points come from the planned geometry, so they sit on the
    /// roads PerfectRouter chose.
    static func handoffWaypoints(
        _ waypoints: [Waypoint],
        line: [CLLocationCoordinate2D],
        style: RouteStyle,
        maxTotal: Int
    ) -> [Waypoint] {
        guard style != .fastest,
              waypoints.count >= 2,
              line.count >= 2,
              maxTotal > waypoints.count else { return waypoints }

        // A line that doesn't start and end at the ride's ends belongs to an
        // older plan (stops edited, replan not finished). Hand off the stops
        // alone rather than steer the rider along the old roads.
        guard meters(line[0], waypoints[0].coordinate) <= stopSnapMeters,
              meters(line[line.count - 1], waypoints[waypoints.count - 1].coordinate) <= stopSnapMeters
        else { return waypoints }

        // Running distance along the line, and where each rider stop sits on
        // it. Stops are matched in order so a loop's start and end don't
        // swap places.
        var cumulative: [CLLocationDistance] = [0]
        cumulative.reserveCapacity(line.count)
        for index in 1..<line.count {
            cumulative.append(cumulative[index - 1] + meters(line[index - 1], line[index]))
        }
        var stopIndices: [Int] = [0]
        var searchFrom = 0
        for waypoint in waypoints.dropFirst().dropLast() {
            guard let index = firstVisit(of: waypoint.coordinate, on: line, from: searchFrom) else {
                return waypoints
            }
            stopIndices.append(index)
            searchFrom = index
        }
        stopIndices.append(line.count - 1)

        let legLengths = zip(stopIndices, stopIndices.dropFirst()).map { cumulative[$1] - cumulative[$0] }
        let shapedTotal = legLengths.filter { $0 >= minimumShapedLegMeters }.reduce(0, +)
        let spare = min(maxTotal - waypoints.count, maxShapingPoints)
        guard shapedTotal > 0, spare > 0 else { return waypoints }

        // Share the spare slots by length, largest remainders first.
        var counts = legLengths.map { $0 >= minimumShapedLegMeters ? Int(Double(spare) * $0 / shapedTotal) : 0 }
        var left = spare - counts.reduce(0, +)
        let byRemainder = legLengths.indices
            .filter { legLengths[$0] >= minimumShapedLegMeters }
            .sorted {
                let a = Double(spare) * legLengths[$0] / shapedTotal - Double(counts[$0])
                let b = Double(spare) * legLengths[$1] / shapedTotal - Double(counts[$1])
                return a > b
            }
        for leg in byRemainder where left > 0 {
            counts[leg] += 1
            left -= 1
        }

        var result: [Waypoint] = []
        for leg in legLengths.indices {
            result.append(waypoints[leg])
            let start = cumulative[stopIndices[leg]]
            let length = legLengths[leg]
            let n = counts[leg]
            guard n > 0 else { continue }
            for k in 1...n {
                let target = start + length * Double(k) / Double(n + 1)
                // A vertex of the planned line, so the point is on its road.
                var index = stopIndices[leg]
                while index < stopIndices[leg + 1], cumulative[index] < target { index += 1 }
                result.append(Waypoint(name: "Via", coordinate: line[index]))
            }
        }
        result.append(waypoints[waypoints.count - 1])
        return result
    }

    /// How far a stop may sit from the planned line and still count as on
    /// it. Farther means the line is from an older plan.
    static let stopSnapMeters: CLLocationDistance = 1_000

    /// Where the line first passes `coordinate`, at or after `start`. A route
    /// that passes the same place twice (an out-and-back, a figure eight)
    /// takes the earliest pass that is about as close as the closest one, so
    /// a stop isn't matched to the way home. Nil when the line never comes
    /// within `stopSnapMeters`.
    static func firstVisit(
        of coordinate: CLLocationCoordinate2D,
        on line: [CLLocationCoordinate2D],
        from start: Int
    ) -> Int? {
        guard start < line.count else { return nil }
        let distances = line[start...].map { meters($0, coordinate) }
        guard let closest = distances.min(), closest <= stopSnapMeters else { return nil }
        let accepted = closest + 150
        guard let runStart = distances.firstIndex(where: { $0 <= accepted }) else { return nil }
        var best = runStart
        var offset = runStart
        while offset < distances.count, distances[offset] <= accepted {
            if distances[offset] < distances[best] { best = offset }
            offset += 1
        }
        return start + best
    }

    /// Opens the ride in Apple Maps so it follows the planned line.
    static func openInAppleMaps(_ waypoints: [Waypoint], legs: [MKRoute], style: RouteStyle) {
        let line = legs.flatMap { RouteGeometry.coordinates(of: $0.polyline) }
        openInAppleMaps(handoffWaypoints(waypoints, line: line, style: style, maxTotal: appleMapsMaxStops))
    }

    /// Opens the ride in Google Maps so it follows the planned line. Rider
    /// stops come first; shaping points only use slots they leave free.
    static func openInGoogleMaps(_ waypoints: [Waypoint], legs: [MKRoute], style: RouteStyle) {
        let line = legs.flatMap { RouteGeometry.coordinates(of: $0.polyline) }
        openInGoogleMaps(handoffWaypoints(waypoints, line: line, style: style, maxTotal: googleMapsMaxWaypoints + 2))
    }

    private static func meters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> CLLocationDistance {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
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
