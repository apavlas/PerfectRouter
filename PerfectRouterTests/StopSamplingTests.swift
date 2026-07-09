import XCTest
@testable import PerfectRouter

/// Unit tests for `StopSuggestionService.evenlySpaced`, the budget cap that
/// spreads a bounded number of searches across the whole route (rather than
/// truncating to the head of the route).
final class StopSamplingTests: XCTestCase {

    private let service = StopSuggestionService()

    func testFewerSamplesThanLimitAreUntouched() {
        XCTAssertEqual(service.evenlySpaced([1, 2, 3], max: 16), [1, 2, 3])
    }

    func testKeepsFirstAndLastWhenDownsampling() {
        let samples = Array(0..<100)
        let picked = service.evenlySpaced(samples, max: 16)
        XCTAssertEqual(picked.count, 16)
        XCTAssertEqual(picked.first, 0)
        XCTAssertEqual(picked.last, 99)
    }

    func testSpreadIsRoughlyEven() {
        let samples = Array(0..<100)
        let picked = service.evenlySpaced(samples, max: 5)
        // 0, ~25, ~50, ~74, 99 — gaps within one step of each other.
        XCTAssertEqual(picked.count, 5)
        let gaps = zip(picked.dropFirst(), picked).map(-)
        guard let smallest = gaps.min(), let largest = gaps.max() else {
            return XCTFail("expected gaps")
        }
        XCTAssertLessThanOrEqual(largest - smallest, 1)
    }

    func testLimitOfOneKeepsTheStart() {
        XCTAssertEqual(service.evenlySpaced([7, 8, 9], max: 1), [7])
    }

    func testZeroLimitYieldsNothing() {
        XCTAssertEqual(service.evenlySpaced([1, 2, 3], max: 0), [])
    }

    func testEmptyInputYieldsNothing() {
        XCTAssertEqual(service.evenlySpaced([Int](), max: 5), [])
    }
}
