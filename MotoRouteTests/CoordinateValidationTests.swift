import XCTest
import CoreLocation
@testable import MotoRoute

/// Tests for `CLLocationCoordinate2D.isValidLocation`, the guard that keeps
/// invalid / NaN coordinates from reaching MapKit (which asserts on them).
final class CoordinateValidationTests: XCTestCase {

    func testRealCoordinateIsValid() {
        let augusta = CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105)
        XCTAssertTrue(augusta.isValidLocation)
    }

    func testZeroIslandIsValid() {
        // (0, 0) is a real, in-range coordinate — MapKit accepts it.
        XCTAssertTrue(CLLocationCoordinate2D(latitude: 0, longitude: 0).isValidLocation)
    }

    func testMapKitInvalidSentinelIsRejected() {
        XCTAssertFalse(kCLLocationCoordinate2DInvalid.isValidLocation)
    }

    func testNaNIsRejected() {
        XCTAssertFalse(CLLocationCoordinate2D(latitude: .nan, longitude: .nan).isValidLocation)
        XCTAssertFalse(CLLocationCoordinate2D(latitude: 33.0, longitude: .nan).isValidLocation)
    }

    func testInfiniteIsRejected() {
        XCTAssertFalse(CLLocationCoordinate2D(latitude: .infinity, longitude: 0).isValidLocation)
    }

    func testOutOfRangeIsRejected() {
        XCTAssertFalse(CLLocationCoordinate2D(latitude: 91, longitude: 0).isValidLocation)
        XCTAssertFalse(CLLocationCoordinate2D(latitude: 0, longitude: 181).isValidLocation)
    }
}
