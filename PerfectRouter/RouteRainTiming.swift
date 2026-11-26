import CoreLocation
import Foundation

/// One hour of forecast at one point on the route.
struct HourlyRainChance: Equatable {
    var date: Date
    /// Precipitation chance, 0...1.
    var chance: Double
}

/// A forecast point on the route: where it is, how long after departure the
/// rider reaches it, and that point's hourly forecast.
struct RouteRainSample: Equatable {
    var coordinate: CLLocationCoordinate2D
    var distanceAlongRoute: CLLocationDistance
    /// Riding time from the start to this point.
    var offsetFromDeparture: TimeInterval
    var hourly: [HourlyRainChance]

    static func == (lhs: RouteRainSample, rhs: RouteRainSample) -> Bool {
        lhs.coordinate.latitude == rhs.coordinate.latitude
            && lhs.coordinate.longitude == rhs.coordinate.longitude
            && lhs.distanceAlongRoute == rhs.distanceAlongRoute
            && lhs.offsetFromDeparture == rhs.offsetFromDeparture
            && lhs.hourly == rhs.hourly
    }
}

/// Every forecast point on the route, fetched once. A point whose forecast
/// couldn't be fetched stays in the list with no hours, so it reads as
/// unknown: it draws as the plain line, and no departure is suggested as
/// dry while any point is unknown. Because each point keeps
/// its whole hourly forecast, rain for a different departure is worked out
/// here without asking WeatherKit again.
struct RouteRainProfile: Equatable {
    var samples: [RouteRainSample]

    /// True when at least one point has forecast hours.
    var hasAnyForecast: Bool { samples.contains { !$0.hourly.isEmpty } }

    /// Chance at `sample` for a ride leaving at `departure`: the hourly entry
    /// closest to when the rider passes. Nil when that time is more than 90
    /// minutes outside the forecast.
    static func chance(at sample: RouteRainSample, departure: Date) -> Double? {
        let passing = departure.addingTimeInterval(sample.offsetFromDeparture)
        guard let hour = sample.hourly.min(by: {
            abs($0.date.timeIntervalSince(passing)) < abs($1.date.timeIntervalSince(passing))
        }) else { return nil }
        guard abs(hour.date.timeIntervalSince(passing)) <= 90 * 60 else { return nil }
        return hour.chance
    }

    /// Highest chance along the route and where it is, for `departure`.
    func forecast(departure: Date) -> RouteRainForecast? {
        var best: (chance: Double, distance: CLLocationDistance)?
        for sample in samples {
            guard let chance = Self.chance(at: sample, departure: departure) else { continue }
            if best == nil || chance > best!.chance {
                best = (chance, sample.distanceAlongRoute)
            }
        }
        guard let best else { return nil }
        return RouteRainForecast(maxChance: best.chance, distanceOfMaxChance: best.distance)
    }

    /// The first point at or above `threshold`, and how long after departure
    /// the rider gets there. Used to time the mid-ride rain alert.
    func firstRain(departure: Date, threshold: Double) -> (sample: RouteRainSample, chance: Double)? {
        for sample in samples.sorted(by: { $0.distanceAlongRoute < $1.distanceAlongRoute }) {
            if let chance = Self.chance(at: sample, departure: departure), chance >= threshold {
                return (sample, chance)
            }
        }
        return nil
    }
}

/// How wet a stretch of the route line looks on the map.
enum RainBand: Int, Comparable {
    case dry
    case possible
    case likely

    /// 30% matches the rain warning. 60% is "likely".
    static let possibleThreshold = 0.3
    static let likelyThreshold = 0.6

    init(chance: Double?) {
        guard let chance else { self = .dry; return }
        if chance >= Self.likelyThreshold {
            self = .likely
        } else if chance >= Self.possibleThreshold {
            self = .possible
        } else {
            self = .dry
        }
    }

    static func < (lhs: RainBand, rhs: RainBand) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// A stretch of the route line drawn in one rain colour.
struct RainLineSegment: Equatable, Identifiable {
    var id: Int
    var coordinates: [CLLocationCoordinate2D]
    var band: RainBand
    var chance: Double?

    static func == (lhs: RainLineSegment, rhs: RainLineSegment) -> Bool {
        lhs.id == rhs.id && lhs.band == rhs.band && lhs.chance == rhs.chance
            && lhs.coordinates.count == rhs.coordinates.count
    }
}

/// A departure that rides through less rain than the one picked.
struct RainDepartureSuggestion: Equatable {
    var departure: Date
    var maxChance: Double
    var currentMaxChance: Double
}

enum RouteRainTiming {

