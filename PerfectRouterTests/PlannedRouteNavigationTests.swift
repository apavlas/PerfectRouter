import CoreLocation
import XCTest
@testable import PerfectRouter

/// The locked line is the plan. A faster shortcut is off route, and a
/// replacement that skips a selected stop is rejected.
final class PlannedRouteNavigationTests: XCTestCase {

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    /// East, then north, then east again. The northward jog is the scenic
    /// detour. The straight road along latitude 0 is the faster shortcut.
    private func scenicDetour() -> PlannedNavigationLine {
        let overlook = PlannedRouteStop(
            id: UUID(),
            name: "Overlook",
            latitude: 0.015,
            longitude: 0.02,
            distanceAlongRoute: 0,
            kind: .stop,
            isFuel: false
        )
        let destination = PlannedRouteStop(
            id: UUID(),
            name: "Camp",
            latitude: 0.015,
            longitude: 0.04,
            distanceAlongRoute: 0,
            kind: .destination,
            isFuel: false
        )
        let line = PlannedRouteNavigation.makeLine(
            coordinates: [
                coordinate(0, 0),
                coordinate(0, 0.02),
                coordinate(0.015, 0.02),
                coordinate(0.015, 0.04),
            ],
            stops: [overlook, destination],
            routeStyleName: "Scenic"
        )
        XCTAssertNotNil(line)
        return line!
    }

    func testMakeLineKeepsTheScenicBulge() {
        let line = scenicDetour()
        XCTAssertEqual(line.coordinates.count, 4)
        XCTAssertEqual(line.coordinates[2].latitude, 0.015, accuracy: 0.000_000_1)
        XCTAssertEqual(line.coordinates[2].longitude, 0.02, accuracy: 0.000_000_1)
        XCTAssertEqual(line.routeStyleName, "Scenic")

        let overlook = line.stops.first { $0.name == "Overlook" }
        let jog = RouteGeometry.length(of: [
            coordinate(0, 0),
            coordinate(0, 0.02),
            coordinate(0.015, 0.02),
        ])
        XCTAssertEqual(overlook?.distanceAlongRoute ?? -1, jog, accuracy: jog * 0.02)
    }

    func testRiderOnTheDetourIsOnRoute() {
        let line = scenicDetour()
        let onDetour = coordinate(0.015, 0.03)
        let fix = PlannedRouteNavigation.fix(at: onDetour, on: line, progressedDistance: 0)
        XCTAssertFalse(fix.isOffRoute)
        XCTAssertLessThan(fix.distanceFromLine, PlannedRouteNavigation.onRouteToleranceMeters)
        XCTAssertGreaterThan(fix.distanceAlong, 0)
    }

    func testFasterShortcutIsOffRouteAndDoesNotMoveTheLine() {
        let line = scenicDetour()
        let original = line.coordinates
        // Latitude 0, past the jog: the shortcut that skips Overlook.
        let shortcut = coordinate(0, 0.03)
        let fix = PlannedRouteNavigation.fix(at: shortcut, on: line, progressedDistance: 0)

        XCTAssertTrue(fix.isOffRoute)
        XCTAssertGreaterThan(fix.distanceFromLine, 1_000)
        XCTAssertTrue(PlannedRouteNavigation.shouldOfferOffRouteChoice(isOffRoute: true, decision: nil))
        XCTAssertFalse(PlannedRouteNavigation.shouldOfferOffRouteChoice(isOffRoute: true, decision: .backToMyRoute))
        XCTAssertEqual(line.coordinates.count, original.count)
        XCTAssertEqual(line.coordinates[2].latitude, original[2].latitude, accuracy: 0.000_000_1)
    }

    func testProgressDoesNotJumpBackwardToAnEarlierVertex() {
        let line = scenicDetour()
        let far = PlannedRouteNavigation.fix(
            at: coordinate(0.015, 0.035),
            on: line,
            progressedDistance: 0
        )
        let glitchNearStart = PlannedRouteNavigation.fix(
            at: coordinate(0, 0.001),
            on: line,
            progressedDistance: far.progressedDistance
        )
        XCTAssertFalse(glitchNearStart.isOffRoute)
        XCTAssertGreaterThanOrEqual(glitchNearStart.progressedDistance, far.progressedDistance - 1)
    }

    func testRerouteThatSkipsTheSelectedStopIsRejected() {
        let line = scenicDetour()
        let required = PlannedRouteNavigation.remainingRequiredStops(on: line, progressedDistance: 0)
        XCTAssertEqual(required.map(\.name), ["Overlook", "Camp"])

        let shortcut = [
            coordinate(0, 0),
            coordinate(0.015, 0.04),
        ]
        XCTAssertFalse(PlannedRouteNavigation.reroutePreservesStops(required, on: shortcut))
    }

    func testRerouteThatKeepsTheSelectedStopIsAccepted() {
        let line = scenicDetour()
        let required = PlannedRouteNavigation.remainingRequiredStops(on: line, progressedDistance: 0)
        XCTAssertTrue(PlannedRouteNavigation.reroutePreservesStops(required, on: line.coordinates))
    }

    func testChoiceIsNotImpliedWhileStillOnTheLine() {
        XCTAssertFalse(PlannedRouteNavigation.shouldOfferOffRouteChoice(isOffRoute: false, decision: nil))
    }

    func testMakeLineDropsOnlyDuplicateVertices() {
        let line = PlannedRouteNavigation.makeLine(
            coordinates: [
                coordinate(0, 0),
                coordinate(0, 0),
                coordinate(0, 0.01),
            ],
            stops: [],
            routeStyleName: "Fastest"
        )
        XCTAssertEqual(line?.coordinates.count, 2)
    }

    func testEmptyAndSinglePointLinesAreNil() {
        XCTAssertNil(PlannedRouteNavigation.makeLine(coordinates: [], stops: [], routeStyleName: "Fastest"))
        XCTAssertNil(PlannedRouteNavigation.makeLine(
            coordinates: [coordinate(1, 2)],
            stops: [],
            routeStyleName: "Fastest"
        ))
    }
}
