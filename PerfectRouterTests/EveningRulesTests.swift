import CoreLocation
import XCTest
@testable import PerfectRouter

/// #65: an Overnight ends the riding day it is reached on; no Evening right
/// before the destination. 50 mph everywhere, 8:00 departure, hotel time
/// 6:00 PM, so day 1's Evening point is mile 500.
final class EveningRulesTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    private func legs(miles: Double) -> [FuelStopRidingTime.Leg] {
        [FuelStopRidingTime.Leg(distanceMeters: miles * mile, expectedTravelTime: miles / 50 * 3_600)]
    }

    private func evenings(miles: Double, overnights: [Double] = []) -> [HotelAlongRoute.Evening] {
        HotelAlongRoute.evenings(
            legs: legs(miles: miles),
            overnightDistances: overnights.map { $0 * mile },
            departureMinutes: 8 * 60,
            targetMinutes: 18 * 60
        )
    }

    private func days(miles: Double, overnights: [Double]) -> [HotelAlongRoute.RideDay] {
        HotelAlongRoute.rideDays(
            evenings: evenings(miles: miles, overnights: overnights),
            overnightDistances: overnights.map { $0 * mile },
            totalDistance: miles * mile,
            legs: legs(miles: miles),
            dailyLimit: HotelAlongRoute.dailyRidingLimit(targetMinutes: 18 * 60)
        )
    }

    // MARK: - An Overnight ends the day it is reached on

    /// The 80 mi slack used to hand this hotel to day 2 and leave night 1
    /// showing "No hotel picked".
    func testHotelHundredMilesPastTheEveningIsThatNight() {
        let remaining = evenings(miles: 1_500, overnights: [600])
        // Day 1 ends at the hotel. Day 2 runs 8:00 from mile 600 → Evening at 1,100.
        XCTAssertEqual(remaining.map(\.dayNumber), [2])
        XCTAssertEqual(remaining[0].dayStartDistance, 600 * mile, accuracy: 1)
        XCTAssertEqual(remaining[0].targetDistance, 1_100 * mile, accuracy: 1)

        let split = days(miles: 1_500, overnights: [600])
        XCTAssertEqual(split.map(\.endDistance).map { ($0 / mile).rounded() }, [600, 1_100, 1_500])
        XCTAssertNil(split[0].unpickedEvening)
        XCTAssertEqual(split[1].unpickedEvening, 2)
    }

    func testHotelWellBeforeHotelTimeStillEndsThatDay() {
        // Mile 300 is 2:00 PM.
        let remaining = evenings(miles: 1_200, overnights: [300])
        XCTAssertEqual(remaining.first?.dayStartDistance ?? 0, 300 * mile, accuracy: 1)
        XCTAssertEqual(remaining.first?.targetDistance ?? 0, 800 * mile, accuracy: 1)
    }

    /// A hotel near tomorrow's Evening is tomorrow's: tonight it would be
    /// reached around 3 AM, tomorrow around 5 PM.
    func testHotelNearTomorrowsEveningLeavesTonightUnpicked() {
        let remaining = evenings(miles: 1_520, overnights: [950])
        XCTAssertEqual(remaining.map(\.dayNumber), [1, 3])
        XCTAssertEqual(remaining[0].targetDistance, 500 * mile, accuracy: 1)
        XCTAssertEqual(remaining[1].dayStartDistance, 950 * mile, accuracy: 1)
    }

    func testOutsideWindowNote() {
        XCTAssertEqual(
            HotelAlongRoute.outsideWindowNote(arrivalMinutes: 20 * 60, targetMinutes: 18 * 60),
            "Arrives after your hotel time"
        )
        XCTAssertEqual(
            HotelAlongRoute.outsideWindowNote(arrivalMinutes: 14 * 60, targetMinutes: 18 * 60),
            "Arrives before your hotel time"
        )
        XCTAssertNil(HotelAlongRoute.outsideWindowNote(arrivalMinutes: 19 * 60, targetMinutes: 18 * 60))
        XCTAssertNil(HotelAlongRoute.outsideWindowNote(arrivalMinutes: 17 * 60, targetMinutes: 18 * 60))
    }

    // MARK: - No Evening right before the destination

    func testDestinationAtTenPastSixHasNoEvening() {
        // 508 mi from 8:00 is 6:10 PM.
        XCTAssertTrue(evenings(miles: 508).isEmpty)
    }

    func testDestinationAtHalfPastSevenHasOneEvening() {
        // 575 mi from 8:00 is 7:30 PM, after the window closes at 7:00.
        let result = evenings(miles: 575)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.targetDistance ?? 0, 500 * mile, accuracy: 1)
    }

    func testDestinationJustBeforeTheWindowClosesHasNoEvening() {
        // 548 mi is 6:57.6 PM.
        XCTAssertTrue(evenings(miles: 548).isEmpty)
    }

    // MARK: - Codex review on #70

    /// Hotel time 8:15 AM, 8:00 departure: day 1's Evening is mile 12.5. A
    /// hotel at mile 25 is reached at 8:30 (day 1) or 8:15 (day 2), so it is
    /// day 2's and night 1 stays unpicked, though it is under 15 mi away.
    func testUnpickedEveningNearAnotherDaysHotelIsKept() {
        let ride = legs(miles: 80)
        let target = 8 * 60 + 15
        let overnights = [25 * mile]
        let planned = HotelAlongRoute.evenings(
            legs: ride,
            overnightDistances: overnights,
            departureMinutes: 8 * 60,
            targetMinutes: target
        )
        XCTAssertEqual(planned.first?.dayNumber, 1)
        XCTAssertEqual(planned.first?.targetDistance ?? 0, 12.5 * mile, accuracy: 1)
        let split = HotelAlongRoute.rideDays(
            evenings: planned,
            overnightDistances: overnights,
            totalDistance: 80 * mile,
            legs: ride,
            dailyLimit: HotelAlongRoute.dailyRidingLimit(targetMinutes: target)
        )
        XCTAssertEqual(split.first?.unpickedEvening, 1)
        XCTAssertEqual((split.first?.endDistance ?? 0) / mile, 12.5, accuracy: 0.1)
        XCTAssertEqual((split.dropFirst().first?.endDistance ?? 0) / mile, 25, accuracy: 0.1)
    }

    func testFirstDayStartMovesAnEveningDepartureToTheMorning() {
        XCTAssertEqual(HotelAlongRoute.firstDayStartMinutes(departureMinutes: 19 * 60, targetMinutes: 18 * 60), 8 * 60)
        XCTAssertEqual(HotelAlongRoute.firstDayStartMinutes(departureMinutes: 18 * 60, targetMinutes: 18 * 60), 8 * 60)
        XCTAssertEqual(HotelAlongRoute.firstDayStartMinutes(departureMinutes: 9 * 60, targetMinutes: 18 * 60), 9 * 60)
    }
}
