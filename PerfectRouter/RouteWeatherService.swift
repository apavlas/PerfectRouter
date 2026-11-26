import Foundation
import MapKit
import WeatherKit

/// The result of scanning a route for rain.
struct RouteRainForecast: Equatable {
    /// Highest hourly precipitation chance (0...1) found along the route at the
    /// rider's expected time of passing each point.
    let maxChance: Double
    /// Distance from the start (meters) where that highest chance occurs, used
    /// to tell the rider roughly where to expect rain.
    let distanceOfMaxChance: CLLocationDistance
}

/// Checks WeatherKit forecasts at points along a route to gauge rain risk.
///
/// Strategy: sample a handful of points evenly along the route, estimate when
/// the rider reaches each (assuming an immediate departure and constant pace),
/// then read the hourly precipitation chance nearest that time.
///
/// WeatherKit requires a paid Apple Developer team. Debug builds omit that
/// entitlement so a free Personal Team can Run in Xcode; this service then
/// returns `nil` instead of calling WeatherKit.
struct RouteWeatherService {

    /// Debug (personal-team) builds omit the WeatherKit entitlement, so rain
    /// checks are skipped. Release / App Store keeps the entitlement and
    /// WeatherKit. `try?` below still swallows API errors so a missing
    /// capability cannot crash a ride plan.
    static var isEnabled: Bool {
#if DEBUG
        false
#else
        true
#endif
    }

    /// Number of points sampled along the route. Kept small — each is a
    /// separate WeatherKit request. Eight gives the map's rain colours a
    /// stretch roughly every eighth of the ride.
    var sampleCount = 8

    func rainForecast(alongLegs legs: [MKRoute], departure: Date) async -> RouteRainForecast? {
        await rainProfile(alongLegs: legs, departure: departure)?.forecast(departure: departure)
    }

    /// Hourly forecasts at points along the route, each tagged with how long
    /// after departure the rider reaches it. One fetch covers any departure
    /// in the forecast range, so the departure suggestion and map colours
    /// need no further WeatherKit calls.
    func rainProfile(alongLegs legs: [MKRoute], departure: Date) async -> RouteRainProfile? {
        guard Self.isEnabled else { return nil }

        let samples = sampledPoints(alongLegs: legs, departure: departure, count: sampleCount)
        guard !samples.isEmpty else { return nil }

        let service = WeatherService.shared
        // Ask for every hour the departure search can reach: up to six hours
        // either side of the picked time, plus the ride itself.
        let window = RouteRainTiming.searchWindow + 3_600
        let rideTime = samples.map { $0.eta.timeIntervalSince(departure) }.max() ?? 0
        let start = max(Date(), departure.addingTimeInterval(-window))
        let end = departure.addingTimeInterval(rideTime + window)
        var profileSamples: [RouteRainSample] = []
        for sample in samples {
            guard !Task.isCancelled else { return nil }
            let location = CLLocation(latitude: sample.coordinate.latitude,
                                      longitude: sample.coordinate.longitude)
            // Missing entitlement, network, or WeatherKit outage: skip the
            // sample rather than failing the ride plan.
            guard let hourly = try? await service.weather(for: location, including: .hourly(startDate: start, endDate: end)) else { continue }
            profileSamples.append(RouteRainSample(
                coordinate: sample.coordinate,
                distanceAlongRoute: sample.distanceAlongRoute,
                offsetFromDeparture: sample.eta.timeIntervalSince(departure),
                hourly: hourly.forecast.map {
                    HourlyRainChance(date: $0.date, chance: $0.precipitationChance)
                }
            ))
        }
        guard !profileSamples.isEmpty else { return nil }
        return RouteRainProfile(samples: profileSamples)
    }

    /// Every leg's polyline as one path with running distance, for drawing
    /// the rain colours along the line.
    static func routePath(alongLegs legs: [MKRoute]) -> [(coordinate: CLLocationCoordinate2D, distance: CLLocationDistance)] {
        var path: [(coordinate: CLLocationCoordinate2D, distance: CLLocationDistance)] = []
        var cumulative: CLLocationDistance = 0
        for route in legs {
            let polyline = route.polyline
            let n = polyline.pointCount
            guard n > 0 else { continue }
            var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            for coordinate in coords {
                if let previous = path.last?.coordinate {
                    cumulative += CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
                        .distance(from: CLLocation(latitude: previous.latitude, longitude: previous.longitude))
                }
                path.append((coordinate, cumulative))
            }
        }
        return path
    }

    // MARK: - Sampling

    private struct WeatherSample {
        let coordinate: CLLocationCoordinate2D
        let distanceAlongRoute: CLLocationDistance
        let eta: Date
    }

    /// Picks `count` points spaced evenly by distance along the route
    /// (including start and end), each tagged with the rider's estimated time
    /// of arrival.
    private func sampledPoints(alongLegs legs: [MKRoute], departure: Date, count: Int) -> [WeatherSample] {
        let totalDistance = legs.reduce(0) { $0 + $1.distance }
        let totalTime = legs.reduce(0) { $0 + $1.expectedTravelTime }
        guard totalDistance > 0, count > 0 else { return [] }

        let path = Self.routePath(alongLegs: legs)
        guard let first = path.first else { return [] }
        guard path.count >= 2 else {
            return [WeatherSample(coordinate: first.coordinate, distanceAlongRoute: 0, eta: departure)]
        }

        let step = totalDistance / Double(max(count - 1, 1))
        var samples: [WeatherSample] = []
        var index = 0
        for i in 0..<count {
            let target = min(step * Double(i), totalDistance)
            while index < path.count - 1 && path[index].distance < target {
                index += 1
            }
            let point = path[index]
            let fraction = point.distance / totalDistance
            let eta = departure.addingTimeInterval(totalTime * fraction)
            samples.append(WeatherSample(coordinate: point.coordinate,
                                         distanceAlongRoute: point.distance,
                                         eta: eta))
        }
        return samples
    }
}
