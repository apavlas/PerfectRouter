import CoreLocation
import XCTest
@testable import PerfectRouter

/// Ride safety check-in: ETA, overdue time, the texts, and persistence.
final class RideCheckInTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func group() -> RiderGroup {
        RiderGroup(name: "Sunday Crew", riders: [
            Rider(name: "Derek", phoneNumber: "555-0100"),
            Rider(name: "Chris", phoneNumber: "555-0101"),
        ])
    }

    func testExpectedArrivalAddsFifteenMinutesPerStop() {
        let arrival = RideCheckIn.expectedArrival(start: start, ridingTime: 2 * 3_600, stopCount: 2)
        XCTAssertEqual(arrival.timeIntervalSince(start), 2.5 * 3_600)
    }

    func testGraceIsAQuarterOfTheRideWithinLimits() {
        XCTAssertEqual(RideCheckIn.grace(forRideTime: 30 * 60), 30 * 60)
        XCTAssertEqual(RideCheckIn.grace(forRideTime: 4 * 3_600), 3_600)
        XCTAssertEqual(RideCheckIn.grace(forRideTime: 12 * 3_600), 2 * 3_600)
    }

    func testMakeSetsOverdueAfterArrival() {
        let checkIn = RideCheckIn.make(
            group: group(),
            destinationName: "Alice's Restaurant",
            start: start,
            ridingTime: 4 * 3_600,
            stopCount: 0
        )
        XCTAssertEqual(checkIn.recipients, ["555-0100", "555-0101"])
        XCTAssertEqual(checkIn.expectedArrival.timeIntervalSince(start), 4 * 3_600)
        XCTAssertEqual(checkIn.overdueAt.timeIntervalSince(checkIn.expectedArrival), 3_600)
        XCTAssertFalse(checkIn.isOverdue(now: checkIn.expectedArrival))
        XCTAssertTrue(checkIn.isOverdue(now: checkIn.overdueAt))
    }

    func testStartMessageTellsTheGroupWhenToWorry() {
        let checkIn = RideCheckIn.make(group: group(), destinationName: "Skyline Blvd", start: start, ridingTime: 3_600, stopCount: 0)
        let text = checkIn.startMessage(timeZone: utc)
        XCTAssertTrue(text.contains("Skyline Blvd"))
        XCTAssertTrue(text.contains(RideCheckIn.clock(checkIn.expectedArrival, relativeTo: start, timeZone: utc)))
        XCTAssertTrue(text.contains(RideCheckIn.clock(checkIn.overdueAt, relativeTo: start, timeZone: utc)))
        XCTAssertTrue(text.contains("please call me"))
    }

    func testLateMessageIncludesLocationLinkWhenKnown() {
        let checkIn = RideCheckIn.make(group: group(), destinationName: "Home", start: start, ridingTime: 3_600, stopCount: 0)
        let here = CLLocationCoordinate2D(latitude: 37.12345, longitude: -122.54321)
        XCTAssertTrue(checkIn.lateMessage(location: here, now: start, timeZone: utc).contains("maps.apple.com/?ll=37.12345,-122.54321"))
        XCTAssertFalse(checkIn.lateMessage(location: nil, now: start, timeZone: utc).contains("maps.apple.com"))
    }

    func testStoreRoundTripsAndClears() {
        let defaults = UserDefaults(suiteName: "RideCheckInTests")!
        defaults.removePersistentDomain(forName: "RideCheckInTests")
        let store = RideCheckInStore(defaults: defaults)
        let checkIn = RideCheckIn.make(group: group(), destinationName: "Home", start: start, ridingTime: 3_600, stopCount: 1)
        store.save(checkIn)
        XCTAssertEqual(store.load(), checkIn)
        store.save(nil)
        XCTAssertNil(store.load())
    }
}
