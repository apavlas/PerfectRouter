import CoreLocation
import XCTest
@testable import PerfectRouter

/// AC-C1: Twisty selects a higher-curvature corridor. A longer, gentler bow
/// (the Scenic "pick the long one" outcome) does not win.
final class TwistyRoutingTests: XCTestCase {

    func testCurvierCorridorBeatsALongerGentleBow() {
        let snake = curvyCorridor()
        let bow = gentleBow(from: snake[0], to: snake[snake.count - 1], controlOffsetMeters: 18_000)
        let fastest = straight(from: snake[0], to: snake[snake.count - 1])

        let fastestLength = TwistyRouting.pathLength(fastest)
        let snakeLength = TwistyRouting.pathLength(snake)
        let bowLength = TwistyRouting.pathLength(bow)

        XCTAssertGreaterThan(bowLength, snakeLength, "The gentle bow is the longer detour")
        XCTAssertLessThan(bowLength, fastestLength * TwistyRouting.maximumDistanceFactor)
        XCTAssertLessThan(snakeLength, fastestLength * TwistyRouting.maximumDistanceFactor)
        XCTAssertLessThan(
            TwistyRouting.curvatureRadiansPerKilometer(bow),
            TwistyRouting.minimumCurvatureGainPerKilometer
        )
        XCTAssertGreaterThan(
            TwistyRouting.curvatureRadiansPerKilometer(snake),
            TwistyRouting.minimumCurvatureGainPerKilometer
        )

        let selection = TwistyRouting.select(
            candidates: [
                TwistyRouteCandidate(id: 0, coordinates: fastest, distance: fastestLength),
                TwistyRouteCandidate(id: 1, coordinates: bow, distance: bowLength),
                TwistyRouteCandidate(id: 2, coordinates: snake, distance: snakeLength),
            ],
            fastestID: 0
        )
        XCTAssertEqual(selection?.candidateID, 2)
        XCTAssertGreaterThan(
            (selection?.curvatureRadiansPerKilometer ?? 0)
                - (selection?.fastestCurvatureRadiansPerKilometer ?? 0),
            TwistyRouting.minimumCurvatureGainPerKilometer - 0.001
        )
        XCTAssertGreaterThan(
            selection?.corridorSeparationMeters ?? 0,
            TwistyRouting.minimumCorridorSeparationMeters
        )
    }

    func testGentleBowAloneIsNotTwisty() {
        let bowEndpoints = gentleArc()
        let fastest = straight(from: bowEndpoints[0], to: bowEndpoints[bowEndpoints.count - 1])
        let selection = TwistyRouting.select(
            candidates: [
                TwistyRouteCandidate(id: 0, coordinates: fastest, distance: TwistyRouting.pathLength(fastest)),
                TwistyRouteCandidate(id: 1, coordinates: bowEndpoints, distance: TwistyRouting.pathLength(bowEndpoints)),
            ],
            fastestID: 0
        )
        XCTAssertNil(selection)
        XCTAssertEqual(TwistyRouting.curvatureRadiansPerKilometer(bowEndpoints), 0, accuracy: 0.02)
        XCTAssertGreaterThan(
            TwistyRouting.corridorSeparationMeters(of: bowEndpoints, from: fastest),
            TwistyRouting.minimumCorridorSeparationMeters
        )
    }

    func testOverlongSnakeIsRejectedEvenWhenCurvier() {
        let snake = overlongSnake()
        let fastest = straight(from: snake[0], to: snake[snake.count - 1])
        XCTAssertGreaterThan(
            TwistyRouting.curvatureRadiansPerKilometer(snake),
            TwistyRouting.minimumCurvatureGainPerKilometer
        )
        XCTAssertGreaterThan(
            TwistyRouting.pathLength(snake),
            TwistyRouting.pathLength(fastest) * TwistyRouting.maximumDistanceFactor
        )
        XCTAssertNil(TwistyRouting.select(
            candidates: [
                TwistyRouteCandidate(id: 0, coordinates: fastest, distance: TwistyRouting.pathLength(fastest)),
                TwistyRouteCandidate(id: 1, coordinates: snake, distance: TwistyRouting.pathLength(snake)),
            ],
            fastestID: 0
        ))
    }

