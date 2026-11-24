import CoreLocation
import XCTest
@testable import PerfectRouter

/// #66: no breakfast or dinner Meal stop the rider eats at the hotel; an
/// applied food waypoint covers its meal. 50 mph everywhere (72 s a mile).
final class MealStopRulesTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    private func legs(miles: Double) -> [FuelStopRidingTime.Leg] {
        [FuelStopRidingTime.Leg(distanceMeters: miles * mile, expectedTravelTime: miles / 50 * 3_600)]
    }

    private func start(_ miles: Double, _ hour: Int, _ minute: Int = 0) -> RideClock.DayStart {
        RideClock.DayStart(distance: miles * mile, minutes: hour * 60 + minute)
    }

    private func fuelWithFood(_ miles: Double) -> RideClock.Stop {
        RideClock.Stop(distance: miles * mile, kind: .fuel(hasFood: true))
    }

    // MARK: - Breakfast

    func testDayTwoFuelStopAtQuarterToNineIsNotABreakfastMealStop() {
        // Day 2 starts 8:00 at mile 500; mile 537.5 is 8:45.
        let clock = RideClock(
            legs: legs(miles: 1_000),
            dayStarts: [start(0, 8), start(500, 8)],
            stops: [fuelWithFood(537.5)]
        )
        XCTAssertFalse(clock.isMealStopTime(minutes: 8 * 60 + 45, atDistance: 537.5 * mile))
        // Plain 15 min allowance: mile 600 is 10:00 + 15.
        XCTAssertEqual(clock.minutes(atDistance: 600 * mile), 10 * 60 + 15, accuracy: 0.01)
    }

    func testEarlyStartStillGetsABreakfastMealStop() {
        // Leaving 6:30, mile 37.5 is 7:15.
        let clock = RideClock(legs: legs(miles: 500), dayStarts: [start(0, 6, 30)], stops: [fuelWithFood(37.5)])
        XCTAssertTrue(clock.isMealStopTime(minutes: 7 * 60 + 15, atDistance: 37.5 * mile))
        XCTAssertEqual(clock.minutes(atDistance: 100 * mile), 8 * 60 + 30 + 45, accuracy: 0.01)
    }

    // MARK: - Dinner

    func testDayEndingAtAnEveningBeforeEightSkipsDinner() {
        // Hotel time 6:00 PM on a long ride: mile 483.3 is 5:40 PM.
        let clock = RideClock(
            legs: legs(miles: 1_500),
            dayStarts: [start(0, 8)],
            stops: [fuelWithFood(483.3)],
            hotelMinutes: 18 * 60
        )
        XCTAssertFalse(clock.isMealStopTime(minutes: 17 * 60 + 40, atDistance: 483.3 * mile))
    }

    func testDayEndingAtNineGetsADinnerMealStop() {
        // Destination at 9:00 PM (650 mi), no hotel time. Mile 525 is 6:30 PM.
        let clock = RideClock(legs: legs(miles: 650), dayStarts: [start(0, 8)], stops: [fuelWithFood(525)])
        XCTAssertTrue(clock.isMealStopTime(minutes: 18 * 60 + 30, atDistance: 525 * mile))
        XCTAssertEqual(clock.minutes(atDistance: 600 * mile), 20 * 60 + 45, accuracy: 0.01)
    }

    // MARK: - Food waypoint covers its meal

    func testAppliedRestaurantAtTenPastTwelveCoversLunch() {
        // Mile 208.3 is 12:10. Then 45 min stopped; mile 250 is 1:45.
        let food = RideClock.Stop(distance: 208.3 * mile, kind: .food)
        let clock = RideClock(legs: legs(miles: 600), dayStarts: [start(0, 8)], stops: [food, fuelWithFood(250)])
        XCTAssertEqual(clock.minutes(atDistance: 250 * mile), 13 * 60 + 45, accuracy: 0.1)
        XCTAssertFalse(clock.isMealStopTime(minutes: 13 * 60, atDistance: 250 * mile))
        // Plain 15 min at the fuel stop: mile 300 is 1:45 + 1h + 15.
        XCTAssertEqual(clock.minutes(atDistance: 300 * mile), 15 * 60, accuracy: 0.1)
    }

    func testFoodWaypointOutsideAMealWindowIsFifteenMinutes() {
        // Mile 125 is 10:30.
        let clock = RideClock(legs: legs(miles: 600), dayStarts: [start(0, 8)], stops: [RideClock.Stop(distance: 125 * mile, kind: .food)])
        XCTAssertEqual(clock.minutes(atDistance: 200 * mile), 12 * 60 + 15, accuracy: 0.01)
        XCTAssertTrue(clock.isMealStopTime(minutes: 12 * 60 + 15, atDistance: 200 * mile))
    }

    // MARK: - Fuel planning

    /// Same ride as RideClockTests.testMealPreferenceUsesTheClockWithAllowances,
    /// where the second tank lands in lunch and the pump with food wins. A
    /// restaurant the rider applied at mile 165 (11:33) is lunch, so the
    /// planner keeps the farthest gas-only pump.
    func testFoodWaypointKeepsThePlannerFromSeekingLunch() {
        func pump(_ miles: Double) -> SuggestedStop {
            SuggestedStop(
                name: "Pump \(Int(miles))",
                coordinate: CLLocationCoordinate2D(latitude: 35, longitude: -100 + miles / 100),
                category: .gas,
                distanceAlongRoute: miles * mile
            )
        }
        let first = pump(84)
        let withFood = pump(160)
        let gasOnly = pump(168)
        let stations = [first, withFood, gasOnly, pump(240), pump(320)]
        func plan(_ stops: [RideClock.Stop]) -> [UUID] {
            let clock = RideClock(legs: legs(miles: 400), dayStarts: [start(0, 8)], stops: stops)
            return Array(RoutePlannerViewModel.fuelPlan(
                from: stations,
                totalDistance: 400 * mile,
                range: 100 * mile,
                preferringFoodAt: [withFood.id],
                clock: clock
            ).stops.map(\.id).prefix(2))
        }
        XCTAssertEqual(plan([]), [first.id, withFood.id])
        XCTAssertEqual(plan([RideClock.Stop(distance: 165 * mile, kind: .food)]), [first.id, gasOnly.id])
    }

    // MARK: - Codex review on #71

    /// Leaving 6:30, breakfast at the mile 37.5 pump is 45 min, so the
    /// restaurant at mile 220.833 is reached 11:40, not 11:10: it is lunch,
    /// and the pump at mile 250 (1:00 PM) is a plain fuel stop.
    func testFoodCoverageCountsEarlierMealStops() {
        let clock = RideClock(
            legs: legs(miles: 600),
            dayStarts: [start(0, 6, 30)],
            stops: [fuelWithFood(37.5), RideClock.Stop(distance: 220.833 * mile, kind: .food), fuelWithFood(250)]
        )
        XCTAssertEqual(clock.minutes(atDistance: 220.833 * mile), 11 * 60 + 40, accuracy: 0.1)
        XCTAssertFalse(clock.isMealStopTime(minutes: 13 * 60, atDistance: 250 * mile))
        XCTAssertEqual(clock.minutes(atDistance: 300 * mile), 14 * 60 + 15, accuracy: 0.1)
    }

    /// Lunch at mile 200 is 45 min, so the mile 500 pump is 6:45 PM and the
    /// destination is past 8:00 PM even with a plain stop there: dinner.
    func testDinnerCutoffCountsAnEarlierLunch() {
        let clock = RideClock(
            legs: legs(miles: 562.5),
            dayStarts: [start(0, 8)],
            stops: [fuelWithFood(200), fuelWithFood(500)]
        )
        XCTAssertTrue(clock.isMealStopTime(minutes: 18 * 60 + 45, atDistance: 500 * mile))
        XCTAssertEqual(clock.minutes(atDistance: 562.5 * mile), 20 * 60 + 45, accuracy: 0.1)
    }

    /// A restaurant 1,400 mi out is on a later riding day: it does not cover
    /// today's lunch, so day 1's Evening stays at mile 462.5.
    func testFoodOnALaterDayDoesNotCoverTodaysLunch() {
        let ride = legs(miles: 1_500)
        func firstEvening(_ stops: [RideClock.Stop]) -> CLLocationDistance {
            HotelAlongRoute.evenings(
                legs: ride,
                overnightDistances: [],
                departureMinutes: 8 * 60,
                targetMinutes: 18 * 60,
                stops: stops
            ).first?.targetDistance ?? 0
        }
        let lunch = fuelWithFood(200)
        XCTAssertEqual(firstEvening([lunch]) / mile, 462.5, accuracy: 0.1)
        XCTAssertEqual(
            firstEvening([lunch, RideClock.Stop(distance: 1_400 * mile, kind: .food)]) / mile,
            462.5,
            accuracy: 0.1
        )
    }
}
