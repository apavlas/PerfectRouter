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
}
