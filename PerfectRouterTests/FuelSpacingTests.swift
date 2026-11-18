import XCTest
import CoreLocation
import MapKit
@testable import PerfectRouter

/// FUEL-9: minimum spacing between fuel stops and the same stops for the
/// same ride on every device and run. Fixed station fixtures, no MapKit.
@MainActor
final class FuelSpacingTests: XCTestCase {
    private let mile = AppSettings.metersPerMile

    private func coordinate(atMiles miles: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 35.0 + miles * mile / 111_320, longitude: -98.0)
    }

    private func station(_ name: String, _ miles: Double, detourMeters: Double = 0) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: coordinate(atMiles: miles),
            category: .gas,
            distanceAlongRoute: miles * mile,
            detourMeters: detourMeters
        )
    }

    /// Same place, new search: fresh id, same name and coordinate, mile
    /// moved by `jitterMeters`.
    private func copy(_ stop: SuggestedStop, jitterMeters: Double) -> SuggestedStop {
        SuggestedStop(
            name: stop.name,
            coordinate: stop.coordinate,
            category: .gas,
            distanceAlongRoute: stop.distanceAlongRoute + jitterMeters,
            detourMeters: stop.detourMeters
        )
    }

    private func plan(
        _ stations: [SuggestedStop],
        totalMiles: Double,
        tankMiles: Double = 100,
        food: Set<UUID> = [],
        departure: Date? = nil,
        travelTime: TimeInterval = 0,
        calendar: Calendar = .current
    ) -> [SuggestedStop] {
        RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: totalMiles * mile,
            range: tankMiles * mile,
            preferringFoodAt: food,
            departure: departure,
            totalTravelTime: travelTime,
            calendar: calendar
        ).stops
    }

    private func hops(_ stops: [SuggestedStop], totalMiles: Double) -> [Double] {
        let marks = [0] + stops.map { $0.distanceAlongRoute / mile } + [totalMiles]
        return zip(marks.dropFirst(), marks).map { (($0 - $1) * 10).rounded() / 10 }
    }

    /// Build 14 iPhone pool, OKC -> Amarillo (258.1 mi), 100 mi tank. From
    /// Love's at 79.0 the reserve window held only Phillips 66 at 85.7, and a
    /// pump at 183 sat in the 179-185.7 sliver past Love's tank, so the old
    /// short-hop exception kept the 6.7 mi hop: 79.0 / 6.7 / 79.2 / 84.9 / 8.3.
    private var okcToAmarilloIPhonePool: [SuggestedStop] {
        [
            station("Love's Travel Stop", 79.0),
            station("Phillips 66", 85.7),
            station("Chevron", 164.9),
            station("Shamrock Fuel", 183.0),
            station("National Truck Stop Amarillo", 249.8),
        ]
    }

    func testOKCPatternNoLongerCommitsTheSixMileHop() {
        let stops = plan(okcToAmarilloIPhonePool, totalMiles: 258.1)
        XCTAssertEqual(stops.map(\.name), ["Love's Travel Stop", "Chevron", "National Truck Stop Amarillo"])
        XCTAssertEqual(hops(stops, totalMiles: 258.1), [79.0, 85.9, 84.9, 8.3])
    }

    func testOKCPatternWithFoodAtTheShortHopStillSkipsIt() {
        // Lunch at the reserve edge and food only at the 6.7 mi Phillips 66:
        // a meal preference never pulls a stop inside the spacing.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let departure = utc.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 9, minute: 30))!
        let pool = okcToAmarilloIPhonePool
        let phillips = pool[1]
        let stops = plan(
            pool,
            totalMiles: 258.1,
            food: [phillips.id],
            departure: departure,
            travelTime: 4 * 3_600,
            calendar: utc
        )
        XCTAssertFalse(stops.contains { $0.id == phillips.id })
        XCTAssertTrue(hops(stops, totalMiles: 258.1).dropLast().allSatisfy { $0 >= 25 })
    }

    func testNoCommittedStopWithinAQuarterTankOnADenseCorridor() {
        // A pump every 3 mi for 400 mi, three brands per exit.
        var pool: [SuggestedStop] = []
        for exit in stride(from: 3.0, through: 397.0, by: 3.0) {
            pool.append(station("Shell \(Int(exit))", exit))
            pool.append(station("Love's \(Int(exit))", exit + 0.2))
            pool.append(station("Casey's \(Int(exit))", exit + 0.4))
        }
        for tank in [100.0, 140.0, 200.0] {
            let stops = plan(pool, totalMiles: 400, tankMiles: tank)
            let legs = hops(stops, totalMiles: 400)
            XCTAssertFalse(stops.isEmpty)
            for leg in legs.dropLast() {
                XCTAssertGreaterThanOrEqual(leg, tank * 0.25, "tank \(tank): \(legs)")
                XCTAssertLessThanOrEqual(leg, tank, "tank \(tank): \(legs)")
            }
        }
    }

    func testShortHopIsKeptWhenItIsTheOnlyWayPastAGap() {
        // From 80 nothing at or past 105 sits inside the tank (180). The
        // pump at 90 is the only way to reach 185, so the 10 mi hop is forced.
        let pool = [station("A", 80), station("B", 90), station("C", 185)]
        let stops = plan(pool, totalMiles: 260)
        XCTAssertEqual(stops.map(\.name), ["A", "B", "C"])
        XCTAssertEqual(hops(stops, totalMiles: 260), [80, 10, 95, 75])
    }

    func testShortHopIsNotForcedWhenAFartherStopIsInTheTank() {
        // Same as above plus a pump at 170: the 10 mi hop is no longer the
        // only option, so it is not committed.
        let pool = [station("A", 80), station("B", 90), station("D", 170), station("C", 185)]
        let stops = plan(pool, totalMiles: 260)
        XCTAssertEqual(stops.map(\.name), ["A", "D"])
    }

    func testSameStopsForAnyOrderDuplicatesAndSearchNoise() {
        // Both build 14 pools plus near-ties, as two devices might return them.
        let base = okcToAmarilloIPhonePool + [
            station("Phillips 66 Elk City", 165.7),
            station("Chisum Travel Plaza", 247.6),
            station("Pilot", 120.3),
            station("Valero", 120.5),
            station("Shell", 30.0),
            station("Casey's", 26.0),
        ]
        let expected = plan(base, totalMiles: 258.1).map(\.name)
        XCTAssertFalse(expected.isEmpty)
        var rng = SeededGenerator(seed: 9)
        for run in 0..<300 {
            var pool: [SuggestedStop] = []
            for stop in base {
                pool.append(copy(stop, jitterMeters: Double.random(in: -80...80, using: &rng)))
                if Bool.random(using: &rng) {
                    pool.append(copy(stop, jitterMeters: Double.random(in: -80...80, using: &rng)))
                }
            }
            pool.shuffle(using: &rng)
            XCTAssertEqual(plan(pool, totalMiles: 258.1).map(\.name), expected, "run \(run)")
        }
    }

    func testNearTieAtTheReserveEdgeIsBrokenByName() {
        // Two pumps 0.3 mi apart near the reserve edge. Which one projects
        // farther flips with search noise; the pick must not.
        let a = station("Alpha Fuel", 84.6)
        let b = station("Bravo Fuel", 84.9)
        let first = plan([a, b], totalMiles: 150).map(\.name)
        let swapped = plan([copy(b, jitterMeters: -600), copy(a, jitterMeters: 0)], totalMiles: 150).map(\.name)
        XCTAssertEqual(first, ["Alpha Fuel"])
        XCTAssertEqual(swapped, first)
    }

    // Select recommended end to end: the scan off the main actor uses the
    // same rules, so the inserted waypoints have no short hop.
    func testSelectRecommendedInsertsSpacedStopsForTheOKCPattern() async {
        let total = 258.1
        let line = stride(from: 0.0, through: total, by: 10).map { coordinate(atMiles: $0) }
            + [coordinate(atMiles: total)]
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 100 * mile
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: line[0]),
            Waypoint(name: "End", coordinate: line[line.count - 1]),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.legs = [
            StubMKRoute(
                name: "Westbound",
                coordinates: line,
                distance: total * mile,
                expectedTravelTime: (total / 60) * 3_600,
                hasHighways: true
            )
        ]
        viewModel.gasStations = okcToAmarilloIPhonePool.shuffled()

        await viewModel.toggleRecommendedFuelSelection()

        XCTAssertEqual(
            viewModel.waypoints.map(\.name),
            ["Start", "Love's Travel Stop", "Chevron", "National Truck Stop Amarillo", "End"]
        )
    }
}

/// SplitMix64, so the shuffle test is the same on every run.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
