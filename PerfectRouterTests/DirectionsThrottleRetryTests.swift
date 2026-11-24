import XCTest
import MapKit
@testable import PerfectRouter

/// A throttled directions leg is retried with backoff instead of failing the plan.
final class DirectionsThrottleRetryTests: XCTestCase {

    private let throttled = NSError(domain: MKErrorDomain, code: Int(MKError.Code.loadingThrottled.rawValue))
    private let serverFailure = NSError(domain: MKErrorDomain, code: Int(MKError.Code.serverFailure.rawValue))

    /// Records each backoff without sleeping.
    private final class Pauses: @unchecked Sendable {
        var waited: [Duration] = []
        var allow = true
    }

    func testRetriesThrottleThenSucceeds() async throws {
        let pauses = Pauses()
        var calls = 0
        let result = try await DirectionsThrottleRetry.run(pause: { pauses.waited.append($0); return pauses.allow }) {
            calls += 1
            if calls < 3 { throw throttled }
            return "route"
        }
        XCTAssertEqual(result, "route")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(pauses.waited, [.seconds(2), .seconds(4)])
    }

    func testGivesUpAfterMaxRetriesWithThrottleError() async {
        let pauses = Pauses()
        var calls = 0
        do {
            _ = try await DirectionsThrottleRetry.run(pause: { pauses.waited.append($0); return true }) { () -> String in
                calls += 1
                throw throttled
            }
            XCTFail("expected the throttle error")
        } catch {
            XCTAssertTrue(StopSuggestionService.isMapSearchThrottled(error))
        }
        XCTAssertEqual(calls, DirectionsThrottleRetry.maxRetries + 1)
        XCTAssertEqual(pauses.waited, [.seconds(2), .seconds(4), .seconds(8)])
    }

    func testOtherErrorsAreNotRetried() async {
        var calls = 0
        do {
            _ = try await DirectionsThrottleRetry.run(pause: { _ in true }) { () -> String in
                calls += 1
                throw serverFailure
            }
            XCTFail("expected the server error")
        } catch {
            XCTAssertEqual((error as NSError).code, serverFailure.code)
        }
        XCTAssertEqual(calls, 1)
    }

    func testCancelledWaitStopsRetrying() async {
        var calls = 0
        do {
            _ = try await DirectionsThrottleRetry.run(pause: { _ in false }) { () -> String in
                calls += 1
                throw throttled
            }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(calls, 1)
    }
}
