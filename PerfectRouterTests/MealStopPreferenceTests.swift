import XCTest
import CoreLocation
import MapKit
@testable import PerfectRouter

/// #69: the Meal stop preference has to work in the app, not only when a
/// test passes `preferringFoodAt` by hand. The planner names the pumps that
/// competed for each meal-time tank; the view model checks a few of them for
/// food and plans again.
final class MealStopPreferenceTests: XCTestCase {
    private let mile = UITestFixture.metersPerMile

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(hour: Int, minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: hour, minute: minute))!
    }

    private func gas(_ miles: Double) -> SuggestedStop {
        SuggestedStop(
            name: "Pump \(Int(miles))",
            coordinate: CLLocationCoordinate2D(latitude: 35, longitude: -100 + miles / 100),
            category: .gas,
            distanceAlongRoute: miles * mile
        )
    }

    // MARK: - Planner output

    func testMealTimeTankListsItsCompetingPumpsBestFirst() {
        let stations = [gas(40), gas(60), gas(80), gas(160), gas(240)]
        // 10:30 departure, 60 mph: the 85 mi comfort edge is at 11:55 (lunch).
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 300 * mile,
            range: 100 * mile,
            departure: utcDate(hour: 10, minute: 30),
            totalTravelTime: 5 * 3_600,
            calendar: utcCalendar
        )
        let first = try? XCTUnwrap(plan.mealWindowCandidateIDs.first)
        XCTAssertEqual(first, [stations[2].id, stations[1].id, stations[0].id])
    }

    func testOffMealTanksListNothing() {
        let stations = [gas(40), gas(60), gas(80), gas(160)]
        // 14:00 departure, 60 mph, 200 mi: tanks at 15:25 and 16:45,
        // between lunch and dinner.
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 200 * mile,
            range: 100 * mile,
            departure: utcDate(hour: 14),
            totalTravelTime: 200.0 / 60 * 3_600,
            calendar: utcCalendar
        )
        XCTAssertTrue(plan.mealWindowCandidateIDs.isEmpty)
    }

    // MARK: - Search targets

    func testTargetsTakeThreePerTankSkipCheckedAndStopAtTheBudget() {
        let a = (0..<5).map { _ in UUID() }
        let b = (0..<5).map { _ in UUID() }
        let targets = RoutePlannerViewModel.mealFoodSearchTargets(
            windows: [a, [a[0]] + b],
            checked: [a[1]],
            budget: 12
        )
        // Tank 1: a0, a2 (a1 was checked). Tank 2: a0 repeats, then b0, b1.
        XCTAssertEqual(targets, [a[0], a[2], b[0], b[1]])

        let capped = RoutePlannerViewModel.mealFoodSearchTargets(
            windows: [a, b],
            checked: [],
            budget: 4
        )
        XCTAssertEqual(capped, [a[0], a[1], a[2], b[0]])
        XCTAssertTrue(RoutePlannerViewModel.mealFoodSearchTargets(windows: [a], checked: [], budget: 0).isEmpty)
    }

    // MARK: - View model, end to end

    /// Food exists only near the 70 mi pump. Without the second pass the
    /// planner keeps the 84 mi gas-only pump for the lunch tank.
    @MainActor
    func testLunchTankMovesToThePumpWithFood() async throws {
        let origin = UITestFixture.origin
        let line = (0...300).map { UITestFixture.coordinate(milesNorth: Double($0), eastMeters: 0) }
        func pump(_ miles: Double) -> SuggestedStop {
            SuggestedStop(
                name: "Pump \(Int(miles))",
                coordinate: UITestFixture.coordinate(milesNorth: miles, eastMeters: 0),
                category: .gas,
                distanceAlongRoute: miles * mile
            )
        }
        let early = pump(50)
        let withFood = pump(70)
        let gasOnly = pump(84)
        let stations = [early, withFood, gasOnly, pump(150), pump(230)]
        let search = FakeStopSearch(stations: stations, foodNear: withFood.coordinate)

        let viewModel = RoutePlannerViewModel(stopSearch: search)
        viewModel.fuelRangeMeters = 100 * mile
        // Tomorrow 10:15 local, 60 mph: the 85 mi comfort edge is at 11:40.
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        viewModel.setDeparture(Calendar.current.date(bySettingHour: 10, minute: 15, second: 0, of: tomorrow)!)
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: origin),
            Waypoint(name: "End", coordinate: line[line.count - 1]),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.legs = [StubMKRoute(
            name: "North",
            coordinates: line,
            distance: 300 * mile,
            expectedTravelTime: 5 * 3_600,
            hasHighways: true
        )]
        viewModel.gasStations = stations
        viewModel.applyFuelCandidatePool()

        let deadline = Date().addingTimeInterval(5)
        while viewModel.fuelStops.first?.id != withFood.id, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(viewModel.fuelStops.first?.id, withFood.id)
        XCTAssertLessThanOrEqual(search.foodSearches, 12 + viewModel.fuelStops.count * 4)
    }
}

/// Gas returns the fixture stations; food exists only near one coordinate.
@MainActor
private final class FakeStopSearch: StopSearching {
    let stations: [SuggestedStop]
    let foodNear: CLLocationCoordinate2D
    private(set) var foodSearches = 0

    init(stations: [SuggestedStop], foodNear: CLLocationCoordinate2D) {
        self.stations = stations
        self.foodNear = foodNear
    }

    func findStops(
        category: StopCategory,
        alongLegs legs: [MKRoute],
        sampleDistances: [CLLocationDistance]?,
        corridorRadiusMeters: CLLocationDistance?,
        generation: Int
    ) async -> CorridorSearchResult {
        CorridorSearchResult(
            stops: category == .gas ? stations : [],
            status: .completed,
            succeeded: 1,
            failed: 0,
            throttled: 0
        )
    }

    func findFood(
        near coordinate: CLLocationCoordinate2D,
        alongPolylines legPolylines: [[CLLocationCoordinate2D]]
    ) async -> [SuggestedStop] {
        foodSearches += 1
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let target = CLLocation(latitude: foodNear.latitude, longitude: foodNear.longitude)
        guard here.distance(from: target) < 100 else { return [] }
        return [SuggestedStop(
            name: "Diner",
            coordinate: CLLocationCoordinate2D(latitude: foodNear.latitude, longitude: foodNear.longitude + 0.002),
            category: .food,
            distanceAlongRoute: 0
        )]
    }
}
