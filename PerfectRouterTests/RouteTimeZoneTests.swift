import CoreLocation
import XCTest
@testable import PerfectRouter

/// Clock times are local time at that point on the route (#67), like a
/// ride from Albuquerque (Mountain) to Amarillo (Central).
@MainActor
final class RouteTimeZoneTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }
    private let mountain = -7 * 3_600
    private let central = -6 * 3_600

    /// 50 mph everywhere: one mile is 72 seconds of riding.
    private func steadyLegs(miles: Double = 1_000) -> [FuelStopRidingTime.Leg] {
        [FuelStopRidingTime.Leg(distanceMeters: miles * mile, expectedTravelTime: miles / 50 * 3_600)]
    }

    /// Starts in `from`, crosses into `to` at `lineMiles`.
    private func zones(from: Int, to: Int, lineMiles: Double = 100, phone: Int? = nil) -> RideClock.Zones {
        RideClock.Zones(
            marks: [.init(distance: 0, secondsFromGMT: from), .init(distance: lineMiles * mile, secondsFromGMT: to)],
            phoneSecondsFromGMT: phone ?? from
        )
    }

    private func clock(departure: Int = 8 * 60, zones: RideClock.Zones, stops: [RideClock.Stop] = []) -> RideClock {
        RideClock(
            legs: steadyLegs(),
            dayStarts: [RideClock.DayStart(distance: 0, minutes: departure)],
            stops: stops,
            zones: zones
        )
    }

    private func isLunchStop(_ clock: RideClock, atMiles miles: Double) -> Bool {
        let distance = miles * mile
        return clock.isMealStopTime(minutes: clock.minutes(atDistance: distance), atDistance: distance)
    }

    // MARK: Acceptance

    /// Eastbound, 8:00 AM Mountain. 212.5 mi is 12:15 PM in Mountain when
    /// the line is past it: lunch.
    func testTwelveFifteenMountainCountsAsLunch() {
        let ride = clock(zones: zones(from: mountain, to: central, lineMiles: 250))
        XCTAssertEqual(ride.minutes(atDistance: 212.5 * mile), 12 * 60 + 15, accuracy: 0.01)
        XCTAssertTrue(isLunchStop(ride, atMiles: 212.5))
    }

    /// Westbound from Central: 287.5 mi is 1:45 PM at the start but 12:45 PM
    /// Mountain where the rider is, so it is still lunch.
    func testLunchIsReadInTheZoneWhereTheStopIs() {
        let ride = clock(zones: zones(from: central, to: mountain))
        XCTAssertEqual(ride.minutes(atDistance: 287.5 * mile), 12 * 60 + 45, accuracy: 0.01)
        XCTAssertTrue(isLunchStop(ride, atMiles: 287.5))

        let phoneOnly = clock(zones: .phone)
        XCTAssertFalse(isLunchStop(phoneOnly, atMiles: 287.5), "without zones it reads 1:45 PM")
    }

    /// Eastbound: 237.5 mi is 12:45 PM Mountain, 1:45 PM Central. Past the
    /// line that is after lunch.
    func testEastboundLunchEndsAnHourEarlierPastTheLine() {
        let ride = clock(zones: zones(from: mountain, to: central))
        XCTAssertEqual(ride.minutes(atDistance: 237.5 * mile), 13 * 60 + 45, accuracy: 0.01)
        XCTAssertFalse(isLunchStop(ride, atMiles: 237.5))
    }

    /// A 6:00 PM hotel time near Amarillo is 6:00 PM Central: 5:00 PM on the
    /// Mountain clock the ride left on, 450 mi at 50 mph instead of 500.
    func testHotelTimeIsEvaluatedInCentral() {
        let evenings = HotelAlongRoute.evenings(
            legs: steadyLegs(),
            overnightDistances: [],
            departureMinutes: 8 * 60,
            targetMinutes: 18 * 60,
            zones: zones(from: mountain, to: central)
        )
        let first = try? XCTUnwrap(evenings.first)
        XCTAssertEqual((first?.targetDistance ?? 0) / mile, 450, accuracy: 0.1)

        let phoneOnly = HotelAlongRoute.evenings(
            legs: steadyLegs(),
            overnightDistances: [],
            departureMinutes: 8 * 60,
            targetMinutes: 18 * 60
        )
        XCTAssertEqual((phoneOnly.first?.targetDistance ?? 0) / mile, 500, accuracy: 0.1)
    }

    /// The hotel caption reads Central time at the hotel.
    func testHotelArrivalIsLocalAtTheHotel() {
        let arrival = HotelAlongRoute.arrivalMinutes(
            atDistance: 450 * mile,
            legs: steadyLegs(),
            dayStartDistance: 0,
            departureMinutes: 8 * 60,
            zones: zones(from: mountain, to: central)
        )
        XCTAssertEqual(arrival, 18 * 60)
    }

    // MARK: Zone lines

    /// Riding east, 10:00 AM Mountain becomes 11:00 AM Central at the line.
    /// A 10:30 target is skipped; the answer is the line.
    func testTargetSkippedByTheLineIsTheLine() {
        let ride = clock(zones: zones(from: mountain, to: central))
        let start = ride.dayStart(for: 0)
        XCTAssertEqual(ride.distance(reachingMinutes: 10 * 60 + 30, from: start) / mile, 100, accuracy: 0.01)
        XCTAssertEqual(ride.distance(reachingMinutes: 12 * 60, from: start) / mile, 150, accuracy: 0.01)
    }

    /// Riding west the clock falls back at the line. The answer is the first
    /// time the clock reads the target, before the line.
    func testWestboundTargetIsFirstReachBeforeTheLine() {
        let ride = clock(zones: zones(from: central, to: mountain))
        let start = ride.dayStart(for: 0)
        XCTAssertEqual(ride.distance(reachingMinutes: 9 * 60 + 30, from: start) / mile, 75, accuracy: 0.01)
        XCTAssertEqual(ride.distance(reachingMinutes: 10 * 60 + 30, from: start) / mile, 175, accuracy: 0.01)
    }

    /// A Morning start's 8:00 AM is local where the day starts, so a second
    /// day that starts past the line starts at 8:00 Central.
    func testLaterDayStartsInItsOwnZone() {
        let ride = RideClock(
            legs: steadyLegs(),
            dayStarts: [
                RideClock.DayStart(distance: 0, minutes: 8 * 60),
                RideClock.DayStart(distance: 450 * mile, minutes: 8 * 60),
            ],
            zones: zones(from: mountain, to: central)
        )
        XCTAssertEqual(ride.minutes(atDistance: 500 * mile), 9 * 60, accuracy: 0.01)
    }

    // MARK: Fallback

    /// With no zone known for a point, the phone's zone is used.
    func testUnknownPointUsesThePhoneZone() {
        let zones = RideClock.Zones(
            marks: [.init(distance: 200 * mile, secondsFromGMT: central)],
            phoneSecondsFromGMT: mountain
        )
        XCTAssertEqual(zones.secondsFromGMT(at: 50 * mile), mountain)
        XCTAssertEqual(zones.secondsFromGMT(at: 250 * mile), central)
        XCTAssertEqual(zones.changes(after: 0), [200 * mile])
    }

    /// No zones at all: today's clock, unchanged.
    func testPhoneZonesMatchTheOldClock() {
        let ride = clock(zones: .phone)
        XCTAssertEqual(ride.minutes(atDistance: 237.5 * mile), 12 * 60 + 45, accuracy: 0.01)
        XCTAssertEqual(ride.distance(reachingMinutes: 18 * 60, from: ride.dayStart(for: 0)) / mile, 500, accuracy: 0.01)
    }

    // MARK: Lookups

    /// Each waypoint coordinate is looked up once; a later edit does not
    /// repeat lookups that already ran, including ones that found nothing.
    func testWaypointZonesAreLookedUpOncePerPlace() async {
        let model = RoutePlannerViewModel()
        var calls: [String] = []
        let albuquerque = CLLocationCoordinate2D(latitude: 35.0844, longitude: -106.6504)
        let amarillo = CLLocationCoordinate2D(latitude: 35.2220, longitude: -101.8313)
        let tucumcari = CLLocationCoordinate2D(latitude: 35.1717, longitude: -103.7250)
        model.timeZoneLookup = { coordinate in
            calls.append(RoutePlannerViewModel.coordinateKey(coordinate))
            if coordinate.longitude == amarillo.longitude { return TimeZone(identifier: "America/Chicago") }
            if coordinate.longitude == albuquerque.longitude { return TimeZone(identifier: "America/Denver") }
            return nil
        }
        model.waypoints = [Waypoint(name: "ABQ", coordinate: albuquerque), Waypoint(name: "AMA", coordinate: amarillo)]
        await model.waitForTimeZoneLookups()
        model.waypoints.insert(Waypoint(name: "Tucumcari", coordinate: tucumcari), at: 1)
        await model.waitForTimeZoneLookups()
        model.waypoints.remove(at: 1)
        model.waypoints.insert(Waypoint(name: "Tucumcari", coordinate: tucumcari), at: 1)
        await model.waitForTimeZoneLookups()

        XCTAssertEqual(calls.count, 3)
        XCTAssertEqual(Set(calls).count, 3)
        XCTAssertEqual(model.cachedTimeZone(for: amarillo)?.identifier, "America/Chicago")
        XCTAssertEqual(model.cachedTimeZone(for: albuquerque)?.identifier, "America/Denver")
        XCTAssertNil(model.cachedTimeZone(for: tucumcari))
    }
}
