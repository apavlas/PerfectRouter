import XCTest
@testable import PerfectRouter

/// AC-P3: Route Style footers stay honest. Scenic is Apple avoid-highways /
/// avoid-tolls + an alternate — not twisty back-road routing.
final class RouteStyleTests: XCTestCase {

    func testScenicDetailDoesNotOverclaimTwistyRouting() {
        let detail = RouteStyle.scenic.detail
        XCTAssertTrue(detail.contains("Avoids highways and tolls"))
        XCTAssertTrue(detail.contains("not true twisty routing"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("quiet back roads"))
        XCTAssertFalse(detail.localizedCaseInsensitiveContains("twisty road"))
    }

    func testFastestAndAvoidHighwaysFootersStayAccurate() {
        XCTAssertEqual(RouteStyle.fastest.detail, "The quickest route, highways included.")
        XCTAssertEqual(RouteStyle.avoidHighways.detail, "Stays off highways where possible.")
        XCTAssertFalse(RouteStyle.fastest.detail.localizedCaseInsensitiveContains("quiet back roads"))
        XCTAssertFalse(RouteStyle.avoidHighways.detail.localizedCaseInsensitiveContains("quiet back roads"))
    }

    func testScenicCopyDoesNotMarketCurvyRoads() {
        let detail = RouteStyle.scenic.detail.lowercased()
        XCTAssertFalse(detail.contains("curvy"))
        XCTAssertFalse(detail.contains("more curves"))
        // The only "twisty" wording on Scenic is the existing negation.
        XCTAssertTrue(detail.contains("not true twisty routing"))
    }

    func testTwistyIsADistinctStyleThatOptimizesForCurves() {
        XCTAssertEqual(RouteStyle.twisty.rawValue, "Twisty")
        XCTAssertEqual(RouteStyle.allCases, [.fastest, .avoidHighways, .scenic, .twisty])
        XCTAssertEqual(
            RouteStyle.twisty.detail,
            "Biases the route toward roads with more curves than the fastest option."
        )
        let detail = RouteStyle.twisty.detail.lowercased()
        XCTAssertTrue(detail.contains("curve"))
        XCTAssertFalse(detail.contains("track"))
        XCTAssertFalse(detail.contains("rac"))

        // Not a relabel of Scenic or Avoid Highways.
        XCTAssertFalse(RouteStyle.twisty.avoidsHighways)
        XCTAssertFalse(RouteStyle.twisty.avoidsTolls)
        XCTAssertFalse(RouteStyle.twisty.prefersAlternates)
        XCTAssertTrue(RouteStyle.scenic.avoidsHighways)
        XCTAssertTrue(RouteStyle.scenic.avoidsTolls)
        XCTAssertTrue(RouteStyle.scenic.prefersAlternates)
        XCTAssertTrue(RouteStyle.avoidHighways.avoidsHighways)
        XCTAssertFalse(RouteStyle.avoidHighways.avoidsTolls)
        XCTAssertFalse(RouteStyle.avoidHighways.prefersAlternates)
    }

    func testTwistyLimitationNoteAdmitsWhenTheLineMatchesFastest() {
        XCTAssertNil(RoutePlannerViewModel.twistyLimitationNote(missedLegs: 0, totalLegs: 2))
        XCTAssertEqual(
            RoutePlannerViewModel.twistyLimitationNote(missedLegs: 2, totalLegs: 2),
            "MapKit didn't offer a curvier corridor between these stops, so this line matches Fastest."
        )
        let partial = RoutePlannerViewModel.twistyLimitationNote(missedLegs: 1, totalLegs: 3)
        XCTAssertEqual(
            partial,
            "Part of this ride stayed on the fastest roads — MapKit didn't offer a curvier corridor there."
        )
    }
}
