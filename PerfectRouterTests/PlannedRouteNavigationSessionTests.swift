import CoreLocation
import XCTest
@testable import PerfectRouter

/// Not isolated to the main actor, so it can satisfy `NavigationSpeaking`.
private final class RecordingSpeaker: NavigationSpeaking {
    var phrases: [String] = []
    func speak(_ phrase: String) { phrases.append(phrase) }
    func stop() {}
}

/// The session speaks and records the rider's choice. It does not call the
/// reroute handler until "Reroute from here", and it drops a replacement
/// that misses a selected stop.
@MainActor
final class PlannedRouteNavigationSessionTests: XCTestCase {

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

    private func scenicLine() -> PlannedNavigationLine {
        PlannedRouteNavigation.makeLine(
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
    }

    private func session(
        speaker: RecordingSpeaker,
        reroute: PlannedRouteNavigationSession.NavigationRerouteHandler? = nil
    ) -> PlannedRouteNavigationSession {
        let line = scenicLine()
        return PlannedRouteNavigationSession(
            line: line,
            maneuvers: NavigationGuidance.maneuvers(along: line.coordinates, stops: line.stops),
            usesMetric: false,
            speaker: speaker,
            reroute: reroute
        )
    }

    private func latitudes(_ session: PlannedRouteNavigationSession) -> [Double] {
        session.routeCoordinates.map(\.latitude)
    }

    func testShortcutSpeaksOffRouteAndDoesNotReroute() {
        let speaker = RecordingSpeaker()
        var calls = 0
        let ride = session(speaker: speaker) { _, _, _ in
            calls += 1
            return nil
        }
        let locked = latitudes(ride)
        ride.ingest(coordinate(0, 0.03))

        XCTAssertEqual(latitudes(ride), locked)
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(speaker.phrases, [NavigationVoiceGuidance.offRoutePhrase])
        XCTAssertEqual(ride.display.phase, .offRoutePrompt)
        XCTAssertTrue(ride.display.fuelText.hasPrefix("Fuel in "))
        XCTAssertFalse(speaker.phrases.contains { $0.contains("Turn") })
    }

    func testBackToMyRouteKeepsTheDetour() {
        let speaker = RecordingSpeaker()
        let ride = session(speaker: speaker)
        let locked = latitudes(ride)
        ride.ingest(coordinate(0, 0.03))
        ride.chooseBackToMyRoute()

        XCTAssertEqual(latitudes(ride), locked)
        XCTAssertEqual(ride.display.phase, .returning)
        XCTAssertEqual(ride.display.streetName, "Back to my route")
        XCTAssertTrue(speaker.phrases.contains(NavigationVoiceGuidance.returnPhrase))
        XCTAssertFalse(ride.display.fuelText.isEmpty)
    }

    func testRerouteThatMissesTheStopIsDiscarded() async {
        let speaker = RecordingSpeaker()
        let shortcut = PlannedRouteNavigation.makeLine(
            coordinates: [coordinate(0, 0), coordinate(0.015, 0.04)],
            stops: [stop("Camp", latitude: 0.015, longitude: 0.04, kind: .destination)],
            routeStyleName: "Scenic"
        )!
        let ride = session(speaker: speaker) { _, _, _ in
            PlannedNavigationReplacement(
                line: shortcut,
                maneuvers: [],
                note: "faster"
            )
        }
        let locked = latitudes(ride)
        ride.ingest(coordinate(0, 0.03))
        await ride.chooseRerouteFromHere()

        XCTAssertEqual(latitudes(ride), locked)
        XCTAssertEqual(ride.display.phase, .offRoutePrompt)
        XCTAssertEqual(ride.display.statusBanner, "Couldn't reroute. Your planned line is unchanged.")
        XCTAssertFalse(ride.display.fuelText.isEmpty)
    }

    func testRerouteThatKeepsTheStopReplacesTheLine() async {
        let speaker = RecordingSpeaker()
        let kept = scenicLine()
        let ride = session(speaker: speaker) { _, _, styleName in
            XCTAssertEqual(styleName, "Scenic")
            return PlannedNavigationReplacement(
                line: kept,
                maneuvers: NavigationGuidance.maneuvers(along: kept.coordinates, stops: kept.stops),
                note: "Kept the stops."
            )
        }
        ride.ingest(coordinate(0, 0.03))
        await ride.chooseRerouteFromHere()

        XCTAssertEqual(ride.display.phase, .onRoute)
        XCTAssertEqual(ride.display.statusBanner, "Kept the stops.")
        XCTAssertEqual(latitudes(ride), latitudes(session(speaker: RecordingSpeaker())))
    }
}
