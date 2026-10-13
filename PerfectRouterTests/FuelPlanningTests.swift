import XCTest
import CoreLocation
@testable import PerfectRouter

/// Unit tests for the pure fuel-stop planner. These exercise the greedy
/// selection logic (comfort window and fuel gaps) without any networking.
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
        // From 0: farthest <= 85 km is 80 km. From 80: farthest <= 165 km is
        // 160 km. 90 km is still past the reserve, so the 240 km station is
        // the last stop and the destination stays inside that reserve.
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000, 240_000])
    }

    func testStationBeyondTheReserveIsTheFallbackInsideTheTank() {
        // 95 km is inside the 100 km tank and outside the 85 km reserve.
        // Nothing sits inside the reserve, so the farthest in-tank station
        // is the stop. A station past the tank still is not.
        let inTank = gas(at: 95_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [inTank],
            totalDistance: 150_000,
            range: 100_000
        )
        XCTAssertEqual(stops.map(\.id), [inTank.id])
        XCTAssertFalse(hasGap)

        let beyond = gas(at: 140_000)
        let (skipped, gap) = RoutePlannerViewModel.planFuelStops(
            from: [beyond],
            totalDistance: 300_000,
            range: 100_000
        )
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertTrue(gap)
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
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [160_000, 240_000])
    }

    func testMidPlanFillDropsEarlierAutoRecommendations() {
        // Unfilled: 80, 160, then 240 so the last leg stays inside the reserve.
        // A fill at 50 km replans from there — 80 is no longer the pick;
        // farthest in the 50+85 km comfort window is 120.
        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { gas(at: $0) }
        let (withoutFill, _) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000
        )
        XCTAssertEqual(withoutFill.map { Int($0.distanceAlongRoute) }, [80_000, 160_000, 240_000])

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
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000, 240_000])
    }

    func testEmptyReserveFallsBackToTheFarthestStationInsideTheTank() {
        XCTAssertEqual(RoutePlannerViewModel.fuelSafetyFactor, 0.85, accuracy: 0.0001)
        // 90 km from the fill is past the 85 km reserve and inside the tank.
        // The reserve window is empty, so that station is the stop.
        let station = gas(at: 140_000)
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: [station],
            totalDistance: 200_000,
            range: 100_000,
            filledAt: [50_000]
        )
        XCTAssertEqual(stops.map(\.id), [station.id])
        XCTAssertFalse(hasGap)
    }

    // MARK: - Food at the stop

    func testPrefersGasWithFoodAtMealTime() {
        // Comfort-edge ETA is lunch. Both sit in the 85 km window; food wins.
        let withFood = gas(at: 60_000)
        let gasOnly = gas(at: 80_000)
        let (stops, hasGap) = lunchPlan(from: [withFood, gasOnly], preferringFoodAt: [withFood.id])
        XCTAssertFalse(hasGap)
        // Food wins the first window. The pump at 80 km keeps the last leg
        // inside the reserve.
        XCTAssertEqual(stops.map(\.id), [withFood.id, gasOnly.id])
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

    func testFoodStopBeyondTheReserveFallsBackToTheFarthestInTheTank() {
        // Both pumps sit past the 85 km reserve and inside the tank. Meal
        // time does not pull the stop back; the fallback is the farthest.
        let withFood = gas(at: 95_000)
        let gasOnly = gas(at: 99_000)
        let (stops, hasGap) = lunchPlan(from: [withFood, gasOnly], preferringFoodAt: [withFood.id])
        XCTAssertEqual(stops.map(\.id), [gasOnly.id])
        XCTAssertFalse(hasGap)
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
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [80_000, 160_000, 240_000])
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

    /// Charlotte → LA, 2,471 mi, 200 mi tank. The first pass is one lookup
    /// per 170-mile reserve so it stays inside MapKit's rate window. Pride
    /// Travel Center (mile 2,046) to Mobil (mile 2,229) is 183 miles, so
    /// the densify pass has to cover every mile of that stretch.
    func testCoastToCoastFuelSearchCoversArizonaI10() {
        let mile = AppSettings.metersPerMile
        let total = 2_471.0 * mile
        let range = 200 * mile
        let coarse = RoutePlannerViewModel.fuelSearchDistances(
            totalDistance: total,
            range: range
        )
        let radius = RoutePlannerViewModel.fuelSearchCorridorMeters
        let interval = range * RoutePlannerViewModel.fuelSafetyFactor

        XCTAssertFalse(coarse.isEmpty)
        XCTAssertEqual(coarse, coarse.sorted())
        XCTAssertLessThanOrEqual(coarse.count, MapSearchPace.maxRequestsPerWindow)
        var edge = interval
        while edge < total {
            XCTAssertTrue(
                coarse.contains { abs($0 - edge) < 1 },
                "missing comfort edge at \(edge / mile) mi"
            )
            edge += interval
        }
        XCTAssertFalse(
            coarse.contains { abs($0 - 2_100 * mile) <= radius },
            "the coarse pass should leave the middle of Arizona for densify"
        )

        // A station near every comfort edge, except Eloy and Quartzsite,
        // which sit 183 miles apart.
        var stations = coarse.filter { sample in
            abs(sample - 2_040 * mile) > mile && abs(sample - 2_210 * mile) > mile
        }
        stations.append(contentsOf: [2_046 * mile, 2_229 * mile])
        let dense = RoutePlannerViewModel.fuelDensifySearchDistances(
            totalDistance: total,
            limit: interval,
            stationDistances: stations,
            alreadySearched: coarse
        )
        let samples = (coarse + dense).sorted()
        for marker in stride(from: 2_046, through: 2_229, by: 1) {
            let along = Double(marker) * mile
            XCTAssertTrue(
                samples.contains { abs($0 - along) <= radius },
                "mile \(marker) on Arizona I-10 is outside every fuel search"
            )
        }
    }

    func testDensifySkipsAReserveGapAndAnUnsearchedHole() {
        let mile = AppSettings.metersPerMile
        let insideReserve = RoutePlannerViewModel.fuelDensifySearchDistances(
            totalDistance: 1_000 * mile,
            limit: 170 * mile,
            stationDistances: [100 * mile, 260 * mile]
        )
        XCTAssertTrue(insideReserve.isEmpty)

        let unknown = RoutePlannerViewModel.fuelDensifySearchDistances(
            totalDistance: 850 * mile,
            limit: 170 * mile,
            stationDistances: [100 * mile, 800 * mile],
            unsearched: [400 * mile]
        )
        XCTAssertTrue(unknown.isEmpty, "a failed lookup is not a hole to fill with more guesses")
    }

    /// The live miss: stops through mile 567, then a throttled stretch, then
    /// stations again near 1,904. Those later stations must not become the
    /// next fuel stop. The unsearched miles are not an empty road.
    func testThrottledStretchIsNotPlannedAsEmptyRoad() {
        let mile = AppSettings.metersPerMile
        let stations = [165, 332, 500, 567, 1_904, 2_039, 2_209].map {
            gas(at: Double($0) * mile)
        }
        let open = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 2_471 * mile,
            range: 200 * mile
        )
        XCTAssertTrue(open.stops.contains { $0.distanceAlongRoute > 1_900 * mile })

        let blocked = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: 2_471 * mile,
            range: 200 * mile,
            unsearched: [800 * mile, 1_400 * mile]
        )
        XCTAssertTrue(blocked.stops.contains { abs($0.distanceAlongRoute - 567 * mile) < mile })
        XCTAssertFalse(blocked.stops.contains { $0.distanceAlongRoute > 600 * mile })
        XCTAssertFalse(blocked.hasGap)
    }

    func testMapSearchPaceWaitsWhenTheWindowIsFull() {
        let now = Date()
        let full = Array(repeating: now, count: MapSearchPace.maxRequestsPerWindow)
        XCTAssertGreaterThan(MapSearchPace.delay(recent: full, now: now), 50)
        let room = (0..<(MapSearchPace.maxRequestsPerWindow - 1)).map { _ in
            now.addingTimeInterval(-1)
        }
        XCTAssertEqual(MapSearchPace.delay(recent: room, now: now), 0, accuracy: 0.001)
    }

    func testThrottleBackoffGrowsPastTheOldRetryPause() {
        XCTAssertEqual(MapSearchPace.throttleBackoff(attempt: 1), .seconds(2))
        XCTAssertEqual(MapSearchPace.throttleBackoff(attempt: 2), .seconds(4))
        XCTAssertEqual(MapSearchPace.throttleBackoff(attempt: 3), .seconds(8))
        XCTAssertEqual(MapSearchPace.throttleBackoff(attempt: 6), .seconds(8))
    }

    func testRetriedThrottleDropsOutOfTheUnsearchedMiles() {
        let kept = CorridorSearchResult(
            stops: [gas(at: 100)],
            status: .completed,
            succeeded: 4,
            failed: 0,
            throttled: 2,
            failedSampleDistances: [500, 900]
        )
        let retry = CorridorSearchResult(
            stops: [gas(at: 500)],
            status: .completed,
            succeeded: 1,
            failed: 0,
            throttled: 1,
            failedSampleDistances: [900]
        )
        let merged = RoutePlannerViewModel.mergedCorridorSearch(kept, with: retry, retried: [500, 900])
        XCTAssertEqual(merged.failedSampleDistances, [900])
        XCTAssertEqual(merged.throttled, 1)
        XCTAssertEqual(merged.stops.map(\.distanceAlongRoute), [100, 500])
        XCTAssertEqual(merged.status, .completed)
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
        // 10 km is inside the 20 km separation, and it is the only way to
        // reach the station at 105 km. That station is past the 85 km
        // reserve measured from the short hop and inside the tank, so the
        // empty reserve window takes it.
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

    /// A coast-to-coast ride on a 200-mile tank needs more than a handful of
    /// stops. Each leg, including the one to the destination, stays inside
    /// the range left after the 15% reserve. The count itself is not fixed.
    func testLongRideKeepsEveryLegInsideTheReserve() {
        let mile = AppSettings.metersPerMile
        let range = 200 * mile
        let total = 2_600 * mile
        XCTAssertGreaterThan(total, 2_500 * mile)
        let stations = stride(from: 20.0, through: 2_580.0, by: 20.0).map { gas(at: $0 * mile) }
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: total,
            range: range
        )
        let comfort = range * RoutePlannerViewModel.fuelSafetyFactor
        XCTAssertGreaterThanOrEqual(plan.stops.count, 7)
        XCTAssertFalse(plan.hasGap)
        var previous: CLLocationDistance = 0
        let points = plan.stops.map(\.distanceAlongRoute) + [total]
        for distance in points {
            XCTAssertLessThanOrEqual(
                distance - previous,
                comfort + 1,
                "leg of \((distance - previous) / mile) mi exceeds the reserve"
            )
            previous = distance
        }
    }

    /// Charlotte → LA is about 2,455 mi. On a 200 mi tank the reserve is 170.
    /// Every recommended hop, including the one into the destination, stays
    /// at or under that. Stations past 170 mi in a window are in the pool
    /// and must not be the pick.
    func testCoastToCoastLegsStayWithinOneSeventyMiles() {
        let mile = AppSettings.metersPerMile
        let range = 200 * mile
        let total = 2_500 * mile
        var marks = stride(from: 10.0, through: 2_490.0, by: 10.0).map { $0 }
        marks.append(contentsOf: [175, 180, 183])
        let stations = marks.map { gas(at: $0 * mile) }
        let plan = RoutePlannerViewModel.fuelPlan(
            from: stations,
            totalDistance: total,
            range: range
        )
        let reserve = 170 * mile
        XCTAssertGreaterThanOrEqual(plan.stops.count, 7)
        XCTAssertFalse(plan.hasGap)
        var previous: CLLocationDistance = 0
        let points = plan.stops.map(\.distanceAlongRoute) + [total]
        for distance in points {
            XCTAssertLessThanOrEqual(
                distance - previous,
                reserve,
                "leg of \((distance - previous) / mile) mi exceeds 170"
            )
            previous = distance
        }
    }
}