    func testStraightLineHasNoCurvature() {
        let line = straight(
            from: CLLocationCoordinate2D(latitude: 0, longitude: 0),
            to: CLLocationCoordinate2D(latitude: 0, longitude: 0.3)
        )
        XCTAssertEqual(TwistyRouting.curvatureRadiansPerKilometer(line), 0, accuracy: 0.001)
    }

    func testBiasCorridorsLeaveTheFastChordOnOppositeSides() {
        let start = CLLocationCoordinate2D(latitude: 33.5, longitude: -84.5)
        let end = CLLocationCoordinate2D(latitude: 33.5, longitude: -82.5)
        let corridors = TwistyRouting.biasCorridors(from: start, to: end)
        XCTAssertEqual(corridors.count, 2)
        XCTAssertEqual(corridors[0].vias.count, 2, "A long leg gets two same-side vias")
        XCTAssertEqual(corridors[1].vias.count, 2)

        let chord = [[start, end]]
        XCTAssertEqual(RouteGeometry.side(of: corridors[0].vias[0], alongPolylines: chord), .left)
        XCTAssertEqual(RouteGeometry.side(of: corridors[1].vias[0], alongPolylines: chord), .right)
        XCTAssertGreaterThan(corridors[0].vias[0].latitude, start.latitude)
        XCTAssertLessThan(corridors[1].vias[0].latitude, start.latitude)
        for via in corridors.flatMap(\.vias) {
            XCTAssertGreaterThan(
                RouteGeometry.distanceFromRoute(of: via, alongPolylines: chord),
                3_000
            )
        }
    }

    func testShortLegHasNoBiasCorridor() {
        let start = CLLocationCoordinate2D(latitude: 33.47, longitude: -82.01)
        let end = CLLocationCoordinate2D(latitude: 33.49, longitude: -82.00)
        XCTAssertTrue(TwistyRouting.biasCorridors(from: start, to: end).isEmpty)
    }

    func testFuelSplitSkipsTheViaCascade() {
        let plan = TwistyRouting.fetchPlan(straightMeters: 160_000, liesOnPlannedCorridor: true)
        XCTAssertFalse(plan.avoidHighwayAlternates)
        XCTAssertFalse(plan.offsetVias)
    }

    func testVeryLongFreshLegSkipsOffsetViasButKeepsAlternates() {
        let plan = TwistyRouting.fetchPlan(straightMeters: 1_600_000, liesOnPlannedCorridor: false)
        XCTAssertTrue(plan.avoidHighwayAlternates)
        XCTAssertFalse(plan.offsetVias)
    }

    func testFreshMediumLegProbesOffsetVias() {
        let plan = TwistyRouting.fetchPlan(straightMeters: 80_000, liesOnPlannedCorridor: false)
        XCTAssertTrue(plan.avoidHighwayAlternates)
        XCTAssertTrue(plan.offsetVias)
    }

    func testOriginalEndpointsAreNotTreatedAsACorridorSplit() {
        let start = CLLocationCoordinate2D(latitude: 33.0, longitude: -84.0)
        let end = CLLocationCoordinate2D(latitude: 33.0, longitude: -83.0)
        let onEnds = TwistyRouting.liesOnPlannedCorridor(
            from: start,
            to: end,
            polylines: [[start, end]]
        )
        XCTAssertFalse(onEnds)
        let mid = CLLocationCoordinate2D(latitude: 33.0, longitude: -83.5)
        let split = TwistyRouting.liesOnPlannedCorridor(
            from: start,
            to: mid,
            polylines: [[start, end]]
        )
        XCTAssertTrue(split)
    }

