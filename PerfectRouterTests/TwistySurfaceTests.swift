import CoreLocation
import XCTest
@testable import PerfectRouter

/// Twisty must not pick a line that rides into a dead end and back, and by
/// default must not pick one Apple flags as unpaved.
final class TwistySurfaceTests: XCTestCase {

    private let metersPerDegreeLongitude = 111_320.0
    private let metersPerDegreeLatitude = 110_540.0

    // MARK: - Dead-end spurs

    func testStraightLineHasNoSpur() {
        XCTAssertEqual(TwistyRouting.longestDeadEndSpurMeters(eastLine(meters: 10_000)), 0)
    }

    func testOutAndBackSpurIsMeasured() {
        let spur = TwistyRouting.longestDeadEndSpurMeters(lineWithSpur(spurMeters: 1_200))
        XCTAssertGreaterThan(spur, 1_100)
        XCTAssertLessThan(spur, 1_300)
    }

    func testHairpinIsNotASpur() {
        XCTAssertLessThan(
            TwistyRouting.longestDeadEndSpurMeters(hairpin()),
            TwistyRouting.maximumDeadEndSpurMeters
        )
    }

    func testCandidateWithDeadEndSpurIsSkipped() {
        let fastest = eastLine(meters: 10_000)
        // The spur adds two 90° turns and a 180° reversal, so on curvature
        // alone it beats Fastest. It must still lose.
        let spurred = lineWithSpur(spurMeters: 1_500, northOffsetMeters: 1_000)
        let selection = TwistyRouting.select(
            candidates: [
                TwistyRouteCandidate(id: 0, coordinates: fastest, distance: TwistyRouting.pathLength(fastest)),
                TwistyRouteCandidate(id: 1, coordinates: spurred, distance: TwistyRouting.pathLength(spurred)),
            ],
            fastestID: 0
        )
        XCTAssertNil(selection)
    }

    // MARK: - Unpaved

    func testUnpavedNoticeIsRecognized() {
        XCTAssertTrue(TwistyRouting.mentionsUnpavedRoad(["Route includes unpaved roads"]))
        XCTAssertTrue(TwistyRouting.mentionsUnpavedRoad(["Gravel road ahead"]))
        XCTAssertFalse(TwistyRouting.mentionsUnpavedRoad(["Route has tolls"]))
        XCTAssertFalse(TwistyRouting.mentionsUnpavedRoad([]))
    }

    func testPavedOnlySkipsUnpavedCandidateButAnySurfaceKeepsIt() {
        let fastest = eastLine(meters: 30_000)
        let curvy = zigzag()
        let candidates = [
            TwistyRouteCandidate(id: 0, coordinates: fastest, distance: TwistyRouting.pathLength(fastest)),
            TwistyRouteCandidate(
                id: 1,
                coordinates: curvy,
                distance: TwistyRouting.pathLength(curvy),
                mentionsUnpavedRoad: true
            ),
        ]
        XCTAssertNil(TwistyRouting.select(candidates: candidates, fastestID: 0))
        XCTAssertEqual(
            TwistyRouting.select(candidates: candidates, fastestID: 0, pavedOnly: false)?.candidateID,
            1
        )
    }

    func testPavedOnlyIsOnByDefault() {
        XCTAssertTrue(AppSettings.twistyPavedOnlyDefault)
    }

    func testCacheKeySeparatesSurfaceRuleForTwistyOnly() {
        let a = CLLocationCoordinate2D(latitude: 37, longitude: -122)
        let b = CLLocationCoordinate2D(latitude: 37.3, longitude: -122.2)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertNotEqual(
            TwistyRouting.legCacheKey(from: a, to: b, style: .twisty, departure: now, pavedOnly: true),
            TwistyRouting.legCacheKey(from: a, to: b, style: .twisty, departure: now, pavedOnly: false)
        )
        XCTAssertEqual(
            TwistyRouting.legCacheKey(from: a, to: b, style: .fastest, departure: now, pavedOnly: true),
            TwistyRouting.legCacheKey(from: a, to: b, style: .fastest, departure: now, pavedOnly: false)
        )
    }

    // MARK: - Shapes

    private func point(eastMeters: Double, northMeters: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: northMeters / metersPerDegreeLatitude,
            longitude: eastMeters / metersPerDegreeLongitude
        )
    }

    private func eastLine(meters: Double) -> [CLLocationCoordinate2D] {
        stride(from: 0.0, through: meters, by: 500).map { point(eastMeters: $0, northMeters: 0) }
    }

    /// East along a road that sits `northOffsetMeters` north of the fast line,
    /// with a dead-end spur north at the middle that is ridden out and back.
    private func lineWithSpur(
        spurMeters: Double,
        northOffsetMeters: Double = 0
    ) -> [CLLocationCoordinate2D] {
        let y = northOffsetMeters
        var points = [point(eastMeters: 0, northMeters: 0)]
        if y > 0 { points.append(point(eastMeters: 0, northMeters: y)) }
        points.append(point(eastMeters: 5_000, northMeters: y))
        points.append(point(eastMeters: 5_000, northMeters: y + spurMeters))
        points.append(point(eastMeters: 5_000, northMeters: y))
        points.append(point(eastMeters: 10_000, northMeters: y))
        if y > 0 { points.append(point(eastMeters: 10_000, northMeters: 0)) }
        return points
    }

    /// A 15 m radius hairpin whose two legs run 30 m apart, then a climb away.
    private func hairpin() -> [CLLocationCoordinate2D] {
        var points = [point(eastMeters: 0, northMeters: 0), point(eastMeters: 500, northMeters: 0)]
        for step in 1..<20 {
            let angle = Double.pi * Double(step) / 20
            points.append(point(eastMeters: 500 + 15 * sin(angle), northMeters: 15 - 15 * cos(angle)))
        }
        points.append(point(eastMeters: 500, northMeters: 30))
        points.append(point(eastMeters: 0, northMeters: 30))
        points.append(point(eastMeters: 0, northMeters: 530))
        return points
    }

    /// Square-wave road across 30 km, 1 to 1.5 km north of the fast line.
    private func zigzag() -> [CLLocationCoordinate2D] {
        var points = [point(eastMeters: 0, northMeters: 0)]
        var north = 1_000.0
        for east in stride(from: 1_500.0, through: 28_500, by: 1_500) {
            points.append(point(eastMeters: east - 1_500, northMeters: north))
            points.append(point(eastMeters: east, northMeters: north))
            north = north == 1_000 ? 1_500 : 1_000
        }
        points.append(point(eastMeters: 30_000, northMeters: 0))
        return points
    }
}
