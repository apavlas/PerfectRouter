import CoreLocation
import Foundation

/// One turn (or arrival) along the locked line. Built from the planned
/// vertices, not from a fresh directions request.
struct PlannedManeuver: Equatable, Identifiable, Sendable {
    enum Direction: String, Equatable, Sendable {
        case straight
        case slightLeft
        case left
        case sharpLeft
        case slightRight
        case right
        case sharpRight
        case uTurn
        case arrive
        case depart
        case returnToRoute
    }

    var id: Int
    var direction: Direction
    var streetName: String
    var distanceAlongRoute: CLLocationDistance
    var instruction: String
}

/// A step the planner already stored on the planned route. Street names are
/// read from these instructions when the step sits on the same vertex.
/// Navigation does not request new steps.
struct PlannedStepHint: Sendable {
    var instructions: String
    var coordinates: [CLLocationCoordinate2D]
}

struct VoiceCue: Equatable, Sendable {
    var key: String
    var phrase: String
}

enum NavigationPhase: String, Equatable, Sendable {
    case onRoute
    case offRoutePrompt
    case returning
    case rerouting
    case arrived
}

/// What the glanceable screen draws. Fuel text is never empty.
struct PlannedNavigationDisplay: Equatable {
    var phase: NavigationPhase
    var arrowSymbol: String
    var distanceText: String
    var streetName: String
    var instruction: String
    var fuelText: String
    var statusBanner: String?
    var puckLatitude: Double?
    var puckLongitude: Double?
}

struct PlannedNavigationReplacement {
    var line: PlannedNavigationLine
    var maneuvers: [PlannedManeuver]
    var note: String?
}

/// Turn phrases, the next-fuel distance, and the session state that speaks
/// them. The locked coordinates change only inside `applyReroute`.
enum NavigationGuidance {

    /// Bearing change below this stays "continue" and is not a turn.
    static let minimumTurnDegrees = 25.0

    /// Vertices closer than this are skipped when looking for turns, so a
    /// dense trace doesn't announce a wiggle. The locked line still keeps them.
    static let minimumTurnSpacingMeters: CLLocationDistance = 25

    static func maneuvers(
        along coordinates: [CLLocationCoordinate2D],
        stops: [PlannedRouteStop],
        steps: [PlannedStepHint] = []
    ) -> [PlannedManeuver] {
        guard coordinates.count >= 2 else { return [] }
        let distances = cumulativeDistances(coordinates)
        let kept = thinnedIndices(coordinates: coordinates, distances: distances)

        var drafts: [Draft] = []
        if kept.count >= 3 {
            for index in 1..<(kept.count - 1) {
                let previous = kept[index - 1]
                let current = kept[index]
                let next = kept[index + 1]
                let incoming = PlannedRouteNavigation.bearingDegrees(
                    from: coordinates[previous],
                    to: coordinates[current]
                )
                let outgoing = PlannedRouteNavigation.bearingDegrees(
                    from: coordinates[current],
                    to: coordinates[next]
                )
                let delta = PlannedRouteNavigation.signedTurnDegrees(
                    incoming: incoming,
                    outgoing: outgoing
                )
                guard let direction = turnDirection(for: delta) else { continue }
                let street = streetName(near: coordinates[current], steps: steps) ?? "the planned route"
                drafts.append(Draft(
                    distance: distances[current],
                    direction: direction,
                    street: street,
                    instruction: instruction(direction: direction, street: street)
                ))
            }
        }

        for stop in stops where stop.kind == .stop {
            let crowded = drafts.contains { abs($0.distance - stop.distanceAlongRoute) < 50 }
            if !crowded {
                drafts.append(Draft(
                    distance: stop.distanceAlongRoute,
                    direction: .arrive,
                    street: stop.name,
                    instruction: "Arrive at \(stop.name)"
                ))
            }
        }

        let destinationName = stops.last { $0.kind == .destination }?.name ?? "your destination"
        let end = distances.last ?? 0
        let arrivalAlreadyNoted = drafts.contains {
            $0.direction == .arrive && abs($0.distance - end) < PlannedRouteNavigation.arrivalToleranceMeters
        }
        if !arrivalAlreadyNoted {
            drafts.append(Draft(
                distance: end,
                direction: .arrive,
                street: destinationName,
                instruction: "Arrive at \(destinationName)"
            ))
        }

        return drafts
            .sorted { lhs, rhs in
                if lhs.distance == rhs.distance { return lhs.instruction < rhs.instruction }
                return lhs.distance < rhs.distance
            }
            .enumerated()
            .map { index, draft in
                PlannedManeuver(
                    id: index,
                    direction: draft.direction,
                    streetName: draft.street,
                    distanceAlongRoute: draft.distance,
                    instruction: draft.instruction
                )
            }
    }

