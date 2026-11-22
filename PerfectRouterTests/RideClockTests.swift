import CoreLocation
import XCTest
@testable import PerfectRouter

/// Clock predictions are riding time plus stop allowances (#64). Riding
/// captions stay moving time only.
final class RideClockTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    /// 50 mph everywhere: one mile is 72 seconds of riding.
    private func steadyLegs(miles: Double) -> [FuelStopRidingTime.Leg] {
        [FuelStopRidingTime.Leg(distanceMeters: miles * mile, expectedTravelTime: miles / 50 * 3_600)]
    }

    private func clock(
        miles: Double = 1_000,
        departure: Int = 8 * 60,
        stops: [RideClock.Stop] = [],
        dayStarts: [RideClock.DayStart] = []
    ) -> RideClock {
        RideClock(
            legs: steadyLegs(miles: miles),
            dayStarts: [RideClock.DayStart(distance: 0, minutes: departure)] + dayStarts,
            stops: stops
        )
    }

    private func fuel(_ miles: Double, food: Bool = false) -> RideClock.Stop {
        RideClock.Stop(distance: miles * mile, kind: .fuel(hasFood: food))
    }

    // MARK: - Allowances

    func testNoStopsIsRidingTimeOnly() {
        // 100 mi at 50 mph from 8:00 is 10:00.
        XCTAssertEqual(clock().minutes(atDistance: 100 * mile), 10 * 60, accuracy: 0.01)
    }

    /// Issue #64 fixture: 8:00 departure, 8h riding, three fuel stops of
    /// which one is a Meal stop. 8:00 + 8h + 15 + 15 + 45 = 5:15 PM.
    func testThreeFuelStopsOneOfThemAMealStop() {
        let subject = clock(stops: [
            fuel(100),              // 10:00, not a meal window
            fuel(200, food: true),  // 12:15 after the first allowance: lunch
            fuel(300),              // gas only
        ])
        XCTAssertEqual(subject.minutes(atDistance: 400 * mile), 17 * 60 + 15, accuracy: 0.01)
    }

    func testFoodOutsideAMealWindowIsAPlainFuelStop() {
        // Reached at 10:00, outside breakfast (ends 9:30) and lunch.
        let subject = clock(stops: [fuel(100, food: true)])
        XCTAssertEqual(subject.minutes(atDistance: 200 * mile), 12 * 60 + 15, accuracy: 0.01)
    }

    func testOtherWaypointsAddFifteenMinutes() {
        let subject = clock(stops: [RideClock.Stop(distance: 50 * mile, kind: .waypoint)])
        XCTAssertEqual(subject.minutes(atDistance: 100 * mile), 10 * 60 + 15, accuracy: 0.01)
    }

    func testAStopAtTheDistanceIsTheArrivalNotAPause() {
        let subject = clock(stops: [fuel(100)])
        XCTAssertEqual(subject.minutes(atDistance: 100 * mile), 10 * 60, accuracy: 0.01)
    }

    func testStopsOnAnEarlierDayDoNotDelayTheNextMorning() {
        let subject = clock(
            stops: [fuel(100), fuel(600)],
            dayStarts: [RideClock.DayStart(distance: 500 * mile, minutes: 8 * 60)]
        )
        // Day 2: 8:00 at mile 500, 100 mi to mile 600 = 10:00; one stop then 50 mi.
        XCTAssertEqual(subject.minutes(atDistance: 650 * mile), 11 * 60 + 15, accuracy: 0.01)
    }

    // MARK: - Inverse

    func testDistanceReachingAClockSubtractsAllowances() {
        let start = RideClock.DayStart(distance: 0, minutes: 8 * 60)
        // Moving only: 10h to 6 PM is 500 mi.
        XCTAssertEqual(clock().distance(reachingMinutes: 18 * 60, from: start) / mile, 500, accuracy: 0.01)
        // Two 15-minute stops cost 30 minutes of riding: 25 mi less.
        let stopped = clock(stops: [fuel(100), fuel(300)])
        XCTAssertEqual(stopped.distance(reachingMinutes: 18 * 60, from: start) / mile, 475, accuracy: 0.01)
    }

    func testTargetPassingDuringAStopReturnsThatStop() {
        let start = RideClock.DayStart(distance: 0, minutes: 8 * 60)
        // Mile 100 at 10:00, stopped until 10:15. 10:05 lands on the stop.
        XCTAssertEqual(clock(stops: [fuel(100)]).distance(reachingMinutes: 10 * 60 + 5, from: start) / mile, 100, accuracy: 0.01)
    }

    func testInverseRoundTrips() {
        let subject = clock(stops: [fuel(120, food: true), fuel(260), RideClock.Stop(distance: 330 * mile, kind: .waypoint)])
        let start = RideClock.DayStart(distance: 0, minutes: 8 * 60)
        for target in stride(from: 9.0 * 60, through: 16.0 * 60, by: 37) {
            let distance = subject.distance(reachingMinutes: target, from: start)
            let back = subject.minutes(atDistance: distance)
            // Inside a pause the clock reads the arrival, at or before the target.
            XCTAssertLessThanOrEqual(back, target + 0.01)
            XCTAssertGreaterThan(back, target - 46)
        }
    }

    // MARK: - Meal windows

    func testMealTimeWrapsPastMidnight() {
        XCTAssertTrue(RideClock.isMealTime(minutes: 24 * 60 + 8 * 60, windows: MealWindow.typical))
        XCTAssertFalse(RideClock.isMealTime(minutes: 24 * 60 + 10 * 60, windows: MealWindow.typical))
    }

    // MARK: - Evenings and hotel arrivals

    func testEveningMovesEarlierWithStopsAndRidingCaptionStaysMovingTime() {
        let legs = steadyLegs(miles: 1_000)
        let plain = HotelAlongRoute.evenings(
            legs: legs, overnightDistances: [], departureMinutes: 8 * 60, targetMinutes: 18 * 60
        )
        let stopped = HotelAlongRoute.evenings(
            legs: legs, overnightDistances: [], departureMinutes: 8 * 60, targetMinutes: 18 * 60,
            stops: [fuel(100), fuel(300)]
        )
        XCTAssertEqual(plain.first?.targetDistance ?? 0, 500 * mile, accuracy: 1)
        XCTAssertEqual(stopped.first?.targetDistance ?? 0, 475 * mile, accuracy: 1)
        // 475 mi at 50 mph is 9h 30m of riding.
        XCTAssertEqual(stopped.first?.ridingSeconds ?? 0, 9.5 * 3_600, accuracy: 1)
    }

    func testHotelArrivalCountsStopsBeforeIt() {
        let legs = steadyLegs(miles: 1_000)
        let arrival = HotelAlongRoute.arrivalMinutes(
            atDistance: 450 * mile,
            legs: legs,
            dayStartDistance: 0,
            departureMinutes: 8 * 60,
            stops: [fuel(100), fuel(300)]
        )
        // 9h riding + 30 min stopped.
        XCTAssertEqual(arrival, 17 * 60 + 30)
    }

    // MARK: - Fuel planning

    /// 100 mi tank (85 mi comfort range), 50 mph from 8:00. The first tank
    /// ends near mile 85 at 9:42, after breakfast. Riding time alone puts
    /// the second tank's target (mile 169) at 11:23, before lunch, so the
    /// farthest pump wins. With the first fuel stop's 15 minutes it is
    /// 11:38, inside lunch, so the pump with food wins.
    func testMealPreferenceUsesTheClockWithAllowances() {
        let legs = steadyLegs(miles: 400)
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
        let departure = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date())!

        let ridingOnly = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 400 * mile,
            range: 100 * mile,
            preferringFoodAt: [withFood.id],
            departure: departure,
            totalTravelTime: 8 * 3_600
        )
        XCTAssertEqual(Array(ridingOnly.stops.map(\.id).prefix(2)), [first.id, gasOnly.id])

        let rideClock = RideClock(legs: legs, dayStarts: [RideClock.DayStart(distance: 0, minutes: 8 * 60)])
        let withAllowances = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 400 * mile,
            range: 100 * mile,
            preferringFoodAt: [withFood.id],
            departure: departure,
            totalTravelTime: 8 * 3_600,
            clock: rideClock
        )
        XCTAssertEqual(Array(withAllowances.stops.map(\.id).prefix(2)), [first.id, withFood.id])
    }

    // MARK: - View model stops (Codex review on #68)

    /// A ride with only a start and a destination still counts its
    /// recommended fuel stops, and food pairing marks the Meal-stop candidate.
    @MainActor
    func testTwoWaypointRideCountsFuelStopsAndPairedFood() {
        let viewModel = RoutePlannerViewModel()
        let origin = UITestFixture.origin
        let destination = UITestFixture.coordinate(milesNorth: 280, eastMeters: 0)
        viewModel.waypoints = [
            Waypoint(name: "Test Origin", coordinate: origin),
            Waypoint(name: "Test Destination", coordinate: destination),
        ]
        viewModel.legs = [StubRouteBuilder.routes(from: origin, to: destination, avoidsHighways: false, alternates: false)[0]]
        let gasOnly = SuggestedStop(
            name: "Gas Only",
            coordinate: UITestFixture.coordinate(milesNorth: 90, eastMeters: 0),
            category: .gas,
            distanceAlongRoute: 90 * mile
        )
        let withFood = SuggestedStop(
            name: "Gas And Diner",
            coordinate: UITestFixture.coordinate(milesNorth: 180, eastMeters: 0),
            category: .gas,
            distanceAlongRoute: 180 * mile
        )
        let diner = SuggestedStop(
            name: "Diner",
            coordinate: UITestFixture.coordinate(milesNorth: 180, eastMeters: 200),
            category: .food,
            distanceAlongRoute: 180 * mile
        )
        viewModel.fuelStops = [gasOnly, withFood]
        viewModel.fuelFoodStops = [
            FuelFoodStop(fuelStop: gasOnly, nearbyFood: []),
            FuelFoodStop(fuelStop: withFood, nearbyFood: [diner]),
        ]

        let stops = viewModel.rideClockStops(includingFuelStops: true)
        XCTAssertEqual(stops.map(\.kind), [.fuel(hasFood: false), .fuel(hasFood: true)])
        XCTAssertTrue(viewModel.rideClockStops(includingFuelStops: false).isEmpty)
    }
}
