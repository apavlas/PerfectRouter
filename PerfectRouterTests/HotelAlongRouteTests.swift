import CoreLocation
import XCTest
@testable import PerfectRouter

/// The evening window and which real lodging places are kept. MapKit is not
/// involved: a place that was not handed in cannot appear.
@MainActor
final class HotelAlongRouteTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    private func leg(miles: Double, hours: Double) -> FuelStopRidingTime.Leg {
        FuelStopRidingTime.Leg(
            distanceMeters: miles * mile,
            expectedTravelTime: hours * 3_600
        )
    }

    /// 1,200 miles in 24 hours. 8:00 AM reaches 6:00 PM at mile 500, and the
    /// next morning reaches the following 6:00 PM at mile 1,000.
    private var longRide: [FuelStopRidingTime.Leg] {
        [leg(miles: 1_200, hours: 24)]
    }

    private func evenings(
        legs: [FuelStopRidingTime.Leg]? = nil,
        overnights: [CLLocationDistance] = [],
        departureHour: Int,
        departureMinute: Int = 0,
        targetHour: Int = 18,
        targetMinute: Int = 0
    ) -> [HotelAlongRoute.Evening] {
        HotelAlongRoute.evenings(
            legs: legs ?? longRide,
            overnightDistances: overnights,
            departureMinutes: departureHour * 60 + departureMinute,
            targetMinutes: targetHour * 60 + targetMinute
        )
    }

    private func candidate(
        _ name: String,
        hour: Int,
        minute: Int,
        detourMiles: Double,
        key: String? = nil
    ) -> HotelAlongRoute.Candidate {
        HotelAlongRoute.Candidate(
            key: key ?? name,
            name: name,
            arrivalMinutes: hour * 60 + minute,
            detourMeters: detourMiles * mile,
            distanceAlongRoute: 0
        )
    }

    // MARK: - Window

    func testDefaultWindowIsAnHourEitherSideOfSix() {
        XCTAssertEqual(HotelAlongRoute.defaultTargetMinutes, 18 * 60)
        XCTAssertEqual(HotelAlongRoute.windowHalfMinutes, 60)
        XCTAssertEqual(
            HotelAlongRoute.emptyMessage(targetMinutes: HotelAlongRoute.defaultTargetMinutes),
            "No lodging found between 5 and 7 PM"
        )
        XCTAssertEqual(
            HotelAlongRoute.windowLabel(targetMinutes: HotelAlongRoute.defaultTargetMinutes),
            "Hotels between 5 and 7 PM"
        )
        XCTAssertEqual(HotelAlongRoute.nearRadiusMeters, 5 * mile, accuracy: 0.01)
        XCTAssertEqual(HotelAlongRoute.farRadiusMeters, 15 * mile, accuracy: 0.01)
        XCTAssertEqual(HotelAlongRoute.morningDepartureMinutes, 8 * 60)
    }

    func testChangedTargetRenamesTheWindow() {
        XCTAssertEqual(
            HotelAlongRoute.emptyMessage(targetMinutes: 19 * 60),
            "No lodging found between 6 and 8 PM"
        )
        XCTAssertEqual(
            HotelAlongRoute.betweenPhrase(targetMinutes: 18 * 60 + 30),
            "5:30 and 7:30 PM"
        )
        XCTAssertEqual(
            HotelAlongRoute.betweenPhrase(targetMinutes: 12 * 60 + 30),
            "11:30 AM and 1:30 PM"
        )
    }

    func testSixPMPointFollowsRidingTimeAndALaterDeparture() {
        let fromEight = evenings(departureHour: 8)
        XCTAssertEqual(fromEight.first?.dayNumber, 1)
        XCTAssertEqual(fromEight.first?.targetDistance ?? 0, 500 * mile, accuracy: 1)
        XCTAssertEqual(fromEight.first?.ridingSeconds ?? 0, 10 * 3_600, accuracy: 1)

        let fromFour = evenings(departureHour: 16)
        XCTAssertEqual(fromFour.first?.targetDistance ?? 0, 100 * mile, accuracy: 1)
        XCTAssertLessThan(fromFour.first?.targetDistance ?? 0, fromEight.first?.targetDistance ?? 0)

        let fromSeven = evenings(departureHour: 8, targetHour: 19)
        XCTAssertEqual(fromSeven.first?.targetDistance ?? 0, 550 * mile, accuracy: 1)
    }

    func testDepartureAtOrAfterTheTargetHasNoEvening() {
        XCTAssertNil(HotelAlongRoute.ridingSeconds(fromDepartureMinutes: 18 * 60, toTargetMinutes: 18 * 60))
        XCTAssertNil(HotelAlongRoute.ridingSeconds(fromDepartureMinutes: 19 * 60, toTargetMinutes: 18 * 60))
        XCTAssertTrue(evenings(departureHour: 18).isEmpty)
        XCTAssertTrue(evenings(departureHour: 19).isEmpty)
    }

    func testTripThatEndsBeforeSixHasNoSuggestion() {
        // 2:00 PM plus 3 hours of riding arrives at 5:00 PM, still before 6.
        let ride = [leg(miles: 150, hours: 3)]
        XCTAssertTrue(evenings(legs: ride, departureHour: 14).isEmpty)

        // Arriving exactly at 6:00 PM is the destination, not a night on the road.
        let untilSix = [leg(miles: 500, hours: 10)]
        XCTAssertTrue(evenings(legs: untilSix, departureHour: 8).isEmpty)
    }

    func testMultiDaySuggestsEachEveningFromTheNextMorning() {
        let days = evenings(departureHour: 8)
        XCTAssertEqual(days.map(\.dayNumber), [1, 2])
        XCTAssertEqual(days[0].targetDistance, 500 * mile, accuracy: 1)
        XCTAssertEqual(days[0].departureMinutes, 8 * 60)
        XCTAssertEqual(days[1].dayStartDistance, 500 * mile, accuracy: 1)
        XCTAssertEqual(days[1].departureMinutes, HotelAlongRoute.morningDepartureMinutes)
        XCTAssertEqual(days[1].targetDistance, 1_000 * mile, accuracy: 1)
        XCTAssertEqual(days[1].ridingSeconds, 10 * 3_600, accuracy: 1)
    }

    func testAppliedOvernightStartsTheNextSixPMFromThatHotel() {
        let hotel = 400 * mile
        let days = evenings(overnights: [hotel], departureHour: 8)
        XCTAssertEqual(days.map(\.dayNumber), [2])
        XCTAssertEqual(days[0].dayStartDistance, hotel, accuracy: 1)
        XCTAssertEqual(days[0].departureMinutes, 8 * 60)
        XCTAssertEqual(days[0].targetDistance, 900 * mile, accuracy: 1)
    }

    func testRidingTimeAndSinceLastResetTheNextMorning() {
        let legs = [
            leg(miles: 100, hours: 2),
            leg(miles: 62, hours: 1 + 40.0 / 60),
            leg(miles: 50, hours: 2 + 25.0 / 60),
        ]
        // The hotel is the first stop. Its own row is still day 1.
        XCTAssertEqual(
            FuelStopRidingTime.waypointCaption(index: 1, legs: legs, dayStartIndex: 0, usesMetric: false),
            "100 mi · 2h 00m riding"
        )
        XCTAssertEqual(
            FuelStopRidingTime.waypointCaption(index: 2, legs: legs, dayStartIndex: 1, usesMetric: false),
            "62 mi · 1h 40m riding"
        )
        XCTAssertEqual(
            FuelStopRidingTime.waypointCaption(index: 3, legs: legs, dayStartIndex: 1, usesMetric: false),
            "112 mi · 4h 05m riding (2h 25m since last)"
        )
        // Without the reset the destination is still the whole trip.
        XCTAssertEqual(
            FuelStopRidingTime.waypointCaption(index: 3, legs: legs, usesMetric: false),
            "212 mi · 6h 05m riding (2h 25m since last)"
        )
    }

    func testDayTitlesSplitOnlyAroundAnOvernightStop() {
        XCTAssertNil(HotelAlongRoute.dayTitle(at: 0, overnightIndices: []))
        XCTAssertEqual(HotelAlongRoute.dayTitle(at: 0, overnightIndices: [2]), "Day 1")
        XCTAssertNil(HotelAlongRoute.dayTitle(at: 1, overnightIndices: [2]))
        XCTAssertNil(HotelAlongRoute.dayTitle(at: 2, overnightIndices: [2]))
        XCTAssertEqual(HotelAlongRoute.dayTitle(at: 3, overnightIndices: [2]), "Day 2")
        XCTAssertEqual(HotelAlongRoute.dayStartIndex(for: 2, overnightIndices: [2]), 0)
        XCTAssertEqual(HotelAlongRoute.dayStartIndex(for: 3, overnightIndices: [2]), 2)
        XCTAssertEqual(
            HotelAlongRoute.dayStartDistance(for: 900, overnightDistances: [400, 900]),
            400,
            accuracy: 0.1
        )
    }

    // MARK: - Selection

    func testSelectionSortsClosestToSixAndKeepsAtMostThree() {
        let near = [
            candidate("Late", hour: 18, minute: 50, detourMiles: 4),
            candidate("Early", hour: 17, minute: 10, detourMiles: 1),
            candidate("Close", hour: 18, minute: 20, detourMiles: 3),
            candidate("Also", hour: 18, minute: 40, detourMiles: 2),
            candidate("After Window", hour: 19, minute: 5, detourMiles: 0.5),
        ]
        let selection = HotelAlongRoute.select(near: near, far: [], targetMinutes: 18 * 60)
        XCTAssertFalse(selection.widened)
        XCTAssertNil(selection.emptyMessage)
        // 6:20, then 6:40, then 5:10. 6:50 is the same 50 minutes off as 5:10
        // and loses the tie on detour. 7:05 is outside the window.
        XCTAssertEqual(selection.keys, ["Close", "Also", "Early"])
    }

    func testTwoRealOptionsStayTwo() {
        let near = [
            candidate("A", hour: 18, minute: 10, detourMiles: 1),
            candidate("B", hour: 17, minute: 30, detourMiles: 2),
        ]
        let selection = HotelAlongRoute.select(near: near, far: [], targetMinutes: 18 * 60)
        XCTAssertEqual(selection.keys, ["A", "B"])
    }

    func testEmptyNearWidensOnceAndLabelsFartherOptions() {
        let outside = candidate("Diner", hour: 20, minute: 0, detourMiles: 1)
        let far = [
            candidate("Farther Inn", hour: 18, minute: 10, detourMiles: 12),
            candidate("Other Inn", hour: 18, minute: 40, detourMiles: 9),
            candidate("Too Far", hour: 18, minute: 5, detourMiles: 16),
        ]
        let keptNear = HotelAlongRoute.select(near: [outside], far: [], targetMinutes: 18 * 60)
        XCTAssertFalse(keptNear.widened)
        XCTAssertEqual(
            keptNear.emptyMessage,
            "No lodging found between 5 and 7 PM"
        )

        let widened = HotelAlongRoute.select(near: [], far: far, targetMinutes: 18 * 60)
        XCTAssertTrue(widened.widened)
        XCTAssertNil(widened.emptyMessage)
        XCTAssertEqual(widened.keys, ["Farther Inn", "Other Inn"])
        XCTAssertEqual(
            HotelAlongRoute.arrivalCaption(
                arrivalMinutes: 18 * 60 + 20,
                detourMeters: 2 * mile,
                fartherOff: false,
                usesMetric: false
            ),
            "arrive ~6:20 PM · 2 mi off route"
        )
        XCTAssertEqual(
            HotelAlongRoute.arrivalCaption(
                arrivalMinutes: 18 * 60 + 10,
                detourMeters: 12 * mile,
                fartherOff: true,
                usesMetric: false
            ),
            "arrive ~6:10 PM · 12 mi off route · farther off"
        )
    }

    func testNearResultWinsOverACloserFarResult() {
        let near = [candidate("On Route", hour: 18, minute: 50, detourMiles: 2)]
        let far = [candidate("Closer Clock", hour: 18, minute: 5, detourMiles: 8)]
        let selection = HotelAlongRoute.select(near: near, far: far, targetMinutes: 18 * 60)
        XCTAssertEqual(selection.keys, ["On Route"])
        XCTAssertFalse(selection.widened)
    }

    func testDuplicatePlaceIsListedOnce() {
        let copy = candidate("Inn", hour: 18, minute: 15, detourMiles: 1, key: "same")
        let selection = HotelAlongRoute.select(near: [copy, copy], far: [], targetMinutes: 18 * 60)
        XCTAssertEqual(selection.keys, ["same"])
    }

    func testEdgesOfTheWindowAreIncluded() {
        let edges = [
            candidate("Five", hour: 17, minute: 0, detourMiles: 1),
            candidate("Seven", hour: 19, minute: 0, detourMiles: 1),
        ]
        let selection = HotelAlongRoute.select(near: edges, far: [], targetMinutes: 18 * 60)
        XCTAssertEqual(Set(selection.keys), ["Five", "Seven"])
    }

    func testNothingInEitherRadiusNamesTheWindow() {
        let selection = HotelAlongRoute.select(near: [], far: [], targetMinutes: 18 * 60)
        XCTAssertTrue(selection.keys.isEmpty)
        XCTAssertFalse(selection.widened)
        XCTAssertEqual(selection.emptyMessage, "No lodging found between 5 and 7 PM")
    }

    func testContactButtonsUseOnlyAPublishedNumberAndPage() {
        XCTAssertEqual(
            HotelAlongRoute.telephoneURL(from: "(555) 010-1000")?.absoluteString,
            "tel:5550101000"
        )
        XCTAssertNil(HotelAlongRoute.telephoneURL(from: nil))
        XCTAssertNil(HotelAlongRoute.telephoneURL(from: "front desk"))
        XCTAssertNil(HotelAlongRoute.websiteURL(from: nil))
        XCTAssertNil(HotelAlongRoute.websiteURL(from: URL(string: "tel:5550101000")))
        XCTAssertEqual(
            HotelAlongRoute.websiteURL(from: URL(string: "https://inn.example/stay"))?.absoluteString,
            "https://inn.example/stay"
        )
    }

    func testSearchCenterSitsOnTheRouteAtTheRequestedDistance() {
        let start = CLLocationCoordinate2D(latitude: 33, longitude: -82)
        let end = CLLocationCoordinate2D(latitude: 34, longitude: -82)
        let line = [start, end]
        let length = RouteGeometry.length(of: line)
        let mid = RouteGeometry.coordinate(atDistance: length / 2, alongPolylines: [line])
        XCTAssertNotNil(mid)
        XCTAssertEqual(mid?.latitude ?? 0, 33.5, accuracy: 0.01)
        XCTAssertEqual(mid?.longitude ?? 0, -82, accuracy: 0.001)
        XCTAssertNil(RouteGeometry.coordinate(atDistance: 10, alongPolylines: []))
    }

    // MARK: - Apply, day split, tank

    func testOvernightHotelIsAFullTankForTheNextMorning() {
        XCTAssertTrue(RoutePlannerViewModel.isTankFill(isGasFill: false, isOvernight: true))
        XCTAssertTrue(RoutePlannerViewModel.isTankFill(isGasFill: true, isOvernight: false))
        XCTAssertFalse(RoutePlannerViewModel.isTankFill(isGasFill: false, isOvernight: false))

        let stations = stride(from: 20_000.0, through: 240_000.0, by: 20_000.0).map { meters in
            SuggestedStop(
                name: "Gas @\(Int(meters))",
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                category: .gas,
                distanceAlongRoute: meters
            )
        }
        // The hotel's mile mark is the fill. The next tank is planned from
        // there, same as a pump the rider already added.
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 250_000,
            range: 100_000,
            filledAt: [80_000]
        )
        XCTAssertFalse(hasGap)
        XCTAssertEqual(stops.map { Int($0.distanceAlongRoute) }, [160_000, 240_000])
    }

    func testCheckHotelThenApplyAddsOneOvernightAndReplansOnce() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: CLLocationCoordinate2D(latitude: 33, longitude: -82)),
            Waypoint(name: "End", coordinate: CLLocationCoordinate2D(latitude: 34, longitude: -81)),
        ]
        let hotel = SuggestedStop(
            name: "Trail Inn",
            coordinate: CLLocationCoordinate2D(latitude: 33.5, longitude: -81.5),
            category: .lodging,
            distanceAlongRoute: 80_000,
            detourMeters: 2 * mile
        )

        viewModel.addStop(from: hotel)
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])
        XCTAssertTrue(viewModel.isHotelBuffered(hotel))

        viewModel.addStop(from: hotel)
        XCTAssertFalse(viewModel.isHotelBuffered(hotel))
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])

        viewModel.addStop(from: hotel)
        let before = viewModel.calculatingGeneration
        viewModel.applyBufferedHotelStops()
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Trail Inn", "End"])
        XCTAssertTrue(viewModel.waypoints[1].isOvernight)
        XCTAssertFalse(viewModel.waypoints[1].isGasFill)
        XCTAssertTrue(viewModel.bufferedHotelStops.isEmpty)
        XCTAssertEqual(viewModel.calculatingGeneration, before + 1)

        viewModel.applyBufferedHotelStops()
        XCTAssertEqual(viewModel.calculatingGeneration, before + 1)
        XCTAssertEqual(viewModel.rideDayTitle(at: 0), "Day 1")
        XCTAssertEqual(viewModel.rideDayTitle(at: 2), "Day 2")
    }

    func testDeletingTheHotelReturnsToOneDayAndReplansOnce() {
        let viewModel = RoutePlannerViewModel()
        var hotel = Waypoint(
            name: "Trail Inn",
            coordinate: CLLocationCoordinate2D(latitude: 33.5, longitude: -81.5)
        )
        hotel.isOvernight = true
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: CLLocationCoordinate2D(latitude: 33, longitude: -82)),
            hotel,
            Waypoint(name: "End", coordinate: CLLocationCoordinate2D(latitude: 34, longitude: -81)),
        ]
        XCTAssertEqual(viewModel.rideDayTitle(at: 0), "Day 1")
        XCTAssertEqual(viewModel.rideDayTitle(at: 2), "Day 2")

        let before = viewModel.calculatingGeneration
        viewModel.removeWaypoint(at: IndexSet(integer: 1))
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "End"])
        XCTAssertNil(viewModel.rideDayTitle(at: 0))
        XCTAssertNil(viewModel.rideDayTitle(at: 1))
        XCTAssertEqual(viewModel.calculatingGeneration, before + 1)
    }

    func testSelectingASecondHotelOnTheSameEveningReplacesTheFirst() {
        var checked: [Int: String] = [:]
        checked = HotelAlongRoute.checkedKeys(selecting: "Quality Inn", onDay: 1, current: checked)
        checked = HotelAlongRoute.checkedKeys(selecting: "Holiday Inn Express", onDay: 1, current: checked)
        XCTAssertEqual(checked, [1: "Holiday Inn Express"])
        XCTAssertEqual(HotelAlongRoute.keysToApply(checked), ["Holiday Inn Express"])

        checked = HotelAlongRoute.checkedKeys(selecting: "OKC Hotel", onDay: 2, current: checked)
        XCTAssertEqual(
            HotelAlongRoute.keysToApply(checked),
            ["Holiday Inn Express", "OKC Hotel"]
        )
        // Checking the selected hotel again clears that evening only.
        checked = HotelAlongRoute.checkedKeys(selecting: "Holiday Inn Express", onDay: 1, current: checked)
        XCTAssertEqual(HotelAlongRoute.keysToApply(checked), ["OKC Hotel"])
    }

    func testTwoSameEveningHotelsApplyAsOneOvernight() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            Waypoint(name: "Start", coordinate: CLLocationCoordinate2D(latitude: 33, longitude: -82)),
            Waypoint(name: "End", coordinate: CLLocationCoordinate2D(latitude: 34, longitude: -81)),
        ]
        let quality = SuggestedStop(
            name: "Quality Inn",
            coordinate: CLLocationCoordinate2D(latitude: 33.40, longitude: -81.50),
            category: .lodging,
            distanceAlongRoute: 80_000,
            detourMeters: 2 * mile
        )
        let holiday = SuggestedStop(
            name: "Holiday Inn Express",
            coordinate: CLLocationCoordinate2D(latitude: 33.41, longitude: -81.51),
            category: .lodging,
            distanceAlongRoute: 81_600,
            detourMeters: mile
        )
        let pump = SuggestedStop(
            name: "Pilot Madison",
            coordinate: CLLocationCoordinate2D(latitude: 33.2, longitude: -82),
            category: .gas,
            distanceAlongRoute: 40_000
        )
        viewModel.fuelStops = [pump]
        viewModel.gasStations = [pump]
        viewModel.legs = [
            StubMKRoute(
                name: "Leg",
                coordinates: [
                    CLLocationCoordinate2D(latitude: 33, longitude: -82),
                    CLLocationCoordinate2D(latitude: 34, longitude: -81),
                ],
                distance: 160_000,
                expectedTravelTime: 3 * 3_600,
                hasHighways: true
            )
        ]

        viewModel.toggleBufferedHotelStop(quality, onEvening: 1)
        viewModel.toggleBufferedHotelStop(holiday, onEvening: 1)
        XCTAssertFalse(viewModel.isHotelBuffered(quality))
        XCTAssertTrue(viewModel.isHotelBuffered(holiday))

        viewModel.applyBufferedHotelStops()
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Holiday Inn Express", "End"])
        XCTAssertEqual(viewModel.waypoints.filter(\.isOvernight).count, 1)
        XCTAssertEqual(viewModel.rideDayTitle(at: 0), "Day 1")
        XCTAssertNil(viewModel.rideDayTitle(at: 1))
        XCTAssertEqual(viewModel.rideDayTitle(at: 2), "Day 2")
        XCTAssertEqual(viewModel.fuelStops.map(\.name), ["Pilot Madison"])
        XCTAssertEqual(viewModel.gasStations.map(\.name), ["Pilot Madison"])
    }

    func testRemainingEveningsAreOfferedAfterAnOvernight() {
        // 1,800 miles in 36 hours. An overnight at mile 400 consumes day 1.
        // Day 2 and day 3 still reach 6 PM, so both stay on the list.
        let ride = [leg(miles: 1_800, hours: 36)]
        let days = evenings(legs: ride, overnights: [400 * mile], departureHour: 8)
        XCTAssertEqual(days.map(\.dayNumber), [2, 3])
        XCTAssertEqual(days[0].dayStartDistance, 400 * mile, accuracy: 1)
        XCTAssertEqual(days[0].targetDistance, 900 * mile, accuracy: 1)
        XCTAssertEqual(days[1].dayStartDistance, 900 * mile, accuracy: 1)
        XCTAssertEqual(days[1].targetDistance, 1_400 * mile, accuracy: 1)
        XCTAssertEqual(days[0].departureMinutes, HotelAlongRoute.morningDepartureMinutes)
        XCTAssertEqual(days[1].departureMinutes, HotelAlongRoute.morningDepartureMinutes)
    }

    func testArrivalUsesRouteETAAndDetourIsDistanceFromTheLine() {
        let start = CLLocationCoordinate2D(latitude: 33, longitude: -82)
        let end = CLLocationCoordinate2D(latitude: 34, longitude: -82)
        let line = [start, end]
        let length = RouteGeometry.length(of: line)
        let mid = RouteGeometry.coordinate(atDistance: length / 2, alongPolylines: [line])
        XCTAssertNotNil(mid)
        let latitude = mid?.latitude ?? 33.5
        let lonScale = 111_320 * cos(latitude * .pi / 180)
        let east = CLLocationCoordinate2D(
            latitude: latitude,
            longitude: (mid?.longitude ?? -82) + (2 * mile) / lonScale
        )
        let legs = [FuelStopRidingTime.Leg(distanceMeters: length, expectedTravelTime: 2 * 3_600)]
        let measured = HotelAlongRoute.measurement(
            of: east,
            alongPolylines: [line],
            legs: legs,
            dayStartDistance: 0,
            departureMinutes: 8 * 60
        )
        XCTAssertNotNil(measured)
        XCTAssertEqual(measured?.detourMeters ?? 0, 2 * mile, accuracy: mile * 0.2)
        XCTAssertGreaterThan(measured?.detourMeters ?? 0, mile)
        XCTAssertLessThanOrEqual(abs((measured?.arrivalMinutes ?? 0) - 9 * 60), 2)
        let caption = HotelAlongRoute.arrivalCaption(
            arrivalMinutes: measured?.arrivalMinutes ?? 0,
            detourMeters: measured?.detourMeters ?? 0,
            fartherOff: false,
            usesMetric: false
        )
        XCTAssertFalse(caption.contains("6:00 PM"))
        XCTAssertFalse(caption.contains("0 mi"))
        XCTAssertTrue(caption.contains("AM"), caption)
        XCTAssertEqual(
            HotelAlongRoute.formatDetour(0.4 * mile, usesMetric: false),
            "0.4 mi"
        )
        XCTAssertNil(HotelAlongRoute.measurement(
            of: east,
            alongPolylines: [],
            legs: legs,
            dayStartDistance: 0,
            departureMinutes: 8 * 60
        ))
    }

    func testOvernightReplanKeepsFuelStopsBeforeTheHotel() {
        let stations = stride(from: 20_000.0, through: 480_000.0, by: 20_000.0).map { meters in
            SuggestedStop(
                name: "Gas @\(Int(meters))",
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                category: .gas,
                distanceAlongRoute: meters
            )
        }
        let (stops, hasGap) = RoutePlannerViewModel.planFuelStopsPerLeg(
            from: stations,
            totalDistance: 500_000,
            range: 100_000,
            overnightDistances: [300_000]
        )
        XCTAssertFalse(hasGap)
        let marks = stops.map { Int($0.distanceAlongRoute) }
        XCTAssertTrue(marks.contains(80_000), "stops before the hotel were dropped: \(marks)")
        XCTAssertTrue(marks.contains(160_000))
        XCTAssertTrue(marks.contains(240_000))
        XCTAssertTrue(marks.contains { $0 > 300_000 }, "no fuel was planned after the hotel: \(marks)")
        let previous = marks.filter { $0 < 300_000 }.max() ?? 0
        XCTAssertLessThanOrEqual(300_000 - previous, 100_000)

        // Starting the whole ride at the hotel's mile mark is what hid those pumps.
        let (afterOnly, _) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 500_000,
            range: 100_000,
            filledAt: [300_000]
        )
        XCTAssertFalse(afterOnly.contains { Int($0.distanceAlongRoute) < 300_000 })
    }

    func testSharedRouteRoundTripsOvernightAndLegacyRidesStayOneDay() throws {
        var hotel = Waypoint(
            name: "Trail Inn",
            coordinate: CLLocationCoordinate2D(latitude: 33.5, longitude: -81.5)
        )
        hotel.isOvernight = true
        let route = SharedRoute(waypoints: [
            Waypoint(name: "Start", coordinate: CLLocationCoordinate2D(latitude: 33, longitude: -82)),
            hotel,
            Waypoint(name: "End", coordinate: CLLocationCoordinate2D(latitude: 34, longitude: -81)),
        ])
        let decoded = try JSONDecoder().decode(SharedRoute.self, from: JSONEncoder().encode(route))
        XCTAssertEqual(decoded.waypoints.map(\.isOvernight), [false, true, false])
        XCTAssertEqual(decoded.stops.map(\.isGasFill), [false, false, false])

        let legacy = Data(#"{"stops":[{"name":"Home","latitude":33.0,"longitude":-82.0}],"suggestions":[]}"#.utf8)
        let old = try JSONDecoder().decode(SharedRoute.self, from: legacy)
        XCTAssertFalse(old.waypoints[0].isOvernight)
        XCTAssertFalse(old.stops[0].isGasFill)
    }
}