    /// The next maneuver still ahead of `distanceAlong`.
    static func nextManeuver(
        in maneuvers: [PlannedManeuver],
        distanceAlong: CLLocationDistance
    ) -> (maneuver: PlannedManeuver, distance: CLLocationDistance)? {
        for maneuver in maneuvers where maneuver.distanceAlongRoute > distanceAlong + 15 {
            return (maneuver, maneuver.distanceAlongRoute - distanceAlong)
        }
        if let last = maneuvers.last {
            return (last, max(0, last.distanceAlongRoute - distanceAlong))
        }
        return nil
    }

    /// Next gas stop strictly ahead of the rider. Nil when the plan has no
    /// more fuel, which the screen still says out loud as text.
    static func nextFuel(
        in stops: [PlannedRouteStop],
        distanceAlong: CLLocationDistance
    ) -> (stop: PlannedRouteStop, distance: CLLocationDistance)? {
        let upcoming = stops
            .filter { $0.isFuel && $0.distanceAlongRoute > distanceAlong + 20 }
            .sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }
        guard let stop = upcoming.first else { return nil }
        return (stop, stop.distanceAlongRoute - distanceAlong)
    }

    static func fuelText(
        stops: [PlannedRouteStop],
        distanceAlong: CLLocationDistance,
        extraMeters: CLLocationDistance = 0,
        usesMetric: Bool
    ) -> String {
        guard let fuel = nextFuel(in: stops, distanceAlong: distanceAlong) else {
            return "No fuel stop ahead"
        }
        let distance = glanceDistance(fuel.distance + max(0, extraMeters), usesMetric: usesMetric)
        return "Fuel in \(distance)"
    }

    /// Large, glove-readable distance. Feet under 500 ft, otherwise miles
    /// with one decimal until 10. Metric uses meters under 1 km.
    static func glanceDistance(_ meters: CLLocationDistance, usesMetric: Bool) -> String {
        let safe = max(0, meters)
        if usesMetric {
            if safe < 20 { return "0 m" }
            if safe < 1_000 {
                let rounded = max(50, Int((safe / 50).rounded()) * 50)
                return "\(rounded) m"
            }
            let kilometers = safe / 1_000
            if kilometers < 10 {
                return "\(oneDecimal(kilometers)) km"
            }
            return "\(Int(kilometers.rounded())) km"
        }
        let feet = safe * 3.28084
        if feet < 25 { return "0 ft" }
        if feet < 500 {
            let rounded = max(50, Int((feet / 50).rounded()) * 50)
            return "\(rounded) ft"
        }
        let miles = safe / AppSettings.metersPerMile
        if miles < 10 {
            return "\(oneDecimal(miles)) mi"
        }
        return "\(Int(miles.rounded())) mi"
    }

    /// One decimal place without `String(format:)`, which follows the locale
    /// and can turn a test's "1.0" into "1,0".
    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        let whole = tenths / 10
        let fraction = abs(tenths % 10)
        return "\(whole).\(fraction)"
    }

    static func symbolName(for direction: PlannedManeuver.Direction) -> String {
        switch direction {
        case .straight, .depart:
            return "arrow.up"
        case .slightLeft:
            return "arrow.up.left"
        case .left, .sharpLeft:
            return "arrow.turn.up.left"
        case .slightRight:
            return "arrow.up.right"
        case .right, .sharpRight:
            return "arrow.turn.up.right"
        case .uTurn, .returnToRoute:
            return "arrow.uturn.backward"
        case .arrive:
            return "flag.checkered"
        }
    }

    /// "Turn right onto Ridge Road" -> "Ridge Road".
    static func streetName(from instructions: String) -> String? {
        let patterns = [" onto ", " on ", " toward "]
        var earliest: Range<String.Index>?
        for pattern in patterns {
            guard let range = instructions.range(of: pattern, options: .caseInsensitive) else { continue }
            if earliest == nil || range.lowerBound < earliest!.lowerBound {
                earliest = range
            }
        }
        guard let earliest else { return nil }
        var name = instructions[earliest.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasSuffix(".") {
            name.removeLast()
        }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func instruction(direction: PlannedManeuver.Direction, street: String) -> String {
        let road = street.isEmpty ? "the planned route" : street
        switch direction {
        case .straight:
            return "Continue on \(road)"
        case .slightLeft:
            return "Bear left onto \(road)"
        case .left:
            return "Turn left onto \(road)"
        case .sharpLeft:
            return "Sharp left onto \(road)"
        case .slightRight:
            return "Bear right onto \(road)"
        case .right:
            return "Turn right onto \(road)"
        case .sharpRight:
            return "Sharp right onto \(road)"
        case .uTurn:
            return "Make a U-turn onto \(road)"
        case .arrive:
            return "Arrive at \(road)"
        case .depart:
            return "Head out on \(road)"
        case .returnToRoute:
            return "Head back to your route"
        }
    }

    struct VoiceBand: Equatable {
        var id: String
        var leadIn: String
    }

    /// The tightest band the rider has entered. Nil when the turn is still
    /// farther than the first announcement.
    static func voiceBand(distance: CLLocationDistance, usesMetric: Bool) -> VoiceBand? {
        let bands: [(String, CLLocationDistance, String)]
        if usesMetric {
            bands = [
                ("now", 40, ""),
                ("200m", 200, "In 200 meters, "),
                ("500m", 500, "In 500 meters, "),
                ("1km", 1_000, "In 1 kilometer, "),
            ]
        } else {
            bands = [
                ("now", 40, ""),
                ("500ft", 152, "In 500 feet, "),
                ("half", 805, "In a half mile, "),
                ("mile", 1_609, "In 1 mile, "),
            ]
        }
        for band in bands where distance <= band.1 {
            return VoiceBand(id: band.0, leadIn: band.2)
        }
        return nil
    }

    static func spokenPhrase(leadIn: String, instruction: String) -> String {
        guard !leadIn.isEmpty else { return instruction }
        let body = instruction.prefix(1).lowercased() + instruction.dropFirst()
        return leadIn + body
    }

    // MARK: - Turn geometry

    private struct Draft {
        var distance: CLLocationDistance
        var direction: PlannedManeuver.Direction
        var street: String
        var instruction: String
    }

    static func turnDirection(for signedDegrees: Double) -> PlannedManeuver.Direction? {
        let magnitude = abs(signedDegrees)
        guard magnitude >= minimumTurnDegrees else { return nil }
        let right = signedDegrees > 0
        if magnitude < 50 { return right ? .slightRight : .slightLeft }
        if magnitude < 120 { return right ? .right : .left }
        if magnitude < 160 { return right ? .sharpRight : .sharpLeft }
        return .uTurn
    }

    private static func cumulativeDistances(_ coordinates: [CLLocationCoordinate2D]) -> [CLLocationDistance] {
        var distances: [CLLocationDistance] = [0]
        for index in 1..<coordinates.count {
            let step = PlannedRouteNavigation.meters(from: coordinates[index - 1], to: coordinates[index])
            distances.append(distances[index - 1] + step)
        }
        return distances
    }

    private static func thinnedIndices(
        coordinates: [CLLocationCoordinate2D],
        distances: [CLLocationDistance]
    ) -> [Int] {
        guard let first = coordinates.indices.first else { return [] }
        var kept = [first]
        for index in coordinates.indices.dropFirst() {
            let previous = kept[kept.count - 1]
            let isLast = index == coordinates.index(before: coordinates.endIndex)
            if isLast || distances[index] - distances[previous] >= minimumTurnSpacingMeters {
                kept.append(index)
            }
        }
        return kept
    }

    private static func streetName(
        near coordinate: CLLocationCoordinate2D,
        steps: [PlannedStepHint]
    ) -> String? {
        var bestName: String?
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        let point = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        for step in steps {
            guard let name = streetName(from: step.instructions) else { continue }
            for anchor in [step.coordinates.first, step.coordinates.last].compactMap({ $0 }) {
                let gap = point.distance(from: CLLocation(latitude: anchor.latitude, longitude: anchor.longitude))
                if gap < bestDistance {
                    bestDistance = gap
                    bestName = name
                }
            }
        }
        guard bestDistance <= 80 else { return nil }
        return bestName
    }
}

/// Copy for the Apple CarPlay reply (case 22828371). Describes the speech
/// the in-app guide actually generates. Screenshots of the riding screen
/// still have to be captured on a device or simulator.
enum NavigationVoiceGuidance {
    static let carPlayCaseID = "22828371"

    static let departPhrase = "Head out on your planned route."
    static let offRoutePhrase = "You're off your planned route."
    static let returnPhrase = "Head back to your route."

    static let descriptionForCarPlayReply = """
    PerfectRouter speaks turn-by-turn along the rider's planned line (Apple case \(carPlayCaseID)). \
    It does not hand the ride to Apple Maps, so a scenic detour and the selected stops stay on that line.

    What the rider hears:
    - At the start: "\(departPhrase)"
    - Approaching a turn, once per band: "In 1 mile, …", "In a half mile, …", "In 500 feet, …", \
    then the turn itself ("Turn left onto River Road."). Metric locales use 1 kilometer, 500 meters, and 200 meters.
    - Bear, sharp, and U-turn use those words. A selected stop uses "Arrive at {stop}."
    - The next fuel stop is announced once when it becomes the next one: "Next fuel stop in {distance}." \
    The same distance stays on screen for the whole leg, including while the rider is off the line.
    - Off the planned line, once: "\(offRoutePhrase)" The app does not speak a new route and does not \
    switch the plan. The rider chooses "Back to my route" ("\(returnPhrase)") or "Reroute from here."

    The screen shows a large turn arrow, the distance, and the street name, with the next fuel distance always visible.
    """
}

/// Mutable navigation progress. `ingest` never writes `line.coordinates`.
struct NavigationSessionState {
    var line: PlannedNavigationLine
    var maneuvers: [PlannedManeuver]
    var progressedDistance: CLLocationDistance
    var decision: OffRouteDecision?
    var spokenKeys: Set<String>
    var latest: NavigationFix?
    var isRerouteInFlight: Bool
    var rerouteFailed: Bool
    var rerouteNote: String?
    var usesMetric: Bool

    init(line: PlannedNavigationLine, maneuvers: [PlannedManeuver], usesMetric: Bool) {
        self.line = line
        self.maneuvers = maneuvers
        self.progressedDistance = 0
        self.decision = nil
        self.spokenKeys = []
        self.latest = nil
        self.isRerouteInFlight = false
        self.rerouteFailed = false
        self.rerouteNote = nil
        self.usesMetric = usesMetric
    }

    var phase: NavigationPhase {
        if let latest, PlannedRouteNavigation.hasArrived(
            distanceAlong: latest.distanceAlong,
            length: line.lengthMeters,
            isOffRoute: latest.isOffRoute
        ) {
            return .arrived
        }
        if isRerouteInFlight { return .rerouting }
        if latest?.isOffRoute == true {
            return decision == .backToMyRoute ? .returning : .offRoutePrompt
        }
        return .onRoute
    }

    /// Records a GPS fix. Returns the phrases to speak now.
    /// The planned coordinates are left untouched.
    mutating func ingest(_ coordinate: CLLocationCoordinate2D) -> [VoiceCue] {
        let fix = PlannedRouteNavigation.fix(
            at: coordinate,
            on: line,
            progressedDistance: progressedDistance
        )
        latest = fix
        if fix.isOffRoute {
            return offRouteCues()
        }

        decision = nil
        rerouteFailed = false
        progressedDistance = fix.progressedDistance
        spokenKeys.remove(NavigationVoiceGuidance.offRoutePhrase)
        spokenKeys.remove(NavigationVoiceGuidance.returnPhrase)

        var cues: [VoiceCue] = []
        let announcedDeparture = cueOnce(key: "depart", phrase: NavigationVoiceGuidance.departPhrase, into: &cues)
        if announcedDeparture {
            // The departure sentence is enough for this fix. The next fix
            // announces the upcoming turn and the fuel stop.
            return cues
        }

        if PlannedRouteNavigation.hasArrived(
            distanceAlong: fix.distanceAlong,
            length: line.lengthMeters,
            isOffRoute: false
        ) {
            let name = line.stops.last { $0.kind == .destination }?.name ?? "your destination"
            _ = cueOnce(key: "arrived", phrase: "Arrive at \(name).", into: &cues)
            return cues
        }

        if let next = NavigationGuidance.nextManeuver(in: maneuvers, distanceAlong: fix.distanceAlong),
           let band = NavigationGuidance.voiceBand(distance: next.distance, usesMetric: usesMetric) {
            let phrase = NavigationGuidance.spokenPhrase(leadIn: band.leadIn, instruction: next.maneuver.instruction)
            _ = cueOnce(key: "turn-\(next.maneuver.id)-\(band.id)", phrase: phrase, into: &cues)
        }

        if let fuel = NavigationGuidance.nextFuel(in: line.stops, distanceAlong: fix.distanceAlong) {
            let distance = NavigationGuidance.glanceDistance(fuel.distance, usesMetric: usesMetric)
            _ = cueOnce(
                key: "fuel-\(fuel.stop.id.uuidString)",
                phrase: "Next fuel stop in \(distance).",
                into: &cues
            )
        }
        return cues
    }

    mutating func chooseBackToMyRoute() -> [VoiceCue] {
        guard latest?.isOffRoute == true, !isRerouteInFlight else { return [] }
        decision = .backToMyRoute
        var cues: [VoiceCue] = []
        _ = cueOnce(key: NavigationVoiceGuidance.returnPhrase, phrase: NavigationVoiceGuidance.returnPhrase, into: &cues)
        return cues
    }

    /// Marks the explicit reroute. Does not replace the line.
    mutating func beginReroute() -> [PlannedRouteStop] {
        decision = .rerouteFromHere
        isRerouteInFlight = true
        rerouteFailed = false
        return PlannedRouteNavigation.remainingRequiredStops(on: line, progressedDistance: progressedDistance)
    }

    /// Replaces the locked line only after `beginReroute`, and only when the
    /// remaining selected stops still sit on `replacement`.
    mutating func applyReroute(_ replacement: PlannedNavigationReplacement) -> Bool {
        guard isRerouteInFlight, decision == .rerouteFromHere else { return false }
        let required = PlannedRouteNavigation.remainingRequiredStops(
            on: line,
            progressedDistance: progressedDistance
        )
        guard PlannedRouteNavigation.reroutePreservesStops(required, on: replacement.line.coordinates) else {
            return false
        }
        line = replacement.line
        maneuvers = replacement.maneuvers
        progressedDistance = 0
        decision = nil
        isRerouteInFlight = false
        rerouteFailed = false
        rerouteNote = replacement.note
        spokenKeys = []
        latest = nil
        return true
    }

    mutating func failReroute() {
        isRerouteInFlight = false
        decision = nil
        rerouteFailed = true
    }

    func display() -> PlannedNavigationDisplay {
        let along = latest?.distanceAlong ?? 0
        let extra = (latest?.isOffRoute == true) ? (latest?.returnDistance ?? 0) : 0
        let fuel = NavigationGuidance.fuelText(
            stops: line.stops,
            distanceAlong: latest == nil ? 0 : max(along, progressedDistance),
            extraMeters: extra,
            usesMetric: usesMetric
        )
        let upcoming = NavigationGuidance.nextManeuver(in: maneuvers, distanceAlong: along)

        switch phase {
        case .offRoutePrompt:
            return PlannedNavigationDisplay(
                phase: phase,
                arrowSymbol: "exclamationmark.triangle.fill",
                distanceText: NavigationGuidance.glanceDistance(latest?.distanceFromLine ?? 0, usesMetric: usesMetric),
                streetName: "Off your route",
                instruction: "Back to my route, or reroute from here.",
                fuelText: fuel,
                statusBanner: rerouteFailed ? "Couldn't reroute. Your planned line is unchanged." : nil,
                puckLatitude: latest?.latitude,
                puckLongitude: latest?.longitude
            )
        case .returning:
            return PlannedNavigationDisplay(
                phase: phase,
                arrowSymbol: NavigationGuidance.symbolName(for: .returnToRoute),
                distanceText: NavigationGuidance.glanceDistance(latest?.returnDistance ?? 0, usesMetric: usesMetric),
                streetName: "Back to my route",
                instruction: NavigationVoiceGuidance.returnPhrase,
                fuelText: fuel,
                statusBanner: nil,
                puckLatitude: latest?.latitude,
                puckLongitude: latest?.longitude
            )
        case .rerouting:
            return PlannedNavigationDisplay(
                phase: phase,
                arrowSymbol: "arrow.triangle.2.circlepath",
                distanceText: "…",
                streetName: "Rerouting",
                instruction: "Keeping your remaining stops.",
                fuelText: fuel,
                statusBanner: nil,
                puckLatitude: latest?.latitude,
                puckLongitude: latest?.longitude
            )
        case .arrived:
            let name = line.stops.last { $0.kind == .destination }?.name ?? "your destination"
            return PlannedNavigationDisplay(
                phase: phase,
                arrowSymbol: NavigationGuidance.symbolName(for: .arrive),
                distanceText: NavigationGuidance.glanceDistance(0, usesMetric: usesMetric),
                streetName: name,
                instruction: "Arrive at \(name)",
                fuelText: fuel,
                statusBanner: nil,
                puckLatitude: latest?.latitude,
                puckLongitude: latest?.longitude
            )
        case .onRoute:
            let maneuver = upcoming?.maneuver
            let remaining = upcoming?.distance ?? max(0, line.lengthMeters - along)
            let waitingForFix = latest == nil
            return PlannedNavigationDisplay(
                phase: phase,
                arrowSymbol: NavigationGuidance.symbolName(for: maneuver?.direction ?? .depart),
                distanceText: waitingForFix
                    ? "…"
                    : NavigationGuidance.glanceDistance(remaining, usesMetric: usesMetric),
                streetName: maneuver?.streetName ?? "Planned route",
                instruction: maneuver?.instruction ?? NavigationVoiceGuidance.departPhrase,
                fuelText: fuel,
                statusBanner: rerouteNote,
                puckLatitude: latest?.latitude,
                puckLongitude: latest?.longitude
            )
        }
    }

    private mutating func offRouteCues() -> [VoiceCue] {
        if isRerouteInFlight { return [] }
        var cues: [VoiceCue] = []
        if decision == .backToMyRoute {
            _ = cueOnce(key: NavigationVoiceGuidance.returnPhrase, phrase: NavigationVoiceGuidance.returnPhrase, into: &cues)
        } else {
            _ = cueOnce(key: NavigationVoiceGuidance.offRoutePhrase, phrase: NavigationVoiceGuidance.offRoutePhrase, into: &cues)
        }
        return cues
    }

    private mutating func cueOnce(key: String, phrase: String, into cues: inout [VoiceCue]) -> Bool {
        guard !spokenKeys.contains(key) else { return false }
        spokenKeys.insert(key)
        cues.append(VoiceCue(key: key, phrase: phrase))
        return true
    }
}