    func testLegCacheKeyIgnoresTinyCoordinateNoise() {
        let start = CLLocationCoordinate2D(latitude: 33.47351, longitude: -82.01051)
        let end = CLLocationCoordinate2D(latitude: 34.05, longitude: -83.25)
        let departure = Date(timeIntervalSince1970: 1_700_000_000)
        let first = TwistyRouting.legCacheKey(from: start, to: end, style: .twisty, departure: departure)
        let nudged = CLLocationCoordinate2D(latitude: 33.47354, longitude: -82.01054)
        let second = TwistyRouting.legCacheKey(from: nudged, to: end, style: .twisty, departure: departure)
        XCTAssertEqual(first, second)
        let otherStyle = TwistyRouting.legCacheKey(from: start, to: end, style: .fastest, departure: departure)
        XCTAssertNotEqual(first, otherStyle)
    }

    func testMediumLegUsesASingleViaPerSide() {
        let start = CLLocationCoordinate2D(latitude: 33.5, longitude: -84.0)
        let end = CLLocationCoordinate2D(latitude: 33.64, longitude: -84.0)
        let corridors = TwistyRouting.biasCorridors(from: start, to: end)
        XCTAssertEqual(corridors.count, 2)
        XCTAssertEqual(corridors[0].vias.count, 1)
        XCTAssertEqual(corridors[1].vias.count, 1)
    }

    // MARK: - Fixtures

    /// Same-side switchbacks. Shorter than `gentleBow` between the same
    /// endpoints, and much curvier.
    private func curvyCorridor() -> [CLLocationCoordinate2D] {
        var latitude = 0.0
        var longitude = 0.0
        var points = [CLLocationCoordinate2D(latitude: latitude, longitude: longitude)]
        for index in 0..<6 {
            longitude += 0.03
            points.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            latitude = index % 2 == 0 ? 0.018 : 0.009
            points.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        return points
    }

    /// Many tight reversals. Road distance is several times the chord.
    private func overlongSnake() -> [CLLocationCoordinate2D] {
        var latitude = 0.0
        var longitude = 0.0
        var points = [CLLocationCoordinate2D(latitude: latitude, longitude: longitude)]
        for index in 0..<12 {
            longitude += 0.01
            points.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
            latitude = index % 2 == 0 ? 0.02 : 0.0
            points.append(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        }
        return points
    }

    /// Large-radius arc: separated from its chord, almost no sharp turning.
    private func gentleArc() -> [CLLocationCoordinate2D] {
        let radius = 80_000.0
        let length = 40_000.0
        let sweep = length / radius
        let half = sweep / 2
        return (0...40).map { index in
            let angle = -half + sweep * Double(index) / 40
            let east = radius * sin(angle)
            let north = -radius * cos(angle) + radius * cos(half)
            return CLLocationCoordinate2D(
                latitude: north / 110_540,
                longitude: east / 111_320
            )
        }
    }

    /// Smooth bow through a control point north of the chord. Long, low curvature.
    private func gentleBow(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        controlOffsetMeters: CLLocationDistance
    ) -> [CLLocationCoordinate2D] {
        let control = CLLocationCoordinate2D(
            latitude: (start.latitude + end.latitude) / 2 + controlOffsetMeters / 110_540,
            longitude: (start.longitude + end.longitude) / 2
        )
        return (0...79).map { index in
            let t = Double(index) / 79
            let latitude = (1 - t) * (1 - t) * start.latitude
                + 2 * (1 - t) * t * control.latitude
                + t * t * end.latitude
            let longitude = (1 - t) * (1 - t) * start.longitude
                + 2 * (1 - t) * t * control.longitude
                + t * t * end.longitude
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    private func straight(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        steps: Int = 24
    ) -> [CLLocationCoordinate2D] {
        (0...steps).map { index in
            let t = Double(index) / Double(steps)
            return CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * t,
                longitude: start.longitude + (end.longitude - start.longitude) * t
            )
        }
    }
}
