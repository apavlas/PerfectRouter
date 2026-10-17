import AVFoundation
import CoreLocation
import Foundation

/// Speaks a guidance phrase. The system speaker uses `AVSpeechSynthesizer`.
/// Tests pass a recorder instead.
protocol NavigationSpeaking: AnyObject {
    func speak(_ phrase: String)
    func stop()
}

/// Foreground voice guidance. Queues phrases; `stop` cuts them off when the
/// rider ends the ride.
final class SystemNavigationSpeaker: NavigationSpeaking {
    private let synthesizer = AVSpeechSynthesizer()

    func speak(_ phrase: String) {
        let utterance = AVSpeechUtterance(string: phrase)
        // Default rate is the system's spoken-direction pace.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}

/// Follows one planned line. Owns the location updates for the ride so the
/// planner can keep its one-fix battery behavior.
///
/// Location is when-in-use and stops with the screen. Background guidance and
/// a CarPlay scene are not part of this type: case 22828371 still needs
/// device screenshots plus `NavigationVoiceGuidance.descriptionForCarPlayReply`.
@MainActor
@Observable
final class PlannedRouteNavigationSession: NSObject, CLLocationManagerDelegate, Identifiable {
    let id = UUID()

    private(set) var state: NavigationSessionState
    private let speaker: any NavigationSpeaking
    private let locationManager = CLLocationManager()
    private let reroute: NavigationRerouteHandler?
    /// False after `stop`, so a reroute that returns late cannot replace the line.
    private var acceptsResults = true

    typealias NavigationRerouteHandler = @MainActor (
        _ origin: CLLocationCoordinate2D,
        _ remainingStops: [PlannedRouteStop],
        _ routeStyleName: String
    ) async -> PlannedNavigationReplacement?

    init(
        line: PlannedNavigationLine,
        maneuvers: [PlannedManeuver],
        usesMetric: Bool,
        speaker: (any NavigationSpeaking)? = nil,
        reroute: NavigationRerouteHandler? = nil
    ) {
        self.state = NavigationSessionState(line: line, maneuvers: maneuvers, usesMetric: usesMetric)
        self.speaker = speaker ?? SystemNavigationSpeaker()
        self.reroute = reroute
        super.init()
    }

    var display: PlannedNavigationDisplay { state.display() }

    var routeCoordinates: [CLLocationCoordinate2D] { state.line.coordinates }

    func start() {
        guard acceptsResults else { return }
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        locationManager.activityType = .automotiveNavigation
        locationManager.distanceFilter = 8
        beginUpdatesIfAuthorized()
    }

    func stop() {
        acceptsResults = false
        locationManager.stopUpdatingLocation()
        speaker.stop()
    }

    /// Applies one fix and speaks any new cues. Does not replace the line.
    func ingest(_ coordinate: CLLocationCoordinate2D) {
        guard coordinate.isValidLocation else { return }
        speak(state.ingest(coordinate))
    }

    func chooseBackToMyRoute() {
        speak(state.chooseBackToMyRoute())
    }

    /// Explicit "Reroute from here". A nil or stop-dropping replacement leaves
    /// the planned line in place and returns the rider to the choice.
    func chooseRerouteFromHere() async {
        guard !state.isRerouteInFlight else { return }
        let styleName = state.line.routeStyleName
        let stops = state.beginReroute()
        guard let origin = state.latest?.coordinate, let reroute else {
            state.failReroute()
            return
        }
        let replacement = await reroute(origin, stops, styleName)
        guard acceptsResults else { return }
        if let replacement, state.applyReroute(replacement) {
            return
        }
        state.failReroute()
    }

    private func speak(_ cues: [VoiceCue]) {
        for cue in cues {
            speaker.speak(cue.phrase)
        }
    }

    private func beginUpdatesIfAuthorized() {
        switch locationManager.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            locationManager.startUpdatingLocation()
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        default:
            break
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.acceptsResults else { return }
            self.beginUpdatesIfAuthorized()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in
            guard self.acceptsResults else { return }
            self.ingest(coordinate)
        }
    }
}
