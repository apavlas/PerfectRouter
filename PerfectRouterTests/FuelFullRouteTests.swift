import XCTest
import CoreLocation
import MapKit
@testable import PerfectRouter

/// FUEL-8: Select recommended plans fuel for the whole ride.
@MainActor
final class FuelFullRouteTests: XCTestCase {
    private let mile = AppSettings.metersPerMile

    private func coordinate(atMiles miles: Double, east: Double = 0) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 35.0 + miles * mile / 111_320, longitude: -80.0 + east)
    }

    private func station(_ name: String, miles: Double, east: Double = 0) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: coordinate(atMiles: miles, east: east),
            category: .gas,
            distanceAlongRoute: miles * mile,
            detourMeters: 0
        )
    }

    /// A straight northbound ride with a 100 mi tank.
    private func ride(miles total: Double, stations: [SuggestedStop], tankMiles: Double = 100) -> RoutePlannerViewModel {
        let line = stride(from: 0.0, through: total, by: 10).map { coordinate(atMiles: $0) }
            + [coordinate(atMiles: total)]
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = tankMiles * mile
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: line[0]),
            Waypoint(name: "End", coordinate: line[line.count - 1]),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.legs = [
            StubMKRoute(
                name: "Northbound",
                coordinates: line,
                distance: total * mile,
                expectedTravelTime: (total / 55) * 3_600,
                hasHighways: true
            )
        ]
        viewModel.gasStations = stations
        return viewModel
    }

    /// Hop lengths in miles between consecutive stops, start to destination.
    private func legs(_ names: [String], miles: [String: Double], total: Double) -> [Double] {
        let marks = [0] + names.dropFirst().dropLast().compactMap { miles[$0] } + [total]
        return zip(marks.dropFirst(), marks).map { $0 - $1 }
    }

    // AC1 + AC3: a dry stretch longer than the tank does not end the plan.
    func testSelectRecommendedPlansPastAGapAndKeepsGoing() async {
        let marks: [String: Double] = ["P80": 80, "P230": 230, "P310": 310, "P395": 395]
        let viewModel = ride(miles: 400, stations: marks.map { station($0.key, miles: $0.value) })

        await viewModel.toggleRecommendedFuelSelection()

        let names = viewModel.waypoints.map(\.name)
        XCTAssertEqual(names, ["Start", "P80", "P230", "P310", "P395", "End"])
        let hops = legs(names, miles: marks, total: 400)
        // Only the warned dry stretch (80 -> 230) is longer than the tank.
        XCTAssertEqual(hops.filter { $0 > 100 }, [150], "\(hops)")
    }

    func testTheDryStretchIsWarnedWithFillUpHere() {
        let stops = [station("P80", miles: 80), station("P230", miles: 230), station("P310", miles: 310)]
        let plan = RoutePlannerViewModel.fuelPlan(from: stops, totalDistance: 380 * mile, range: 100 * mile)
        XCTAssertTrue(plan.hasGap)
        let warnings = plan.entries.compactMap { entry -> String? in
            if case .gap(let gap) = entry { return gap.warning }
            return nil
        }
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("No fuel for 150 mi, fill up here."), warnings[0])
        // The plan carries on past the gap: the pump after it, then the next tank.
        let named = plan.entries.compactMap { entry -> String? in
            switch entry {
            case .recommended(let stop), .pastRange(let stop): return stop.name
            case .gap: return nil
            }
        }
        XCTAssertEqual(named, ["P80", "P230", "P310"])
    }

    // AC2: rider's side first; the other side only fills a hop the rider's
    // side leaves too long, and is labeled.
    func testAcrossTheRoadFillsOnlyWhereTheRidersSideHasNoPumpInRange() async {
        let near = RouteGeometry.drivesOnRight ? 0.002 : -0.002
        let riders80 = station("Riders 80", miles: 80, east: near)
        let across160 = station("Across 160", miles: 160, east: -near)
        let riders240 = station("Riders 240", miles: 240, east: near)
        let across60 = station("Across 60", miles: 60, east: -near)
        let viewModel = ride(miles: 300, stations: [riders80, across160, riders240, across60])

        viewModel.applyFuelCandidatePool()
        XCTAssertTrue(viewModel.isAcrossDividedHighway(across160))
        // Across 60 sits where the rider's side already has a pump in range.
        XCTAssertFalse(viewModel.isAcrossDividedHighway(across60))
        XCTAssertFalse(viewModel.isAcrossDividedHighway(riders80))
        XCTAssertEqual(GasListGrouping.acrossDividedHighwayTag, "Across the road")

        await viewModel.toggleRecommendedFuelSelection()
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Riders 80", "Across 160", "Riders 240", "End"])
    }

    // AC4: the same route and tank give the same stops whatever order the
    // searches came back in, including two pumps at the same mile.
    func testSameRouteAndTankGiveTheSameStopsInAnyArrivalOrder() async {
        let base = [
            station("Bravo", miles: 80), station("Alpha", miles: 80),
            station("Mid", miles: 150), station("Late A", miles: 165), station("Late B", miles: 165),
            station("Far", miles: 240), station("Edge", miles: 250),
        ]
        var seenPlans = Set<[String]>()
        var seenRoutes = Set<[String]>()
        var generator = SeededGenerator(seed: 7)
        for _ in 0..<6 {
            let shuffled = base.shuffled(using: &generator)
            let viewModel = ride(miles: 300, stations: shuffled)
            viewModel.applyFuelCandidatePool()
            seenPlans.insert(viewModel.fuelStops.map(\.name))
            await viewModel.toggleRecommendedFuelSelection()
            seenRoutes.insert(viewModel.waypoints.map(\.name))
        }
        XCTAssertEqual(seenPlans.count, 1, "\(seenPlans)")
        XCTAssertEqual(seenRoutes.count, 1, "\(seenRoutes)")
        let route = seenRoutes.first ?? []
        XCTAssertGreaterThanOrEqual(route.count - 2, 3, "\(route)")
        let miles = Dictionary(base.map { ($0.name, $0.distanceAlongRoute / mile) }, uniquingKeysWith: { a, _ in a })
        XCTAssertTrue(legs(route, miles: miles, total: 300).allSatisfy { $0 <= 100 }, "\(route)")
    }

    func testPoolIDsKeepEqualMilesInInputOrder() {
        let a = UUID(), b = UUID(), c = UUID()
        let ids = RoutePlannerViewModel.preferredFuelPoolIDs(
            marks: [(a, 100 * mile), (b, 100 * mile), (c, 50 * mile)],
            travelSide: [a, b],
            totalDistance: 150 * mile,
            limit: 85 * mile
        )
        // c (other side) fills the 0 -> 100 mi hop; a and b tie and keep order.
        XCTAssertEqual(ids, [c, a, b])
    }
}

