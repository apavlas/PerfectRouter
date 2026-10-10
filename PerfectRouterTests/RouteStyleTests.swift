import CoreLocation
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
            "No twistier roads found on this route"
        )
        XCTAssertNotEqual(
            RoutePlannerViewModel.twistyLimitationNote(missedLegs: 1, totalLegs: 3),
            "No twistier roads found on this route"
        )
        let partial = RoutePlannerViewModel.twistyLimitationNote(missedLegs: 1, totalLegs: 3)
        XCTAssertEqual(
            partial,
            "Part of this ride stayed on the fastest roads — MapKit didn't offer a curvier corridor there."
        )
    }

    func testStyleChangeRestartsTheRouteOnce() {
        XCTAssertEqual(
            RoutePlannerViewModel.styleChangeRestart(from: .fastest, to: .twisty),
            .route
        )
        XCTAssertEqual(
            RoutePlannerViewModel.styleChangeRestart(from: .twisty, to: .scenic),
            .route
        )
        XCTAssertEqual(
            RoutePlannerViewModel.styleChangeRestart(from: .scenic, to: .avoidHighways),
            .route
        )
        XCTAssertNil(RoutePlannerViewModel.styleChangeRestart(from: .fastest, to: .fastest))

        // Switching again mid-run cancels the earlier generation. Only the
        // latest one publishes, so a burst of changes is one restart.
        let latest = 3
        let commits = (1...latest).filter { generation in
            RoutePlannerViewModel.shouldPublishRoute(
                generation: generation,
                latestGeneration: latest,
                cancelled: generation != latest
            )
        }
        XCTAssertEqual(commits, [latest])
        XCTAssertFalse(RoutePlannerViewModel.shouldPublishRoute(
            generation: latest,
            latestGeneration: latest,
            cancelled: true
        ))
    }

    func testLegCacheIsKeyedByStyle() {
        let start = CLLocationCoordinate2D(latitude: 33.47, longitude: -82.01)
        let end = CLLocationCoordinate2D(latitude: 34.05, longitude: -83.25)
        let departure = Date(timeIntervalSince1970: 1_700_000_000)
        let keys = RouteStyle.allCases.map {
            TwistyRouting.legCacheKey(from: start, to: end, style: $0, departure: departure)
        }
        XCTAssertEqual(Set(keys.map(\.style)), Set(RouteStyle.allCases.map(\.rawValue)))
        XCTAssertEqual(Set(keys).count, RouteStyle.allCases.count)
    }

    func testPublishedSummaryUsesTheNewStyleTotals() {
        let previous = RoutePlannerViewModel.rideSummaryTotals(
            distances: [160_934],
            times: [7_200]
        )
        let incoming = RoutePlannerViewModel.rideSummaryTotals(
            distances: [210_000],
            times: [9_000]
        )
        XCTAssertEqual(previous.distance, 160_934)
        XCTAssertEqual(previous.time, 7_200)

        let superseded = RoutePlannerViewModel.shouldPublishRoute(
            generation: 1,
            latestGeneration: 2,
            cancelled: true
        )
        XCTAssertFalse(superseded)
        let kept = superseded ? incoming : previous
        XCTAssertEqual(kept.distance, previous.distance)
        XCTAssertEqual(kept.time, previous.time)

        let committed = RoutePlannerViewModel.shouldPublishRoute(
            generation: 2,
            latestGeneration: 2,
            cancelled: false
        )
        XCTAssertTrue(committed)
        let shown = committed ? incoming : previous
        XCTAssertEqual(shown.distance, incoming.distance)
        XCTAssertEqual(shown.time, incoming.time)
        XCTAssertNotEqual(shown.distance, previous.distance)
        XCTAssertNotEqual(shown.time, previous.time)
    }

    func testReplanFeedbackIsImmediateAndProgressWaits() {
        XCTAssertEqual(
            RoutePlannerViewModel.routeReplanStatus(style: .twisty),
            "Replanning for Twisty…"
        )
        XCTAssertEqual(
            RoutePlannerViewModel.routeReplanStatus(style: .scenic),
            "Replanning for Scenic…"
        )
        XCTAssertEqual(
            RoutePlannerViewModel.routeReplanStatus(style: .fastest),
            "Replanning for Fastest…"
        )
        XCTAssertTrue(RoutePlannerViewModel.shouldDimExistingLine(isCalculating: true, hasLegs: true))
        XCTAssertFalse(RoutePlannerViewModel.shouldDimExistingLine(isCalculating: true, hasLegs: false))
        XCTAssertFalse(RoutePlannerViewModel.shouldDimExistingLine(isCalculating: false, hasLegs: true))
        XCTAssertEqual(RoutePlannerViewModel.replanProgressDelay, .seconds(10))
        XCTAssertFalse(RoutePlannerViewModel.shouldShowReplanProgress(elapsed: .seconds(9)))
        XCTAssertTrue(RoutePlannerViewModel.shouldShowReplanProgress(elapsed: .seconds(10)))
    }

    func testMapReplanBannerShowsOnlyWhileALineIsBeingReplaced() {
        XCTAssertTrue(RoutePlannerViewModel.showsMapReplanBanner(isCalculating: true, hasLegs: true))
        XCTAssertFalse(RoutePlannerViewModel.showsMapReplanBanner(isCalculating: true, hasLegs: false))
        XCTAssertFalse(RoutePlannerViewModel.showsMapReplanBanner(isCalculating: false, hasLegs: true))
        XCTAssertFalse(RoutePlannerViewModel.showsMapReplanBanner(isCalculating: false, hasLegs: false))
        for style in RouteStyle.allCases {
            XCTAssertEqual(
                RoutePlannerViewModel.routeReplanStatus(style: style),
                "Replanning for \(style.rawValue)…"
            )
        }
    }
}
