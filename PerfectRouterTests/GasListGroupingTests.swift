import CoreLocation
import XCTest
@testable import PerfectRouter

/// Suggested Gas is one list, cut into the day a leg starts and the tank
/// window that leg fills. Collapsing a section does not drop a check, and
/// a replan of the same ride does not open it again.
@MainActor
final class GasListGroupingTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    private func station(
        _ name: String,
        miles: Double,
        recommended: Bool = false,
        pastRange: Bool = false
    ) -> GasListGrouping.Station {
        GasListGrouping.Station(
            id: UUID(),
            name: name,
            distance: miles * mile,
            isRecommended: recommended,
            pastRange: pastRange
        )
    }

    private func span(_ day: Int, from start: Double, to end: Double) -> GasListGrouping.DaySpan {
        GasListGrouping.DaySpan(dayNumber: day, start: start * mile, end: end * mile)
    }

    /// The stub ride: fills at 80, 150, and 230 miles, evenings at 90 and 180.
    /// Leg 2 starts at 80, before the overnight, so it stays on day 1.
    private func stubRide() -> GasListGrouping {
        let stations = [
            station("Home Fuel", miles: 0),
            station("Alt 15", miles: 15),
            station("Alt 25", miles: 25),
            station("Quick Stop", miles: 40),
            station("Alt 55", miles: 55),
            station("Pilot Madison", miles: 80, recommended: true),
            station("Alt 100", miles: 100),
            station("Alt 120", miles: 120),
            station("Alt 140", miles: 140),
            station("On Route Fuel", miles: 150, recommended: true),
            station("Alt 180", miles: 180),
            station("Alt 200", miles: 200),
            station("Alt 210", miles: 210),
            station("Shell Knoxville", miles: 230, recommended: true),
        ]
        return GasListGrouping.make(
            stations: stations,
            fillDistances: [80, 150, 230].map { $0 * mile },
            daySpans: [
                span(1, from: 0, to: 90),
                span(2, from: 90, to: 180),
                span(3, from: 180, to: 280),
            ],
            totalDistance: 280 * mile,
            usesMetric: false
        )
    }

    func testLegsKeepTheRecommendedStopAndTwoNearestAlternates() {
        let grouping = stubRide()
        XCTAssertTrue(grouping.showsLegHeaders)
        XCTAssertTrue(grouping.showsDayHeaders)
        XCTAssertEqual(grouping.stationCount, 14)
        XCTAssertEqual(grouping.days.map(\.dayNumber), [1, 2])

        let legs = grouping.days.flatMap(\.legs)
        XCTAssertEqual(legs.map(\.number), [1, 2, 3])
        XCTAssertEqual(legs.map(\.dayNumber), [1, 1, 2], "A leg that runs past an overnight stays on the day it starts")
        XCTAssertEqual(legs.map(\.title), [
            "Leg 1 · ~80 mi",
            "Leg 2 · ~150 mi",
            "Leg 3 · ~230 mi",
        ])
        XCTAssertEqual(legs[0].preview.map(\.name), ["Pilot Madison", "Quick Stop", "Alt 55"])
        XCTAssertEqual(legs[0].overflow.map(\.name), ["Home Fuel", "Alt 15", "Alt 25"])
        XCTAssertEqual(legs[1].preview.map(\.name), ["On Route Fuel", "Alt 120", "Alt 140"])
        XCTAssertEqual(legs[1].overflow.map(\.name), ["Alt 100"])
        XCTAssertEqual(legs[2].preview.map(\.name), ["Shell Knoxville", "Alt 200", "Alt 210"])
        XCTAssertEqual(legs[2].overflow.map(\.name), ["Alt 180"])
        XCTAssertFalse(grouping.days.contains { $0.dayNumber == 3 })
    }

    /// The header mile is the recommended fill, which is the first row of
    /// that leg. The next leg, which only starts at that fill, uses its own
    /// window end instead of repeating the mile.
    func testLegMileIsTheFillAndTheNextLegDoesNotRepeatIt() {
        let grouping = GasListGrouping.make(
            stations: [
                station("Pilot", miles: 1192, recommended: true),
                station("Alt A", miles: 1022),
                station("Alt B", miles: 1023),
                station("Later", miles: 1300),
            ],
            fillDistances: [1192 * mile],
            daySpans: [span(1, from: 0, to: 1500)],
            totalDistance: 1500 * mile,
            usesMetric: false
        )
        let legs = grouping.days.flatMap(\.legs)
        XCTAssertEqual(legs.map(\.title), [
            "Leg 1 · ~1192 mi",
            "Leg 2 · ~1500 mi",
        ])
        XCTAssertEqual(legs[0].preview.map(\.name), ["Pilot", "Alt A", "Alt B"])
        XCTAssertEqual(legs[0].preview.first?.distance ?? -1, 1192 * mile, accuracy: 1)
        XCTAssertEqual(legs[1].preview.map(\.name), ["Later"])
        XCTAssertFalse(legs[1].title.contains("1192"))
    }

    func testAMileOnTheOvernightBelongsToTheDayThatStartsThere() {
        let grouping = GasListGrouping.make(
            stations: [
                station("Evening", miles: 90, recommended: true),
                station("Morning", miles: 100),
            ],
            fillDistances: [90 * mile],
            daySpans: [
                span(1, from: 0, to: 90),
                span(2, from: 90, to: 180),
            ],
            totalDistance: 180 * mile,
            usesMetric: false
        )
        let legs = grouping.days.flatMap(\.legs)
        XCTAssertEqual(legs.map(\.dayNumber), [1, 2])
        XCTAssertEqual(legs[0].preview.map(\.name), ["Evening"])
        XCTAssertEqual(legs[1].preview.map(\.name), ["Morning"])
    }

    func testOneLegHasNoDayOrLegChrome() {
        let only = station("Quick Stop", miles: 40)
        let grouping = GasListGrouping.make(
            stations: [only],
            fillDistances: [],
            daySpans: [],
            totalDistance: 60 * mile,
            usesMetric: false
        )
        XCTAssertFalse(grouping.showsLegHeaders)
        XCTAssertFalse(grouping.showsDayHeaders)
        XCTAssertEqual(grouping.days.first?.legs.first?.preview.map(\.name) ?? [], ["Quick Stop"])
        XCTAssertEqual(grouping.days.first?.legs.first?.overflow ?? [], [])
        let rows = grouping.visibleRows(listExpanded: true, collapsedDays: [], overflowLegs: [])
        XCTAssertEqual(rows, [.station(only)])
    }

    func testPastRangeRollsUpFromAHiddenAlternate() {
        let grouping = GasListGrouping.make(
            stations: [
                station("Pilot Madison", miles: 80, recommended: true),
                station("Quick Stop", miles: 40),
                station("Alt 55", miles: 55),
                station("Dry", miles: 10, pastRange: true),
                station("On Route Fuel", miles: 150, recommended: true),
            ],
            fillDistances: [80 * mile, 150 * mile],
            daySpans: [span(1, from: 0, to: 90), span(2, from: 90, to: 200)],
            totalDistance: 200 * mile,
            usesMetric: false
        )
        let leg = grouping.days.first?.legs.first
        XCTAssertEqual(leg?.overflow.map(\.name) ?? [], ["Dry"])
        XCTAssertEqual(leg?.pastRange, true)
        XCTAssertTrue(grouping.pastRange)
        XCTAssertTrue(grouping.days.first?.pastRange == true)
        let hidden = grouping.visibleRows(listExpanded: true, collapsedDays: [], overflowLegs: [])
        XCTAssertFalse(hidden.contains { row in
            if case .station(let station) = row { return station.name == "Dry" }
            return false
        })
        XCTAssertEqual(
            CollapsibleListCopy.stateLabel(
                title: CollapsibleListCopy.gasTitle(count: grouping.stationCount),
                expanded: false,
                pastRange: true
            ),
            "Suggested Gas Stops (5), collapsed, Past your range"
        )
        XCTAssertEqual(
            CollapsibleListCopy.stateLabel(
                title: "Day 1",
                expanded: true,
                pastRange: true
            ),
            "Day 1, expanded"
        )
    }

    func testCollapsedSectionsOmitStationsAndKeepTheirHeaders() {
        let grouping = stubRide()
        XCTAssertTrue(grouping.visibleRows(listExpanded: false, collapsedDays: [], overflowLegs: []).isEmpty)

        let dayClosed = grouping.visibleRows(listExpanded: true, collapsedDays: [2], overflowLegs: [])
        XCTAssertTrue(dayClosed.contains { row in
            if case .dayHeader(let day) = row { return day.dayNumber == 2 }
            return false
        })
        XCTAssertFalse(dayClosed.contains { row in
            if case .legHeader(let leg) = row { return leg.number == 3 }
            return false
        })
        XCTAssertTrue(dayClosed.contains { row in
            if case .legHeader(let leg) = row { return leg.number == 2 }
            return false
        })

        let more = grouping.visibleRows(listExpanded: true, collapsedDays: [], overflowLegs: [1])
        XCTAssertTrue(more.contains { row in
            if case .station(let station) = row { return station.name == "Alt 15" }
            return false
        })
        XCTAssertTrue(more.contains { row in
            if case .showMore(let leg, let expanded) = row { return leg == 1 && expanded }
            return false
        })
    }

    func testDisclosureDefaultsAndAToggleSurvivesTheNextFill() {
        var memory = ListDisclosureMemory()
        XCTAssertTrue(memory.gasExpanded(fuelApplied: false))
        XCTAssertFalse(memory.gasExpanded(fuelApplied: true))
        XCTAssertTrue(memory.foodExpanded(foodApplied: false))
        XCTAssertFalse(memory.foodExpanded(foodApplied: true))
        XCTAssertTrue(memory.highlightsExpanded())

        memory.toggleGas(fuelApplied: false)
        memory.toggleHighlights()
        memory.toggleDay(2)
        memory.toggleOverflow(1)
        XCTAssertFalse(memory.gasExpanded(fuelApplied: false))
        XCTAssertFalse(memory.gasExpanded(fuelApplied: true))
        XCTAssertFalse(memory.highlightsExpanded())
        XCTAssertFalse(memory.dayExpanded(2))
        XCTAssertTrue(memory.overflowExpanded(1))

        memory.toggleGas(fuelApplied: true)
        XCTAssertTrue(memory.gasExpanded(fuelApplied: true))
        memory.reset()
        XCTAssertNil(memory.gasOverride)
        XCTAssertTrue(memory.collapsedDays.isEmpty)
        XCTAssertTrue(memory.overflowLegs.isEmpty)
    }

    func testTitlesNameTheCountAndTheOpenState() {
        XCTAssertEqual(CollapsibleListCopy.gasTitle(count: 13), "Suggested Gas Stops (13)")
        XCTAssertEqual(CollapsibleListCopy.foodTitle(count: 0), "Food (0)")
        XCTAssertEqual(CollapsibleListCopy.highlightsTitle(count: 2), "Highlights (2)")
        XCTAssertEqual(CollapsibleListCopy.dayTitle(2), "Day 2")
        XCTAssertEqual(CollapsibleListCopy.showMoreTitle(expanded: false), "Show more")
        XCTAssertEqual(CollapsibleListCopy.showMoreTitle(expanded: true), "Show less")
        XCTAssertEqual(
            GasListGrouping.legTitle(number: 3, markerMeters: 498 * mile, usesMetric: false),
            "Leg 3 · ~498 mi"
        )
        XCTAssertEqual(
            GasListGrouping.legAccessibilityLabel(title: "Leg 3 · ~498 mi", pastRange: true),
            "Leg 3 · ~498 mi, Past your range"
        )
    }

    func testApplyingGasDoesNotScrollOrReopenASection() {
        let viewModel = RoutePlannerViewModel()
        let start = waypoint("Start", lat: 33.0, lon: -82.0)
        let end = waypoint("End", lat: 35.0, lon: -80.0)
        viewModel.waypoints = [start, end]
        viewModel.plannedCorridor = [[
            start.coordinate,
            CLLocationCoordinate2D(latitude: 34, longitude: -81),
            end.coordinate,
        ]]
        XCTAssertTrue(viewModel.gasListExpanded)
        XCTAssertTrue(viewModel.highlightsListExpanded)
        XCTAssertTrue(viewModel.foodListExpanded)

        viewModel.toggleGasList()
        viewModel.toggleHighlightsList()
        viewModel.toggleGasDay(2)
        viewModel.toggleGasLegOverflow(1)
        let scroll = UUID()
        viewModel.scrollToWaypointID = scroll

        let pump = suggestion("Pilot", category: .gas, lat: 33.4, lon: -81.6, miles: 40)
        viewModel.addStop(from: pump)
        viewModel.applyBufferedGasStops()

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Pilot", "End"])
        XCTAssertTrue(viewModel.waypoints[1].isGasFill)
        XCTAssertFalse(viewModel.gasListExpanded)
        XCTAssertFalse(viewModel.highlightsListExpanded)
        XCTAssertFalse(viewModel.isGasDayExpanded(2))
        XCTAssertTrue(viewModel.listDisclosure.overflowExpanded(1))
        XCTAssertEqual(viewModel.scrollToWaypointID, scroll)

        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            viewModel.waypoints[1],
            waypoint("End", lat: 35.0, lon: -80.0),
        ]
        XCTAssertFalse(viewModel.gasListExpanded)
        XCTAssertFalse(viewModel.highlightsListExpanded)

        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Other", lat: 36.0, lon: -79.0),
        ]
        XCTAssertTrue(viewModel.gasListExpanded)
        XCTAssertTrue(viewModel.highlightsListExpanded)
        XCTAssertTrue(viewModel.isGasDayExpanded(2))
        XCTAssertFalse(viewModel.listDisclosure.overflowExpanded(1))
    }

    func testFuelAlreadyOnTheRideStartsTheGasListClosed() {
        let viewModel = RoutePlannerViewModel()
        var fill = waypoint("Pilot", lat: 33.4, lon: -81.6)
        fill.isGasFill = true
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            fill,
            waypoint("End", lat: 35.0, lon: -80.0),
        ]
        XCTAssertTrue(viewModel.hasAppliedFuelStop)
        XCTAssertFalse(viewModel.gasListExpanded)

        viewModel.toggleGasList()
        XCTAssertTrue(viewModel.gasListExpanded)
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            fill,
            waypoint("End", lat: 35.0, lon: -80.0),
        ]
        XCTAssertTrue(viewModel.gasListExpanded)
    }

    func testAddingFoodClosesFoodAndKeepsThatChoiceForTheRide() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("End", lat: 35.0, lon: -80.0),
        ]
        XCTAssertTrue(viewModel.foodListExpanded)
        XCTAssertFalse(viewModel.hasAppliedFoodStop)

        viewModel.addStop(from: suggestion("Diner", category: .food, lat: 33.5, lon: -81.5, miles: 20))
        XCTAssertTrue(viewModel.hasAppliedFoodStop)
        XCTAssertFalse(viewModel.foodListExpanded)
        XCTAssertEqual(viewModel.scrollToWaypointID, viewModel.waypoints[1].id)

        viewModel.toggleFoodList()
        XCTAssertTrue(viewModel.foodListExpanded)
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            viewModel.waypoints[1],
            waypoint("End", lat: 35.0, lon: -80.0),
        ]
        XCTAssertTrue(viewModel.foodListExpanded)

        viewModel.waypoints = [
            waypoint("Start", lat: 33.0, lon: -82.0),
            waypoint("Other", lat: 36.0, lon: -79.0),
        ]
        XCTAssertFalse(viewModel.hasAppliedFoodStop)
        XCTAssertTrue(viewModel.foodListExpanded)
    }

    func testGasListKeepsTheRecommendedFillWithTheAlternates() {
        let viewModel = RoutePlannerViewModel()
        let mile = mile
        viewModel.fuelRangeMeters = 100 * mile
        viewModel.waypoints = [
            Waypoint(name: "Test Origin", coordinate: UITestFixture.origin),
            Waypoint(
                name: "Test Destination",
                coordinate: UITestFixture.coordinate(milesNorth: 450, eastMeters: 0)
            ),
        ]
        let quick = gasStop("Quick Stop", miles: 40)
        let pilot = gasStop("Pilot Madison", miles: 80)
        let shell = gasStop("Shell Knoxville", miles: 230)
        let dry = gasStop("Dry", miles: 400)
        viewModel.fuelStops = [pilot, shell]
        viewModel.fuelPlanEntries = [.recommended(pilot), .recommended(shell)]
        viewModel.suggestedStops = [dry, shell, quick, pilot]

        XCTAssertEqual(
            viewModel.gasListStations.map(\.name),
            ["Quick Stop", "Pilot Madison", "Shell Knoxville", "Dry"]
        )
        XCTAssertTrue(viewModel.gasListStations.contains { $0.name == "Pilot Madison" })
        XCTAssertFalse(viewModel.suggestionListStops.contains { $0.name == "Pilot Madison" })
        XCTAssertTrue(viewModel.suggestionListStops.contains { $0.name == "Quick Stop" })

        let grouping = viewModel.gasListGrouping
        XCTAssertTrue(grouping.showsLegHeaders)
        XCTAssertFalse(grouping.showsDayHeaders)
        XCTAssertTrue(grouping.pastRange)
        XCTAssertEqual(
            grouping.days.flatMap(\.legs).map { $0.preview.map(\.name) },
            [["Pilot Madison", "Quick Stop"], ["Shell Knoxville"], ["Dry"]]
        )
        XCTAssertEqual(grouping.days.flatMap(\.legs)[2].pastRange, true)
    }

    /// Checking a pump and tapping Apply inserts that waypoint. A replan
    /// that then clears the fuel plan must not flatten the legs or hide
    /// Select recommended.
    func testApplyCheckedGasStopKeepsTheWaypointAndTheLegs() {
        let viewModel = RoutePlannerViewModel()
        let line = stride(from: 0.0, through: 280, by: 40).map {
            UITestFixture.coordinate(milesNorth: $0, eastMeters: 0)
        }
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: UITestFixture.coordinate(milesNorth: 0, eastMeters: 0)),
            Waypoint(name: "End", coordinate: UITestFixture.coordinate(milesNorth: 280, eastMeters: 0)),
        ]
        viewModel.plannedCorridor = [line]
        let quik = gasStop("QuikTrip", miles: 80)
        let shell = gasStop("Shell", miles: 160)
        viewModel.fuelStops = [quik, shell]
        viewModel.fuelPlanEntries = [.recommended(quik), .recommended(shell)]
        viewModel.gasStations = [
            gasStop("Alt 40", miles: 40),
            gasStop("RaceTrac", miles: 60),
            gasStop("Chevron", miles: 70),
            quik,
            gasStop("Extra", miles: 120),
            gasStop("BP", miles: 140),
            gasStop("Amoco", miles: 150),
            shell,
            gasStop("Marathon", miles: 190),
        ]

        viewModel.toggleBufferedGasStop(quik)
        XCTAssertEqual(viewModel.bufferedGasStops.map(\.name), ["QuikTrip"])
        viewModel.applyBufferedGasStops()

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "QuikTrip", "End"])
        XCTAssertTrue(viewModel.waypoints[1].isGasFill)
        XCTAssertTrue(viewModel.bufferedGasStops.isEmpty)

        // The replan drops the old recommendations. The applied fill remains
        // the leg boundary, and Select recommended stays with the corridor.
        viewModel.fuelStops = []
        viewModel.fuelPlanEntries = []
        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)
        XCTAssertTrue(viewModel.showsSelectRecommendedFuelButton)
        XCTAssertFalse(viewModel.gasListExpanded)

        viewModel.toggleGasList()
        let legs = viewModel.gasListGrouping.days.flatMap(\.legs)
        XCTAssertTrue(viewModel.gasListGrouping.showsLegHeaders)
        XCTAssertEqual(legs.first?.preview.map(\.name), ["QuikTrip", "RaceTrac", "Chevron"])
        XCTAssertEqual(legs.first?.overflow.map(\.name), ["Alt 40"])
        XCTAssertTrue(viewModel.gasListRows.contains { row in
            if case .showMore(let legNumber, _) = row { return legNumber == 1 }
            return false
        })
    }

    /// After Apply the fuel plan can come back empty. The applied pumps are
    /// still the leg edges, Select recommended stays up, and each leg keeps
    /// that pump plus two alternates and Show more.
    func testAppliedFillsKeepLegGroupsAndSelectRecommended() {
        let viewModel = RoutePlannerViewModel()
        let line = stride(from: 0.0, through: 280, by: 40).map {
            UITestFixture.coordinate(milesNorth: $0, eastMeters: 0)
        }
        func fill(_ name: String, miles: Double) -> Waypoint {
            var waypoint = Waypoint(
                name: name,
                coordinate: UITestFixture.coordinate(milesNorth: miles, eastMeters: 0)
            )
            waypoint.isGasFill = true
            return waypoint
        }
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: UITestFixture.coordinate(milesNorth: 0, eastMeters: 0)),
            fill("QuikTrip", miles: 80),
            fill("Shell", miles: 160),
            Waypoint(name: "End", coordinate: UITestFixture.coordinate(milesNorth: 280, eastMeters: 0)),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.fuelStops = []
        viewModel.fuelPlanEntries = []
        viewModel.gasStations = [
            gasStop("Alt 40", miles: 40),
            gasStop("RaceTrac", miles: 60),
            gasStop("Chevron", miles: 70),
            gasStop("Extra", miles: 120),
            gasStop("BP", miles: 140),
            gasStop("Amoco", miles: 150),
            gasStop("Marathon", miles: 190),
        ]

        XCTAssertTrue(viewModel.selectableRecommendedFuelStops.isEmpty)
        XCTAssertTrue(viewModel.showsSelectRecommendedFuelButton)
        XCTAssertFalse(viewModel.gasListExpanded)

        let grouping = viewModel.gasListGrouping
        XCTAssertTrue(grouping.showsLegHeaders)
        let legs = grouping.days.flatMap(\.legs)
        XCTAssertEqual(legs.map(\.number), [1, 2, 3])
        XCTAssertEqual(legs.map { $0.preview.map(\.name) }, [
            ["QuikTrip", "RaceTrac", "Chevron"],
            ["Shell", "BP", "Amoco"],
            ["Marathon"],
        ])
        XCTAssertEqual(legs[0].overflow.map(\.name), ["Alt 40"])
        XCTAssertEqual(legs[1].overflow.map(\.name), ["Extra"])
        XCTAssertTrue(legs[0].title.hasPrefix("Leg 1"))
        XCTAssertTrue(legs[1].title.hasPrefix("Leg 2"))

        viewModel.toggleGasList()
        let showMore = viewModel.gasListRows.compactMap { row -> Int? in
            if case .showMore(let legNumber, let expanded) = row {
                XCTAssertFalse(expanded)
                return legNumber
            }
            return nil
        }
        XCTAssertEqual(showMore, [1, 2])
        XCTAssertTrue(viewModel.gasListRows.contains { row in
            if case .legHeader = row { return true }
            return false
        })
    }

    /// After Apply, a refreshed search pin for the same pump is not a second
    /// candidate. The applied stop is the recommended row, its id survives
    /// the next read, and the header count does not grow by the fill count.
    func testAppliedFillShowsOnceAndTheRowResolves() {
        let viewModel = RoutePlannerViewModel()
        let line = stride(from: 0.0, through: 280, by: 40).map {
            UITestFixture.coordinate(milesNorth: $0, eastMeters: 0)
        }
        func fill(_ name: String, miles: Double) -> Waypoint {
            var waypoint = Waypoint(
                name: name,
                coordinate: UITestFixture.coordinate(milesNorth: miles, eastMeters: 0)
            )
            waypoint.isGasFill = true
            return waypoint
        }
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: UITestFixture.coordinate(milesNorth: 0, eastMeters: 0)),
            fill("QuikTrip", miles: 80),
            fill("Shell", miles: 160),
            Waypoint(name: "End", coordinate: UITestFixture.coordinate(milesNorth: 280, eastMeters: 0)),
        ]
        viewModel.plannedCorridor = [line]
        viewModel.fuelStops = []
        viewModel.fuelPlanEntries = []
        viewModel.gasStations = [
            gasStop("QuikTrip", miles: 80.2, eastMeters: 400),
            gasStop("Shell", miles: 160.2, eastMeters: 400),
            gasStop("Alt 40", miles: 40),
            gasStop("RaceTrac", miles: 60),
            gasStop("Chevron", miles: 70),
            gasStop("Extra", miles: 120),
            gasStop("BP", miles: 140),
            gasStop("Amoco", miles: 150),
            gasStop("Marathon", miles: 190),
        ]

        let listed = viewModel.gasListStations
        XCTAssertEqual(listed.filter { $0.name == "QuikTrip" }.count, 1)
        XCTAssertEqual(listed.filter { $0.name == "Shell" }.count, 1)
        XCTAssertEqual(listed.count, 9, "Two applied fills replace their search pins instead of adding to the 7 alternates")

        let grouping = viewModel.gasListGrouping
        XCTAssertEqual(grouping.stationCount, listed.count)
        let resolved = Dictionary(uniqueKeysWithValues: viewModel.gasListStations.map { ($0.id, $0) })
        let legs = grouping.days.flatMap(\.legs)
        XCTAssertEqual(legs.map { $0.preview.first?.name }, ["QuikTrip", "Shell", "Marathon"])
        for leg in legs {
            for station in leg.preview + leg.overflow {
                XCTAssertNotNil(resolved[station.id], "\(station.name) must resolve on the next read")
            }
            XCTAssertFalse(leg.overflow.contains { $0.name == "QuikTrip" || $0.name == "Shell" })
        }

        let quik = try XCTUnwrap(listed.first { $0.name == "QuikTrip" })
        let alternate = try XCTUnwrap(listed.first { $0.name == "RaceTrac" })
        XCTAssertEqual(viewModel.gasSuggestionIdentifier(for: quik), AccessibilityID.fuelStop("QuikTrip", checked: true))
        XCTAssertFalse(viewModel.gasSuggestionIdentifier(for: quik).hasPrefix("gasCandidate"))
        XCTAssertEqual(viewModel.gasSuggestionIdentifier(for: alternate), AccessibilityID.gasCandidate("RaceTrac"))
        XCTAssertTrue(viewModel.isAppliedGasFill(quik))
        XCTAssertFalse(viewModel.isAppliedGasFill(alternate))
    }

    private func gasStop(_ name: String, miles: Double, eastMeters: Double = 800) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: UITestFixture.coordinate(milesNorth: miles, eastMeters: eastMeters),
            category: .gas,
            distanceAlongRoute: miles * mile
        )
    }

    private func waypoint(_ name: String, lat: Double, lon: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
    }

    private func suggestion(
        _ name: String,
        category: StopCategory,
        lat: Double,
        lon: Double,
        miles: Double
    ) -> SuggestedStop {
        SuggestedStop(
            name: name,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            category: category,
            distanceAlongRoute: miles * mile
        )
    }
}
