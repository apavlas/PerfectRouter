import CoreLocation
import XCTest
@testable import PerfectRouter

/// Drive time shown on fuel-stop rows. Per-leg `expectedTravelTime` is spread
/// along that leg's polyline. Stop dwell is not included. Formatting covers
/// under an hour, over a day, and nearest-minute rounding.
final class FuelStopRidingTimeTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    private func leg(_ meters: CLLocationDistance, seconds: TimeInterval) -> FuelStopRidingTime.Leg {
        FuelStopRidingTime.Leg(distanceMeters: meters, expectedTravelTime: seconds)
    }

    // MARK: - Per-leg pace

    func testMultiLegTimeUsesEachLegsPaceNotAFlatAverage() {
        // Leg 1 is slow (2 h), leg 2 is fast (30 min), same geographic length.
        let leg1Line = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
        ]
        let leg2Line = [
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
            CLLocationCoordinate2D(latitude: 0, longitude: 2),
        ]
        let slow = 7_200.0
        let fast = 1_800.0
        let legs = [
            FuelStopRidingTime.leg(polyline: leg1Line, expectedTravelTime: slow),
            FuelStopRidingTime.leg(polyline: leg2Line, expectedTravelTime: fast),
        ]
        let leg1Length = RouteGeometry.length(of: leg1Line)
        let totalLength = leg1Length + RouteGeometry.length(of: leg2Line)
        let midSecond = CLLocationCoordinate2D(latitude: 0, longitude: 1.5)
        let midDistance = RouteGeometry.distanceAlongRoute(
            of: midSecond,
            alongPolylines: [leg1Line, leg2Line]
        )
        let endDistance = RouteGeometry.distanceAlongRoute(
            of: leg2Line[1],
            alongPolylines: [leg1Line, leg2Line]
        )

        let atFirst = FuelStopRidingTime.clock(
            at: leg1Length,
            anchors: [leg1Length, midDistance, endDistance],
            legs: legs
        )
        XCTAssertEqual(atFirst.cumulative, slow, accuracy: 1)
        XCTAssertEqual(atFirst.sincePrevious, slow, accuracy: 1)
        XCTAssertTrue(atFirst.sinceDeparture)

        let atMid = FuelStopRidingTime.clock(
            at: midDistance,
            anchors: [leg1Length, midDistance, endDistance],
            legs: legs
        )
        // Halfway along the fast leg, not halfway along the whole ride.
        XCTAssertEqual(atMid.cumulative, slow + fast * 0.5, accuracy: 1)
        XCTAssertEqual(atMid.sincePrevious, fast * 0.5, accuracy: 1)
        XCTAssertFalse(atMid.sinceDeparture)

        let atEnd = FuelStopRidingTime.clock(
            at: endDistance,
            anchors: [leg1Length, midDistance, endDistance],
            legs: legs
        )
        XCTAssertEqual(atEnd.cumulative, slow + fast, accuracy: 1)
        XCTAssertEqual(atEnd.sincePrevious, fast * 0.5, accuracy: 1)
        XCTAssertFalse(atEnd.sinceDeparture)

        let flatAtMid = (slow + fast) * (midDistance / totalLength)
        XCTAssertEqual(flatAtMid, (slow + fast) * 0.75, accuracy: 1)
        XCTAssertGreaterThan(atMid.cumulative - flatAtMid, 1_000)
    }

    func testPolylineFractionUsesSegmentLengthNotVertexIndex() {
        // The middle vertex is only 20% of the way along the line.
        let polyline = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.2),
            CLLocationCoordinate2D(latitude: 0, longitude: 1),
        ]
        let timing = FuelStopRidingTime.leg(polyline: polyline, expectedTravelTime: 10_000)
        let full = RouteGeometry.length(of: polyline)
        let prefix = RouteGeometry.length(of: [polyline[0], polyline[1]])
        let stop = RouteGeometry.distanceAlongRoute(
            of: polyline[1],
            alongPolylines: [polyline]
        )
        XCTAssertEqual(stop, prefix, accuracy: 1)
        XCTAssertEqual(timing.distanceMeters, full, accuracy: 1)

        let time = FuelStopRidingTime.ridingTime(atDistance: stop, legs: [timing])
        XCTAssertEqual(time, 10_000 * (prefix / full), accuracy: 1)
        XCTAssertGreaterThan(abs(time - 5_000), 1_000)
    }

    func testStopAtEndOfRouteGetsTheFullLegTime() {
        let line = [
            CLLocationCoordinate2D(latitude: 0, longitude: 0),
            CLLocationCoordinate2D(latitude: 0, longitude: 0.4),
            CLLocationCoordinate2D(latitude: 0, longitude: 1.1),
        ]
        let end = RouteGeometry.distanceAlongRoute(of: line[2], alongPolylines: [line])
        XCTAssertEqual(end, RouteGeometry.length(of: line), accuracy: 0.01)
        let timing = FuelStopRidingTime.leg(polyline: line, expectedTravelTime: 5_000)
        XCTAssertEqual(
            FuelStopRidingTime.ridingTime(atDistance: end, legs: [timing]),
            5_000,
            accuracy: 0.01
        )
    }

    func testStopBeyondTheRouteClampsToTotalDriveTime() {
        let time = FuelStopRidingTime.ridingTime(
            atDistance: 500_000,
            legs: [leg(100_000, seconds: 3_600)]
        )
        XCTAssertEqual(time, 3_600, accuracy: 0.001)
    }

    func testEmptyRouteIsZeroRidingTime() {
        XCTAssertEqual(FuelStopRidingTime.ridingTime(atDistance: 1_000, legs: []), 0, accuracy: 0.001)
    }

    /// A zero-length leg is time spent at a point. It must not show up in
    /// the cumulative time or in the gap since the previous stop.
    func testSinceLastExcludesStopDwellBetweenLegs() {
        let legs = [
            leg(100_000, seconds: 3_600),
            leg(0, seconds: 900),
            leg(100_000, seconds: 3_600),
        ]
        let first = FuelStopRidingTime.clock(at: 100_000, anchors: [100_000, 200_000], legs: legs)
        let second = FuelStopRidingTime.clock(at: 200_000, anchors: [100_000, 200_000], legs: legs)
        XCTAssertEqual(first.cumulative, 3_600, accuracy: 0.001)
        XCTAssertTrue(first.sinceDeparture)
        XCTAssertEqual(second.cumulative, 7_200, accuracy: 0.001)
        XCTAssertEqual(second.sincePrevious, 3_600, accuracy: 0.001)
        XCTAssertFalse(second.sinceDeparture)
    }

    func testEarlierAnchorWinsWhenAnchorsAreUnsorted() {
        let legs = [leg(300_000, seconds: 9_000)]
        let reading = FuelStopRidingTime.clock(
            at: 120_000,
            anchors: [200_000, 50_000, 120_000],
            legs: legs
        )
        XCTAssertEqual(reading.cumulative, 3_600, accuracy: 0.001)
        XCTAssertEqual(reading.sincePrevious, 2_100, accuracy: 0.001)
        XCTAssertFalse(reading.sinceDeparture)
    }

    func testAnchorWithinToleranceDoesNotCountAsPreviousStop() {
        let stop = 100_000.0
        let legs = [leg(stop, seconds: 3_600)]
        let samePlace = FuelStopRidingTime.clock(
            at: stop,
            anchors: [stop - 40, stop],
            legs: legs
        )
        XCTAssertTrue(samePlace.sinceDeparture)
        XCTAssertEqual(samePlace.sincePrevious, 3_600, accuracy: 0.001)

        let previousFill = FuelStopRidingTime.clock(
            at: stop,
            anchors: [stop - 1_000, stop],
            legs: legs
        )
        XCTAssertFalse(previousFill.sinceDeparture)
        XCTAssertEqual(previousFill.cumulative, 3_600, accuracy: 0.001)
        XCTAssertEqual(previousFill.sincePrevious, 36, accuracy: 0.5)
    }

    // MARK: - Caption

    func testCaptionPutsMilesBeforeRidingTime() {
        let leg1 = 162 * mile
        let leg2 = 50 * mile
        let legs = [
            leg(leg1, seconds: 4 * 3_600 + 25 * 60),
            leg(leg2, seconds: 1 * 3_600 + 40 * 60),
        ]
        let distance = leg1 + leg2
        let first = FuelStopRidingTime.caption(
            distanceMeters: leg1,
            anchors: [leg1, distance],
            legs: legs,
            usesMetric: false
        )
        let second = FuelStopRidingTime.caption(
            distanceMeters: distance,
            anchors: [leg1, distance],
            legs: legs,
            usesMetric: false
        )
        XCTAssertEqual(first, "162 mi · 4h 25m riding (4h 25m since departure)")
        XCTAssertEqual(second, "212 mi · 6h 05m riding (1h 40m since last)")
    }

    func testCaptionUnderOneHourSaysSinceDeparture() {
        let distance = 40 * mile
        let caption = FuelStopRidingTime.caption(
            distanceMeters: distance,
            anchors: [distance],
            legs: [leg(distance, seconds: 45 * 60)],
            usesMetric: false
        )
        XCTAssertEqual(caption, "40 mi · 45m riding (45m since departure)")
    }

    func testCaptionOverTwentyFourHoursStaysInHours() {
        let leg1 = 100 * mile
        let leg2 = 50 * mile
        let caption = FuelStopRidingTime.caption(
            distanceMeters: leg1 + leg2,
            anchors: [leg1, leg1 + leg2],
            legs: [
                leg(leg1, seconds: 24 * 3_600),
                leg(leg2, seconds: 1 * 3_600 + 5 * 60),
            ],
            usesMetric: false
        )
        XCTAssertEqual(caption, "150 mi · 25h 05m riding (1h 05m since last)")
    }

    func testCaptionUsesKilometersWhenMetric() {
        let caption = FuelStopRidingTime.caption(
            distanceMeters: 212_000,
            anchors: [],
            legs: [leg(212_000, seconds: 45 * 60)],
            usesMetric: true
        )
        XCTAssertEqual(caption, "212 km · 45m riding (45m since departure)")
    }

    // MARK: - Rounding

    func testFormatsUnderOneHourWithoutAnHourComponent() {
        XCTAssertEqual(FuelStopRidingTime.formatDuration(0), "0m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(40 * 60), "40m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(59.4 * 60), "59m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(-30), "0m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(.nan), "0m")
    }

    func testRoundsToNearestMinute() {
        XCTAssertEqual(FuelStopRidingTime.formatDuration(29), "0m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(30), "1m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(6 * 3_600 + 4 * 60 + 29), "6h 04m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(6 * 3_600 + 4 * 60 + 30), "6h 05m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(59.5 * 60), "1h 00m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(100 * 60), "1h 40m")
    }

    func testFormatsPastTwentyFourHoursInHours() {
        XCTAssertEqual(FuelStopRidingTime.formatDuration(24 * 3_600), "24h 00m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(24 * 3_600 + 90), "24h 02m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(25 * 3_600 + 5 * 60), "25h 05m")
        XCTAssertEqual(FuelStopRidingTime.formatDuration(26 * 3_600), "26h 00m")
    }

    func testDistanceRoundsToTheNearestMile() {
        XCTAssertEqual(
            FuelStopRidingTime.formatDistance(212 * mile, usesMetric: false),
            "212 mi"
        )
        XCTAssertEqual(
            FuelStopRidingTime.formatDistance(211.5 * mile, usesMetric: false),
            "212 mi"
        )
        XCTAssertEqual(
            FuelStopRidingTime.formatDistance(211.4 * mile, usesMetric: false),
            "211 mi"
        )
        XCTAssertEqual(FuelStopRidingTime.formatDistance(212_000, usesMetric: true), "212 km")
    }
}
