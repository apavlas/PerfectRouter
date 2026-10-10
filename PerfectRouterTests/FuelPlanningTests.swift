import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for the pure fuel-stop planner. These exercise the greedy
/// selection logic (comfort window, hard-range fallback, and fuel gaps)
/// without any networking.
final class FuelPlanningTests: XCTestCase {

    /// UTC calendar so meal-window tests don't depend on the host timezone.
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func utcDate(hour: Int, minute: Int = 0) -> Date {
        utcCalendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: hour, minute: minute))!
    }

    /// 10:00 departure + 3 h over 150 km puts the 85 km comfort edge at 11:42 (lunch).
    private func lunchPlan(
        from stations: [SuggestedStop],
        preferringFoodAt: Set<UUID>
    ) -> (stops: [SuggestedStop], hasGap: Bool) {
        RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 150_000,
            range: 100_000,
            preferringFoodAt: preferringFoodAt,
            departure: utcDate(hour: 10),
            totalTravelTime: 3 * 60 * 60,
            calendar: utcCalendar
        )
    }

    /// Builds a gas stop at a given distance along the route.
    private func gas(at meters: CLLocationDistance) -> SuggestedStop {
        SuggestedStop(
            name: "Gas @\(Int(meters))",
            coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            category: .gas,
            distanceAlongRoute: meters
        )
    }

    func testShortRideNeedsNoFuelStops() {
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 50_000)],
            totalDistance: 100_000,
            range: 160_900
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertFalse(hasGap)
    }

    func testLongRidePicksFarthestWithinComfortWindow() {
        // Stations every 20 km; range 100 km, comfort window = 85 km.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000
        )
        XCTAssertFalse(hasGap)
        // From 0: farthest <= 85 km is 80 km. From 80: farthest <= 165 km is 160 km.
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])
    }

    func testFallsBackToHardRangeWhenComfortWindowEmpty() {
        // Only station sits beyond the comfort window (85 km) but within range (100 km).
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 95_000)],
            totalDistance: 150_000,
            range: 100_000
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [95_000])
    }

    func testFlagsFuelGapWhenNoReachableStation() {
        // Stations only near the start; a long dry stretch follows.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 20_000), gas(at: 40_000)],
            totalDistance: 300_000,
            range: 100_000
        )
        XCTAssertTrue(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [40_000])
    }

    func testDoesNotSkipAheadToAStationPastTheGap() {
        // A pump past the dry stretch is not a fuel stop. The gap warning
        // covers that segment; the in-range stop stays.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 40_000), gas(at: 220_000)],
            totalDistance: 400_000,
            range: 100_000
        )
        XCTAssertTrue(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [40_000])
    }

    func testOpeningStationBeyondRangeIsAGapNotAStop() {
        // Nothing in the first tank. Do not recommend the far pump.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 200_000)],
            totalDistance: 400_000,
            range: 100_000
        )
        XCTAssertTrue(hasGap)
        XCTAssertTrue(stops.isEmpty)
    }

    func testLateChipStationsBeyondRangeAreAGap() {
        // Augusta → Nashville (~395 mi, 100 mi tank). Pumps only at ~271 and
        // ~375 mi are both outside the tank from the start, and 104 mi apart,
        // so neither is a fuel stop. The gap warning is the result.
        let mile = AppSettings.metersPerMile
        let first = gas(at: 271 * mile)
        let second = gas(at: 375 * mile)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [first, second],
            totalDistance: 395 * mile,
            range: 100 * mile
        )
        XCTAssertTrue(hasGap)
        XCTAssertTrue(stops.isEmpty)
        XCTAssertFalse(stops.contains { $0.id == first.id || $0.id == second.id })
    }

    /// Device bug: tank set to 100 miles, first suggested stop at mile 801.
    /// Every recommended hop, including start → first stop, stays inside the tank.
    func testHundredMileRangeKeepsConsecutiveStopsWithinTank() {
        let mile = AppSettings.metersPerMile
        let range = 100 * mile
        var stations = stride(from: 40.0, through: 400.0, by: 40.0).map { gas(at: $0 * mile) }
        stations.append(gas(at: 801 * mile))
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 1_000 * mile,
            range: range
        )
        XCTAssertFalse(stops.isEmpty)
        var previous: CLLocationDistance = 0
        for stop in stops {
            XCTAssertLessThanOrEqual(
                stop.distanceAlongRoute - previous,
                range + 1,
                "hop of \(stop.distanceAlongRoute - previous) m exceeds the 100-mile tank"
            )
            previous = stop.distanceAlongRoute
        }
        XCTAssertLessThanOrEqual(stops[0].distanceAlongRoute, 85 * mile + 1)
        XCTAssertFalse(stops.contains { abs($0.distanceAlongRoute - 801 * mile) < mile })
        XCTAssertTrue(hasGap)
    }

    func testMile801StationOnAHundredMileTankIsNotRecommended() {
        let mile = AppSettings.metersPerMile
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 801 * mile)],
            totalDistance: 1_200 * mile,
            range: 100 * mile
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertTrue(hasGap)
    }

    func testMergedGasCandidatesDedupesAndKeepsLateStops() {
        let early = gas(at: 50_000)
        let late = gas(at: 400_000)
        let duplicate = SuggestedStop(
            name: early.name,
            coordinate: early.coordinate,
            category: .gas,
            distanceAlongRoute: early.distanceAlongRoute
        )
        let merged = RoutePlannerViewModel.mergedGasCandidates([[early], [duplicate, late]])
        XCTAssertEqual(merged.map(\.name), [early.name, late.name])
    }

    func testPreferredFuelPoolFallsBackWhenTravelSideEmpty() {
        let station = gas(at: 400_000)
        let pool = RoutePlannerViewModel.preferredFuelPool(from: [station], travelSide: [])
        XCTAssertEqual(pool.map(\.id), [station.id])
    }

    func testPreferredFuelPoolKeepsTravelSideWhenPresent() {
        let onSide = gas(at: 80_000)
        let offSide = gas(at: 90_000)
        let pool = RoutePlannerViewModel.preferredFuelPool(from: [onSide, offSide], travelSide: [onSide])
        XCTAssertEqual(pool.map(\.id), [onSide.id])
    }

    func testNoStationsAtAllFlagsGap() {
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [],
            totalDistance: 300_000,
            range: 100_000
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertTrue(hasGap)
    }

    func testRiderAddedGasFillPlansLaterPumpsFromThatPoint() {
        // Same stations as the long-ride case. A fill at the first auto pick
        // (80 km) drops that recommendation; the next tank is planned from 80.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: [80_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [160_000])
    }

    func testMidPlanFillDropsEarlierAutoRecommendations() {
        // Unfilled: 80 then 160. A fill at 50 km replans from there — 80 is
        // no longer the pick; farthest in the 50+85 km comfort window is 120.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (withoutFill, _) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000
        )
        XCTAssertEqual(withoutFill.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])

        let (withFill, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: [50_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(withFill.map { Int($0.distanceAlongRoute) }, [120_000, 200_000])
        XCTAssertFalse(withFill.contains { Int($0.distanceAlongRoute) == 80_000 })
    }

    func testGapWarningUsesRemainingStretchAfterFill() {
        // Stations only near the start. A fill at 200 km leaves 100 km — one
        // tank — so the dry stretch behind the fill is not a gap.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 20_000), gas(at: 40_000)],
            totalDistance: 300_000,
            range: 100_000,
            filledAt: [200_000]
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertFalse(hasGap)
    }

    func testGapAfterFillWhenRemainingStretchIsDry() {
        // Fill at 40 km; nothing reachable in the remaining 260 km.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 20_000), gas(at: 40_000)],
            totalDistance: 300_000,
            range: 100_000,
            filledAt: [40_000]
        )
        XCTAssertTrue(stops.isEmpty)
        XCTAssertTrue(hasGap)
    }

    func testNonGasFillDistancesAreIgnoredByCaller() {
        // Planner only sees distances in `filledAt`. An empty list (food /
        // scenic waypoints) keeps the start-of-ride tank, same as before.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: []
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])
    }

    func testComfortWindowUnchangedWithFill() {
        XCTAssertEqual(RoutePlannerViewModel.fuelSafetyFactor, 0.85, accuracy: 0.0001)
        // Only station sits beyond comfort (50+85=135) but within hard range
        // (50+100=150). Same 85% window, just measured from the fill.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [gas(at: 140_000)],
            totalDistance: 200_000,
            range: 100_000,
            filledAt: [50_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [140_000])
    }

    // MARK: - Food at the stop

    func testPrefersGasWithFoodAtMealTime() {
        // Comfort-edge ETA is lunch. Both sit in the 85 km window; food wins.
        let withFood = gas(at: 60_000)
        let gasOnly = gas(at: 80_000)
        let (stops, hasGap) = lunchPlan(from: [withFood, gasOnly], preferringFoodAt: [withFood.id])
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [withFood.id])
    }

    func testPicksFarthestFoodStopInsideTheTankWindowAtMealTime() {
        let earlyFood = gas(at: 40_000)
        let laterFood = gas(at: 80_000)
        let gasOnly = gas(at: 84_000)
        let (stops, hasGap) = lunchPlan(
            from: [earlyFood, laterFood, gasOnly],
            preferringFoodAt: [earlyFood.id, laterFood.id]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [laterFood.id])
    }

    func testOffMealKeepsFarthestGasEvenWhenFoodExists() {
        // 13:00 + 1.7 h = 14:42 — between lunch and dinner. Tank interval wins.
        let withFood = gas(at: 60_000)
        let gasOnly = gas(at: 80_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [withFood, gasOnly],
            totalDistance: 150_000,
            range: 100_000,
            preferringFoodAt: [withFood.id],
            departure: utcDate(hour: 13),
            totalTravelTime: 3 * 60 * 60,
            calendar: utcCalendar
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [gasOnly.id])
    }

    func testFallsBackToGasOnlyWhenNoFoodInWindow() {
        let only = gas(at: 80_000)
        let (stops, hasGap) = lunchPlan(from: [only], preferringFoodAt: [UUID()])
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000])
    }

    func testHardRangeFallbackPrefersFoodAtMealTime() {
        // Comfort window (85 km) is empty. Lunch ETA still prefers food at 95 km.
        let withFood = gas(at: 95_000)
        let gasOnly = gas(at: 99_000)
        let (stops, hasGap) = lunchPlan(from: [withFood, gasOnly], preferringFoodAt: [withFood.id])
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [withFood.id])
    }

    func testMealTimeWindows() {
        XCTAssertTrue(RoutePlannerViewModel.isMealTime(utcDate(hour: 7, minute: 30), calendar: utcCalendar))
        XCTAssertTrue(RoutePlannerViewModel.isMealTime(utcDate(hour: 12), calendar: utcCalendar))
        XCTAssertTrue(RoutePlannerViewModel.isMealTime(utcDate(hour: 18, minute: 15), calendar: utcCalendar))
        XCTAssertFalse(RoutePlannerViewModel.isMealTime(utcDate(hour: 10, minute: 15), calendar: utcCalendar))
        XCTAssertFalse(RoutePlannerViewModel.isMealTime(utcDate(hour: 15), calendar: utcCalendar))
        XCTAssertFalse(RoutePlannerViewModel.isMealTime(utcDate(hour: 21), calendar: utcCalendar))
    }

    func testEtaAlongRouteInterpolatesByDistance() {
        let departure = utcDate(hour: 10)
        let eta = RoutePlannerViewModel.etaAlongRoute(
            distance: 75_000,
            totalDistance: 150_000,
            departure: departure,
            totalTravelTime: 3 * 60 * 60
        )
        XCTAssertEqual(eta.timeIntervalSince(departure), 1.5 * 60 * 60, accuracy: 1)
    }

    func testEmptyPreferringFoodKeepsFarthestInWindow() {
        // Default / no food data: same pick as the original long-ride case.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            preferringFoodAt: []
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000])
    }

    func testMissingFoodDoesNotSkipLaterTanks() {
        // Food on tank 1 only. Tank 2 is gas-only and must still be picked.
        let foodStop = gas(at: 80_000)
        let gasOnly = gas(at: 160_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [foodStop, gasOnly],
            totalDistance: 250_000,
            range: 100_000,
            preferringFoodAt: [foodStop.id]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map(\.id), [foodStop.id, gasOnly.id])
    }

    // MARK: - Tank-interval search grid

    func testFuelSearchDistancesAnchorToTankInterval() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 250_000,
            range: 100_000
        )
        let interval = 100_000 * RoutePlannerViewModel.fuelSafetyFactor
        XCTAssertTrue(distances.contains { abs($0 - interval) < 1 }, "missing comfort-edge \(interval)")
        XCTAssertTrue(distances.contains { abs($0 - interval * 2) < 1 }, "missing second tank \(interval * 2)")
        XCTAssertTrue(distances.allSatisfy { $0 < 250_000 })
    }

    func testFuelSearchDistancesAreNotATwentyFiveMileGrid() {
        let tankMeters = 100 * AppSettings.metersPerMile
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 400 * AppSettings.metersPerMile,
            range: tankMeters
        )
        let twentyFiveMiles = 25 * AppSettings.metersPerMile
        // First tank-interval point is ~85 mi, not 25.
        XCTAssertGreaterThan(distances.min() ?? 0, twentyFiveMiles)
        XCTAssertTrue(distances.contains { abs($0 - tankMeters * RoutePlannerViewModel.fuelSafetyFactor) < 1 })
    }

    func testFuelSearchDistancesCapAtMax() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 5_000_000,
            range: 100_000,
            maxCount: 16
        )
        XCTAssertEqual(distances.count, 16)
        XCTAssertEqual(distances, distances.sorted())
    }

    func testFuelSearchDistancesKeepEveryTankBeforeAddingExtras() {
        let total: CLLocationDistance = 900_000
        let range: CLLocationDistance = 100_000
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: total,
            range: range,
            maxCount: 12
        )
        let interval = range * RoutePlannerViewModel.fuelSafetyFactor
        var k = 1
        while interval * Double(k) < total {
            let edge = interval * Double(k)
            XCTAssertTrue(
                distances.contains { abs($0 - edge) < 1 },
                "missing tank-interval edge \(edge)"
            )
            k += 1
        }
        XCTAssertLessThanOrEqual(distances.count, 12)
    }

    func testFuelSearchDistancesCapKeepsFirstAndLastTank() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 5_000_000,
            range: 100_000,
            maxCount: 8
        )
        let interval = 100_000 * RoutePlannerViewModel.fuelSafetyFactor
        let lastEdge = interval * floor((5_000_000 - 1) / interval)
        XCTAssertEqual(distances.count, 8)
        XCTAssertEqual(distances.first ?? 0, interval, accuracy: 1)
        XCTAssertEqual(distances.last ?? 0, lastEdge, accuracy: 1)
    }

    func testShortRideStillGetsASearchPoint() {
        let distances = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: 50_000,
            range: 100_000
        )
        XCTAssertEqual(distances.count, 1)
        XCTAssertEqual(distances[0], 25_000, accuracy: 1)
    }

    func testGasStopsWithNearbyFoodMarksInRadius() {
        let pump = SuggestedStop(
            name: "Pump",
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0),
            category: .gas,
            distanceAlongRoute: 80_000
        )
        // ~0.001° latitude ≈ 111 m — inside the 1.5 km food radius.
        let diner = SuggestedStop(
            name: "Diner",
            coordinate: CLLocationCoordinate2D(latitude: 40.001, longitude: -75.0),
            category: .food,
            distanceAlongRoute: 80_000
        )
        let ids = RoutePlannerViewModel.gasStopsWithNearbyFood([pump], food: [diner])
        XCTAssertEqual(ids, [pump.id])
    }

    func testNearDuplicateHopIsSkippedAndGapNamesTheStretch() {
        // Anton's 170-mile ride: Shell at 2,328 is only 29 miles after the
        // stop at 2,299, and the next station is 274 miles later. The short
        // hop is not a fuel stop. The warning sits between those two stations.
        let mile = AppSettings.metersPerMile
        var marks = stride(from: 140.0, through: 2_100.0, by: 140.0).map { $0 }
        marks.append(contentsOf: [2_159, 2_299, 2_328, 2_602])
        let stations = marks.map { gas(at: $0 * mile) }
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 2_700 * mile,
            range: 170 * mile
        )

        XCTAssertFalse(plan.stops.contains { abs($0.distanceAlongRoute - 2_328 * mile) < 1 })
        XCTAssertFalse(plan.stops.contains { abs($0.distanceAlongRoute - 2_602 * mile) < 1 })
        XCTAssertEqual(plan.stops.last.map { Int(($0.distanceAlongRoute / mile).rounded()) }, 2_299)
        var previous: CLLocationDistance = 0
        for stop in plan.stops {
            XCTAssertLessThanOrEqual(stop.distanceAlongRoute - previous, 170 * mile + 1)
            previous = stop.distanceAlongRoute
        }

        let gaps = plan.entries.compactMap { entry -> FuelGap? in
            if case .gap(let gap) = entry { return gap }
            return nil
        }
        XCTAssertEqual(gaps.count, 1)
        let gap = gaps[0]
        XCTAssertEqual(Int((gap.fromMeters / mile).rounded()), 2_328)
        XCTAssertEqual(Int((gap.toMeters / mile).rounded()), 2_602)
        XCTAssertEqual(
            FuelGap.warning(
                fromMeters: gap.fromMeters,
                toMeters: gap.toMeters,
                rangeMeters: gap.rangeMeters,
                usesMetric: false
            ),
            "No gas between mile 2,328 and 2,602 (274 mi, beyond your 170 mi range)"
        )
        guard case .pastRange(let far) = plan.entries.last else {
            return XCTFail("the station after the gap should be listed past range")
        }
        XCTAssertEqual(Int((far.distanceAlongRoute / mile).rounded()), 2_602)
        XCTAssertTrue(plan.hasGap)
    }

    func testShortHopIsKeptWhenTheDestinationIsJustPastTheTank() {
        // 10 km is a short hop, and it is the only way to reach a destination
        // 105 km out. Skipping it would leave the last 5 km uncovered.
        let plan = RoutePlannerViewModel.fuelPlan(
            from: [gas(at: 10_000)],
            totalDistance: 105_000,
            range: 100_000
        )
        XCTAssertFalse(plan.hasGap)
        XCTAssertEqual(plan.stops.map { Int($0.distanceAlongRoute) }, [10_000])
    }

    func testShortHopIsKeptWhenItReachesAFartherStation() {
        // 10 km is inside the 20 km separation, but stopping there reaches
        // the station at 105 km, which the tank cannot reach from the start.
        let plan = RoutePlannerViewModel.fuelPlan(
            from: [gas(at: 10_000), gas(at: 105_000)],
            totalDistance: 180_000,
            range: 100_000
        )
        XCTAssertFalse(plan.hasGap)
        XCTAssertEqual(plan.stops.map { Int($0.distanceAlongRoute) }, [10_000, 105_000])
    }

    func testPlanningResumesAfterAPastRangeStation() {
        let plan = RoutePlannerViewModel.fuelPlan(
            from: [gas(at: 200_000), gas(at: 280_000), gas(at: 360_000)],
            totalDistance: 400_000,
            range: 100_000
        )
        XCTAssertTrue(plan.hasGap)
        XCTAssertEqual(plan.stops.map { Int($0.distanceAlongRoute) }, [280_000, 360_000])
        XCTAssertEqual(plan.entries.count, 4)
        guard case .gap(let gap) = plan.entries[0] else {
            return XCTFail("expected a gap before the out-of-range station")
        }
        XCTAssertEqual(Int(gap.fromMeters), 0)
        XCTAssertEqual(Int(gap.toMeters), 200_000)
        guard case .pastRange(let missed) = plan.entries[1] else {
            return XCTFail("expected the out-of-range station")
        }
        XCTAssertEqual(Int(missed.distanceAlongRoute), 200_000)
    }

    func testLongRoutePlansMoreThanTwentyInRangeStops() {
        let mile = AppSettings.metersPerMile
        let range = 100 * mile
        let stations = stride(from: 80.0, through: 2_000.0, by: 80.0).map { gas(at: $0 * mile) }
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 2_040 * mile,
            range: range
        )
        XCTAssertGreaterThan(plan.stops.count, 20)
        XCTAssertFalse(plan.hasGap)
        XCTAssertTrue(plan.entries.allSatisfy { entry in
            if case .recommended = entry { return true }
            return false
        })
        var previous: CLLocationDistance = 0
        for stop in plan.stops {
            XCTAssertLessThanOrEqual(stop.distanceAlongRoute - previous, range + 1)
            previous = stop.distanceAlongRoute
        }
    }

    func testGasStopsWithNearbyFoodIgnoresFarFood() {
        let pump = SuggestedStop(
            name: "Pump",
            coordinate: CLLocationCoordinate2D(latitude: 40.0, longitude: -75.0),
            category: .gas,
            distanceAlongRoute: 80_000
        )
        // ~0.05° latitude ≈ 5.5 km — outside the 1.5 km food radius.
        let diner = SuggestedStop(
            name: "Far Diner",
            coordinate: CLLocationCoordinate2D(latitude: 40.05, longitude: -75.0),
            category: .food,
            distanceAlongRoute: 80_000
        )
        let ids = RoutePlannerViewModel.gasStopsWithNearbyFood([pump], food: [diner])
        XCTAssertTrue(ids.isEmpty)
    }
}
