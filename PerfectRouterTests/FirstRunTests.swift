import XCTest
@testable import PerfectRouter

/// AC-S2: first-run writes the existing Settings tank key, marks a
/// UserDefaults flag so returning riders skip the intro, and `applySettings`
/// can seed the planner from that key.
@MainActor
final class FirstRunTests: XCTestCase {

    private var previousFuel: Any?
    private var previousFlag: Any?

    override func setUp() {
        super.setUp()
        previousFuel = UserDefaults.standard.object(forKey: AppSettings.Keys.defaultFuelRangeMiles)
        previousFlag = UserDefaults.standard.object(forKey: AppSettings.Keys.hasCompletedFirstRun)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.defaultFuelRangeMiles)
        UserDefaults.standard.removeObject(forKey: AppSettings.Keys.hasCompletedFirstRun)
        AppSettings.registerDefaults()
    }

    override func tearDown() {
        restore(previousFuel, key: AppSettings.Keys.defaultFuelRangeMiles)
        restore(previousFlag, key: AppSettings.Keys.hasCompletedFirstRun)
        super.tearDown()
    }

    private func restore(_ value: Any?, key: String) {
        if let value {
            UserDefaults.standard.set(value, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func testFreshInstallHasNotCompletedFirstRun() {
        XCTAssertFalse(AppSettings.hasCompletedFirstRun)
    }

    func testStartPlanningWritesTankAndMarksDone() {
        AppSettings.completeFirstRun(savingTankMiles: 160)

        XCTAssertTrue(AppSettings.hasCompletedFirstRun)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: AppSettings.Keys.defaultFuelRangeMiles),
            160,
            accuracy: 0.001
        )
        XCTAssertEqual(AppSettings.defaultFuelRangeMeters, 160 * AppSettings.metersPerMile, accuracy: 1)
    }

    func testSetUpLaterMarksDoneWithoutChangingTank() {
        UserDefaults.standard.set(100.0, forKey: AppSettings.Keys.defaultFuelRangeMiles)

        AppSettings.completeFirstRun()

        XCTAssertTrue(AppSettings.hasCompletedFirstRun)
        XCTAssertEqual(
            UserDefaults.standard.double(forKey: AppSettings.Keys.defaultFuelRangeMiles),
            100,
            accuracy: 0.001
        )
    }

    func testApplySettingsSeedsFuelRangeOnlyWhenAsked() {
        UserDefaults.standard.set(180.0, forKey: AppSettings.Keys.defaultFuelRangeMiles)
        let viewModel = RoutePlannerViewModel()
        viewModel.fuelRangeMeters = 50 * AppSettings.metersPerMile

        viewModel.applySettings()
        XCTAssertEqual(viewModel.fuelRangeMeters, 50 * AppSettings.metersPerMile, accuracy: 1)

        viewModel.applySettings(seedFuelRange: true)
        XCTAssertEqual(viewModel.fuelRangeMeters, 180 * AppSettings.metersPerMile, accuracy: 1)
    }
}
