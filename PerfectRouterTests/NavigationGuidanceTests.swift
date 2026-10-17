import CoreLocation
import XCTest
@testable import PerfectRouter

/// Turns, voice bands, and fuel distance follow the locked line. Going off
/// onto a faster road speaks the off-route prompt and leaves the line alone.
final class NavigationGuidanceTests: XCTestCase {

    private func coordinate(_ latitude: Double, _ longitude: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private func stop(
        _ name: String,
        latitude: Double,
        longitude: Double,
        kind: PlannedRouteStop.Kind,
        isFuel: Bool = false
    ) -> PlannedRouteStop {
        PlannedRouteStop(
            id: UUID(),
            name: name,
            latitude: latitude,
            longitude: longitude,
            distanceAlongRoute: 0,
            kind: kind,
            isFuel: isFuel
        )
    }

    /// East, north, east. The northward jog is the scenic detour.
    private func scenicDetour() -> (line: PlannedNavigationLine, maneuvers: [PlannedManeuver]) {
        let line = PlannedRouteNavigation.makeLine(
            coordinates: [
                coordinate(0, 0),
                coordinate(0, 0.02),
                coordinate(0.015, 0.02),
                coordinate(0.015, 0.04),
            ],
            stops: [
                stop("Overlook", latitude: 0.015, longitude: 0.02, kind: .stop),
                stop("Pump", latitude: 0.015, longitude: 0.03, kind: .fuel, isFuel: true),
                stop("Camp", latitude: 0.015, longitude: 0.04, kind: .destination),
            ],
            routeStyleName: "Scenic"
        )!
        let maneuvers = NavigationGuidance.maneuvers(along: line.coordinates, stops: line.stops)
        return (line, maneuvers)
    }

    private func fingerprint(_ line: PlannedNavigationLine) -> [String] {
        line.coordinates.map { "\($0.latitude),\($0.longitude)" }
    }

    func testRightTurnUsesThePlannedVertexAndStepStreet() {
        let corner = coordinate(0, 0.01)
        let coordinates = [coordinate(0, 0), corner, coordinate(-0.01, 0.01)]
        let maneuvers = NavigationGuidance.maneuvers(
            along: coordinates,
            stops: [stop("End", latitude: -0.01, longitude: 0.01, kind: .destination)],
            steps: [PlannedStepHint(instructions: "Turn right onto Ridge Road", coordinates: [coordinate(0, 0), corner])]
        )
        let turn = maneuvers.first { $0.direction == .right }
        XCTAssertEqual(turn?.streetName, "Ridge Road")
        XCTAssertEqual(turn?.instruction, "Turn right onto Ridge Road")
    }

    func testLeftTurnIsNotAnnouncedAsRight() {
        let coordinates = [coordinate(0, 0), coordinate(0, 0.01), coordinate(0.01, 0.01)]
        let maneuvers = NavigationGuidance.maneuvers(along: coordinates, stops: [])
        XCTAssertTrue(maneuvers.contains { $0.direction == .left })
        XCTAssertFalse(maneuvers.contains { $0.direction == .right })
    }

    func testSelectedStopIsAManeuverOnAStraightLine() {
        let coordinates = [coordinate(0, 0), coordinate(0, 0.02)]
        let maneuvers = NavigationGuidance.maneuvers(
            along: coordinates,
            stops: [
                stop("Pump", latitude: 0, longitude: 0.01, kind: .stop, isFuel: true),
                stop("Camp", latitude: 0, longitude: 0.02, kind: .destination),
            ]
        )
        XCTAssertTrue(maneuvers.contains { $0.instruction == "Arrive at Pump" })
        XCTAssertTrue(maneuvers.contains { $0.instruction == "Arrive at Camp" })
        XCTAssertFalse(maneuvers.contains { $0.direction == .left || $0.direction == .right })
    }

    func testStreetNameParsesOnto() {
        XCTAssertEqual(NavigationGuidance.streetName(from: "Turn left onto River Road"), "River Road")
        XCTAssertEqual(NavigationGuidance.streetName(from: "Continue toward the overlook."), "the overlook")
        XCTAssertNil(NavigationGuidance.streetName(from: "Turn left"))
    }

    func testGlanceDistanceRoundsForGloves() {
        XCTAssertEqual(NavigationGuidance.glanceDistance(0, usesMetric: false), "0 ft")
        XCTAssertEqual(NavigationGuidance.glanceDistance(AppSettings.metersPerMile, usesMetric: false), "1.0 mi")
        XCTAssertEqual(NavigationGuidance.glanceDistance(1_000, usesMetric: true), "1.0 km")
        XCTAssertEqual(NavigationGuidance.glanceDistance(0, usesMetric: true), "0 m")
    }

    func testVoiceBandsSpeakOnceAndDoNotRewriteTheDetour() {
        let scenic = scenicDetour()
        var state = NavigationSessionState(line: scenic.line, maneuvers: scenic.maneuvers, usesMetric: false)
        let locked = fingerprint(scenic.line)

        // A long eastbound approach with a right turn, so the mile band is real.
        let cornerDistance = RouteGeometry.length(of: [coordinate(0, 0), coordinate(0, 0.05)])
        let approach = PlannedRouteNavigation.point(
            along: [coordinate(0, 0), coordinate(0, 0.05), coordinate(-0.01, 0.05)],
            distance: cornerDistance - 1_500
        )!
        let approachLine = PlannedRouteNavigation.makeLine(
            coordinates: [coordinate(0, 0), coordinate(0, 0.05), coordinate(-0.01, 0.05)],
            stops: [
                stop("Pump", latitude: 0, longitude: 0.04, kind: .fuel, isFuel: true),
                stop("End", latitude: -0.01, longitude: 0.05, kind: .destination),
            ],
            routeStyleName: "Scenic"
        )!
        var approachState = NavigationSessionState(
            line: approachLine,
            maneuvers: NavigationGuidance.maneuvers(along: approachLine.coordinates, stops: approachLine.stops),
            usesMetric: false
        )
        let first = approachState.ingest(approach)
        XCTAssertEqual(first.map(\.phrase), [NavigationVoiceGuidance.departPhrase])
        let second = approachState.ingest(approach)
        XCTAssertTrue(second.contains { $0.phrase.hasPrefix("In 1 mile, turn right") })
        XCTAssertTrue(second.contains { $0.phrase.hasPrefix("Next fuel stop in ") })
        let repeated = approachState.ingest(approach)
        XCTAssertTrue(repeated.isEmpty)

        let closer = PlannedRouteNavigation.point(
            along: approachLine.coordinates,
            distance: cornerDistance - 100
        )!
        let near = approachState.ingest(closer)
        XCTAssertTrue(near.contains { $0.phrase.hasPrefix("In 500 feet, turn right") })

        // The scenic detour is a different line. Sitting on the shortcut must
        // not speak a turn onto a faster road or replace the bulge.
        _ = state.ingest(coordinate(0, 0.03))
        XCTAssertEqual(fingerprint(state.line), locked)
        XCTAssertEqual(state.phase, .offRoutePrompt)
        XCTAssertEqual(state.display().fuelText.isEmpty, false)
        XCTAssertTrue(state.display().fuelText.hasPrefix("Fuel in ") || state.display().fuelText == "No fuel stop ahead")
        let offAgain = state.ingest(coordinate(0, 0.03))
        XCTAssertTrue(offAgain.isEmpty, "the off-route prompt is spoken once")
        XCTAssertFalse(state.display().fuelText.isEmpty)

        XCTAssertFalse(state.applyReroute(PlannedNavigationReplacement(
            line: approachLine,
            maneuvers: [],
            note: nil
        )))
        state.beginReroute()
        XCTAssertFalse(state.applyReroute(PlannedNavigationReplacement(
            line: approachLine,
            maneuvers: [],
            note: nil
        )), "a faster line that misses Overlook is not applied")
        state.failReroute()
        XCTAssertEqual(fingerprint(state.line), locked)

        let back = state.chooseBackToMyRoute()
        XCTAssertEqual(back.map(\.phrase), [NavigationVoiceGuidance.returnPhrase])
        XCTAssertEqual(fingerprint(state.line), locked)
        XCTAssertEqual(state.phase, .returning)
        XCTAssertFalse(state.display().fuelText.isEmpty)
    }

    func testExplicitRerouteKeepsRemainingStops() {
        let scenic = scenicDetour()
        var state = NavigationSessionState(line: scenic.line, maneuvers: scenic.maneuvers, usesMetric: false)
        _ = state.ingest(coordinate(0, 0.03))
        let required = state.beginReroute()
        XCTAssertTrue(required.contains { $0.name == "Overlook" })

        let kept = PlannedRouteNavigation.makeLine(
            coordinates: scenic.line.coordinates,
            stops: scenic.line.stops,
            routeStyleName: "Scenic"
        )!
        XCTAssertTrue(state.applyReroute(PlannedNavigationReplacement(
            line: kept,
            maneuvers: NavigationGuidance.maneuvers(along: kept.coordinates, stops: kept.stops),
            note: nil
        )))
        XCTAssertEqual(state.phase, .onRoute)
        XCTAssertNil(state.decision)
    }

    func testScenicManeuversFollowTheBulge() {
        let scenic = scenicDetour()
        XCTAssertTrue(scenic.maneuvers.contains { $0.direction == .left })
        XCTAssertTrue(scenic.maneuvers.contains { $0.direction == .right })
        let onDetour = coordinate(0.015, 0.025)
        var state = NavigationSessionState(line: scenic.line, maneuvers: scenic.maneuvers, usesMetric: false)
        _ = state.ingest(onDetour)
        _ = state.ingest(onDetour)
        XCTAssertEqual(state.phase, .onRoute)
        XCTAssertFalse(state.display().fuelText.isEmpty)
        XCTAssertNotEqual(state.display().arrowSymbol, "exclamationmark.triangle.fill")
    }
}