    /// Splits the route line into stretches by rain band. Each point of the
    /// line takes the band of the nearest forecast sample by distance; touching
    /// stretches of the same band are merged so the map draws few overlays.
    static func segments(
        path: [(coordinate: CLLocationCoordinate2D, distance: CLLocationDistance)],
        profile: RouteRainProfile,
        departure: Date
    ) -> [RainLineSegment] {
        let samples = profile.samples.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        guard path.count >= 2, !samples.isEmpty else { return [] }
        let chances = samples.map { RouteRainProfile.chance(at: $0, departure: departure) }
        // Boundaries halfway between consecutive samples.
        let boundaries = zip(samples, samples.dropFirst()).map {
            ($0.distanceAlongRoute + $1.distanceAlongRoute) / 2
        }

        var segments: [RainLineSegment] = []
        var sampleIndex = 0
        for point in path {
            while sampleIndex < boundaries.count, point.distance > boundaries[sampleIndex] {
                sampleIndex += 1
            }
            let chance = chances[sampleIndex]
            let band = RainBand(chance: chance)
            if let last = segments.last, last.band == band {
                // Append in place: copying the last segment out would copy its
                // whole coordinate array on every point of a long ride.
                let index = segments.count - 1
                segments[index].coordinates.append(point.coordinate)
                segments[index].chance = max(last.chance ?? 0, chance ?? 0)
            } else {
                // Start the new stretch at the previous point so the line
                // has no gap where the colour changes.
                var start: [CLLocationCoordinate2D] = []
                if let previous = segments.last?.coordinates.last { start.append(previous) }
                start.append(point.coordinate)
                segments.append(RainLineSegment(id: segments.count, coordinates: start, band: band, chance: chance))
            }
        }
        return segments.filter { $0.coordinates.count >= 2 }
    }

    /// Departures tried, from the picked time, every 30 minutes for 6 hours.
    static let searchStep: TimeInterval = 30 * 60
    static let searchWindow: TimeInterval = 6 * 60 * 60

    /// Suggests leaving at a time that keeps the ride under the warning
    /// threshold, or at least cuts the worst chance by 20 points. Earlier
    /// options (back to `now`) and later ones are both tried; the one closest
    /// to the picked time wins a tie. Nil when the picked time is already dry
    /// or nothing is meaningfully better.
    static func betterDeparture(
        profile: RouteRainProfile,
        departure: Date,
        now: Date,
        threshold: Double = RainBand.possibleThreshold
    ) -> RainDepartureSuggestion? {
        guard let current = profile.forecast(departure: departure)?.maxChance,
              current >= threshold else { return nil }

        let steps = Int(searchWindow / searchStep)
        var best: (date: Date, chance: Double)?
        for step in 1...steps {
            for sign in [1.0, -1.0] {
                let date = departure.addingTimeInterval(sign * Double(step) * searchStep)
                // Never suggest leaving in the past.
                guard date >= now.addingTimeInterval(-60) else { continue }
                // Every sample needs a forecast for this time, or the "dry"
                // answer would only be dry because data ran out.
                let chances = profile.samples.map { RouteRainProfile.chance(at: $0, departure: date) }
                guard !chances.isEmpty, chances.allSatisfy({ $0 != nil }) else { continue }
                let worst = chances.compactMap { $0 }.max() ?? 0
                if best == nil || worst < best!.chance - 1e-6 {
                    best = (date, worst)
                }
            }
            // Stop at the closest dry option.
            if let best, best.chance < threshold { break }
        }

        guard let best else { return nil }
        let dryEnough = best.chance < threshold
        let muchBetter = current - best.chance >= 0.2
        guard dryEnough || muchBetter else { return nil }
        return RainDepartureSuggestion(departure: best.date, maxChance: best.chance, currentMaxChance: current)
    }

    /// "Leave at 10:30 AM to stay dry" or "Leave at 10:30 AM: rain drops to 35%".
    static func suggestionText(_ suggestion: RainDepartureSuggestion, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        formatter.dateStyle = Calendar.current.isDate(suggestion.departure, inSameDayAs: Date()) ? .none : .short
        formatter.timeStyle = .short
        let time = formatter.string(from: suggestion.departure)
        if suggestion.maxChance < RainBand.possibleThreshold {
            return "Leave at \(time) to stay dry"
        }
        let percent = Int((suggestion.maxChance * 100).rounded())
        return "Leave at \(time): rain drops to \(percent)%"
    }
}
