import XCTest
@testable import PerfectRouter

/// The first-launch safety notice (LaunchPlan v1 scope) is shown once per
/// wording version, including to riders who finished first-run earlier.
final class SafetyNoticeTests: XCTestCase {

    private let key = AppSettings.Keys.acknowledgedSafetyNoticeVersion
    private var previous: Any?

    override func setUp() {
        super.setUp()
        previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let previous {
            UserDefaults.standard.set(previous, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testFreshInstallNeedsTheNotice() {
        XCTAssertTrue(AppSettings.needsSafetyNotice)
    }

    func testAcknowledgingHidesItOnLaterLaunches() {
        AppSettings.acknowledgeSafetyNotice()
        XCTAssertFalse(AppSettings.needsSafetyNotice)
    }

    /// A rider who finished first-run on build 15 has never acknowledged.
    func testEarlierFirstRunDoesNotCountAsAcknowledged() {
        let firstRun = UserDefaults.standard.object(forKey: AppSettings.Keys.hasCompletedFirstRun)
        defer { UserDefaults.standard.set(firstRun, forKey: AppSettings.Keys.hasCompletedFirstRun) }
        AppSettings.completeFirstRun()
        XCTAssertTrue(AppSettings.needsSafetyNotice)
    }

    /// New wording: an older acknowledgment no longer counts.
    func testOlderAcknowledgmentShowsItAgain() {
        UserDefaults.standard.set(AppSettings.safetyNoticeVersion - 1, forKey: key)
        XCTAssertTrue(AppSettings.needsSafetyNotice)
    }

    /// The three points the launch plan names.
    func testNoticeCoversTheLaunchPlanPoints() {
        let titles = SafetyNoticeView.points.map(\.title)
        XCTAssertEqual(titles, [
            "Plan before you ride",
            "Don't handle your phone while riding",
            "Fuel and lodging are estimates",
        ])
    }
}
