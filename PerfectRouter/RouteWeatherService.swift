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
struct RouteWeatherService {

    /// Number of points sampled along the route. Kept small — each is a
    /// separate WeatherKit request.
    var sampleCount = 5

    func rainForecast(alongLegs legs: [MKRoute], departure: Date) async -> RouteRainForecast? {
        let samples = sampledPoints(alongLegs: legs, departure: departure, count: sampleCount)
        guard !samples.isEmpty else { return nil }

        let service = WeatherService.shared
        var best: (chance: Double, distance: CLLocationDistance)?

        for sample in samples {
            let location = CLLocation(latitude: sample.coordinate.latitude,
                                      longitude: sample.coordinate.longitude)
            guard let weather = try? await service.weather(for: location) else { continue }

            // The hourly entry closest to when the rider passes this point.
            let hour = weather.hourlyForecast.min {
                abs($0.date.timeIntervalSince(sample.eta)) < abs($1.date.timeIntervalSince(sample.eta))
            }
            guard let hour else { continue }

            if best == nil || hour.precipitationChance > best!.chance {
                best = (hour.precipitationChance, sample.distanceAlongRoute)
            }
        }

        guard let best else { return nil }
        return RouteRainForecast(maxChance: best.chance, distanceOfMaxChance: best.distance)
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

        // Flatten every leg's polyline into a path of (coordinate, cumulative distance).
        var path: [(coordinate: CLLocationCoordinate2D, distance: CLLocationDistance)] = []
        var cumulative: CLLocationDistance = 0
        for route in legs {
            let polyline = route.polyline
            let n = polyline.pointCount
            guard n > 0 else { continue }
            var coords = [CLLocationCoordinate2D](repeating: .init(), count: n)
            polyline.getCoordinates(&coords, range: NSRange(location: 0, length: n))
            for i in 0..<n {
                if i > 0 {
                    let prev = CLLocation(latitude: coords[i - 1].latitude, longitude: coords[i - 1].longitude)
                    let curr = CLLocation(latitude: coords[i].latitude, longitude: coords[i].longitude)
                    cumulative += curr.distance(from: prev)
                }
                path.append((coords[i], cumulative))
            }
        }
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
