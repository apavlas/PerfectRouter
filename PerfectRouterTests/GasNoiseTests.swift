import XCTest
@testable import PerfectRouter

/// AC-P2: gray gas pins follow the "All gas on route" disclosure, and the
/// Gas chip does not get a second station list (gate stays on the view).
@MainActor
final class GasNoiseTests: XCTestCase {

    func testGrayGasPinsStayOffUntilFullListIsOpen() {
        let viewModel = RoutePlannerViewModel()
        viewModel.selectedCategory = .food
        XCTAssertFalse(viewModel.showsAllGasPins)

        viewModel.isShowingAllGasOnRoute = true
        XCTAssertTrue(viewModel.showsAllGasPins)
    }

    func testGasCategoryNeverShowsExtraGrayPins() {
        let viewModel = RoutePlannerViewModel()
        viewModel.selectedCategory = .gas
        viewModel.isShowingAllGasOnRoute = true
        XCTAssertFalse(viewModel.showsAllGasPins)
    }
}
