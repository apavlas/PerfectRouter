import CoreLocation
import XCTest
@testable import PerfectRouter

/// Rain on the route map and the better-departure suggestion.
final class RouteRainTimingTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 12, day: 5, hour: hour, minute: minute))!
    }

    /// Hourly forecast 6:00–20:00, 70% at 9, 10 and 11, otherwise 10%.
    private func morningShower() -> [HourlyRainChance] {
        (6...20).map { hour in
            HourlyRainChance(date: time(hour), chance: (9...11).contains(hour) ? 0.7 : 0.1)
        }
    }

    private func profile() -> RouteRainProfile {
        RouteRainProfile(samples: [
            RouteRainSample(
                coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -122),
                distanceAlongRoute: 0,
                offsetFromDeparture: 0,
                hourly: morningShower()
            ),
            RouteRainSample(
                coordinate: CLLocationCoordinate2D(latitude: 37, longitude: -121.9),
                distanceAlongRoute: 60_000,
                offsetFromDeparture: 3_600,
                hourly: morningShower()
            ),
        ])
    }

    func testChanceUsesTheHourWhenTheRiderPasses() {
        let sample = profile().samples[1]
        XCTAssertEqual(RouteRainProfile.chance(at: sample, departure: time(8)), 0.7)
        XCTAssertEqual(RouteRainProfile.chance(at: sample, departure: time(12)), 0.1)
    }

    func testChanceIsUnknownOutsideTheForecast() {
        let sample = profile().samples[0]
        XCTAssertNil(RouteRainProfile.chance(at: sample, departure: time(23)))
    }

    func testForecastReportsWorstPointForDeparture() {
        let forecast = profile().forecast(departure: time(8))
        XCTAssertEqual(forecast?.maxChance, 0.7)
        XCTAssertEqual(forecast?.distanceOfMaxChance, 60_000)
    }

    func testSuggestsTheClosestDryDeparture() {
        let suggestion = RouteRainTiming.betterDeparture(profile: profile(), departure: time(9), now: time(8))
        XCTAssertEqual(suggestion?.departure, time(12))
        XCTAssertEqual(suggestion?.maxChance, 0.1)
        XCTAssertEqual(suggestion?.currentMaxChance, 0.7)
    }

    func testNoSuggestionWhenAlreadyDry() {
        XCTAssertNil(RouteRainTiming.betterDeparture(profile: profile(), departure: time(13), now: time(8)))
    }

    func testNeverSuggestsLeavingInThePast() {
        // From 11:00 the closest dry time is earlier (7:00 would be dry), but
        // it's already 10:30, so the answer must be later.
        let suggestion = RouteRainTiming.betterDeparture(profile: profile(), departure: time(11), now: time(10, 30))
        XCTAssertNotNil(suggestion)
        XCTAssertGreaterThanOrEqual(suggestion!.departure, time(10, 30))
    }

    func testSegmentsSplitWhereTheBandChanges() {
        let dryThenWet = RouteRainProfile(samples: [
            RouteRainSample(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                distanceAlongRoute: 0,
                offsetFromDeparture: 0,
                hourly: [HourlyRainChance(date: time(9), chance: 0.05)]
            ),
            RouteRainSample(
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0.09),
                distanceAlongRoute: 10_000,
                offsetFromDeparture: 600,
                hourly: [HourlyRainChance(date: time(9), chance: 0.8)]
            ),
        ])
        let path: [(coordinate: CLLocationCoordinate2D, distance: CLLocationDistance)] = [
            (CLLocationCoordinate2D(latitude: 0, longitude: 0), 0),
            (CLLocationCoordinate2D(latitude: 0, longitude: 0.045), 5_000),
            (CLLocationCoordinate2D(latitude: 0, longitude: 0.09), 10_000),
        ]
        let segments = RouteRainTiming.segments(path: path, profile: dryThenWet, departure: time(9))
        XCTAssertEqual(segments.map(\.band), [.dry, .likely])
        XCTAssertEqual(segments.map(\.coordinates.count), [2, 2])
    }

    func testFirstRainIsTheEarliestWetPoint() {
        let first = profile().firstRain(departure: time(8), threshold: 0.3)
        XCTAssertEqual(first?.sample.distanceAlongRoute, 60_000)
        XCTAssertEqual(first?.chance, 0.7)
    }

    func testBands() {
        XCTAssertEqual(RainBand(chance: nil), .dry)
        XCTAssertEqual(RainBand(chance: 0.29), .dry)
        XCTAssertEqual(RainBand(chance: 0.3), .possible)
        XCTAssertEqual(RainBand(chance: 0.6), .likely)
    }
}