/// Deterministic shuffles for the arrival-order test.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

}

extension FuelFullRouteTests {
    // Codex review on #52: planning past a dry stretch commits the pump
    // after it, and the replan from those fills must keep the warning.
    func testTheWarningSurvivesSelectingPastTheGap() {
        let stops = [80.0, 230, 310, 395].map { station("P\(Int($0))", miles: $0) }
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stops,
            totalDistance: 400 * mile,
            range: 100 * mile,
            filledAt: [80, 230, 310, 395].map { $0 * mile }
        )
        XCTAssertTrue(plan.hasGap)
        let warnings = plan.entries.compactMap { entry -> String? in
            if case .gap(let gap) = entry { return gap.warning }
            return nil
        }
        XCTAssertEqual(warnings.count, 1, "\(warnings)")
        XCTAssertTrue(warnings.first?.hasPrefix("No fuel for 150 mi, fill up here.") ?? false, "\(warnings)")
    }

    func testCommittedFillsInsideTheTankNameNoGap() {
        let stops = [80.0, 165, 247].map { station("P\(Int($0))", miles: $0) }
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stops,
            totalDistance: 259 * mile,
            range: 100 * mile,
            filledAt: [80, 165, 247].map { $0 * mile }
        )
        XCTAssertFalse(plan.hasGap)
    }

    // Ralph's copy: the leg's own length first, then the mile mark.
    func testFuelRowsShowTheHopThenMilesFromStart() {
        XCTAssertEqual(
            FuelStopRidingTime.legDistanceText(fromMeters: 80 * mile, toMeters: 166 * mile, usesMetric: false),
            "86 mi (166 mi from start)"
        )
        XCTAssertEqual(
            FuelStopRidingTime.legDistanceText(fromMeters: 0, toMeters: 80 * mile, usesMetric: false),
            "80 mi"
        )
        let rideLegs = [FuelStopRidingTime.Leg(distanceMeters: 260 * mile, expectedTravelTime: 4 * 3_600)]
        let second = FuelStopRidingTime.fuelRowCaption(
            distanceMeters: 166 * mile,
            anchors: [80 * mile, 166 * mile],
            legs: rideLegs,
            usesMetric: false
        )
        XCTAssertTrue(second.hasPrefix("86 mi (166 mi from start) · "), second)
        XCTAssertTrue(second.hasSuffix("since last)"), second)
        XCTAssertFalse(second.contains("~"))
        let first = FuelStopRidingTime.fuelRowCaption(
            distanceMeters: 80 * mile,
            anchors: [80 * mile, 166 * mile],
            legs: rideLegs,
            usesMetric: false
        )
        XCTAssertTrue(first.hasPrefix("80 mi · "), first)
        XCTAssertFalse(first.contains("from start"), first)
    }

    // iPad race: mid-replan the list has the new stop but the old legs, so
    // the destination read as mile 0 and "Day 1" came back after "Day 2".
    // Two rows with one id made SwiftUI drop a stop and repeat the tail.
    func testStaleMilesNeverRepeatARouteListRow() {
        func day(_ number: Int, _ start: Double, _ end: Double, unpicked: Int?) -> HotelAlongRoute.RideDay {
            HotelAlongRoute.RideDay(
                dayNumber: number,
                startDistance: start * mile,
                endDistance: end * mile,
                ridingSeconds: 3_600,
                unpickedEvening: unpicked,
                exceedsDailyLimit: false
            )
        }
        let days = [day(1, 0, 90, unpicked: 0), day(2, 90, 200, unpicked: 1), day(3, 200, 300, unpicked: nil)]
        let ids = (0..<6).map { _ in UUID() }
        // Origin, Pilot, On Route, the new Overlook (old leg prefix), Shell, destination read as 0.
        let stale = [0, 80, 150, 230, 300, 0].map { $0 * mile }
        let entries = RoutePlannerViewModel.routeListEntries(waypointIDs: ids, distances: stale, days: days)
        XCTAssertEqual(Set(entries.map(\.id)).count, entries.count, "\(entries.map(\.id))")
        XCTAssertEqual(entries.compactMap(\.waypointIndex), Array(0..<6))
        let markers = entries.compactMap { $0.dayMarker?.dayNumber }
        XCTAssertEqual(markers, markers.sorted())

        // Fresh miles keep the usual split.
        let fresh = [0, 80, 150, 180, 230, 300].map { $0 * mile }
        let settled = RoutePlannerViewModel.routeListEntries(waypointIDs: ids, distances: fresh, days: days)
        XCTAssertEqual(Set(settled.map(\.id)).count, settled.count)
        XCTAssertEqual(settled.compactMap { $0.dayMarker?.dayNumber }, [1, 2, 3])
        XCTAssertEqual(settled.compactMap(\.waypointIndex), Array(0..<6))
    }
}
