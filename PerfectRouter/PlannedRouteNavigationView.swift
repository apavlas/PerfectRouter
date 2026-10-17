import MapKit
import SwiftUI

/// In-app turn-by-turn. The arrow, distance, and street are sized to be read
/// with gloves. The next fuel distance stays on screen in every phase,
/// including the off-route choice. Nothing on this screen starts a reroute
/// by itself.
struct PlannedRouteNavigationView: View {
    var display: PlannedNavigationDisplay
    var routeCoordinates: [CLLocationCoordinate2D]
    var onBackToRoute: () -> Void
    var onReroute: () -> Void
    var onEnd: () -> Void

    @State private var cameraPosition: MapCameraPosition = .automatic

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height && geo.size.width > 700
            Group {
                if landscape {
                    HStack(spacing: 0) {
                        routeMap
                        guidanceCard
                            .frame(width: min(440, geo.size.width * 0.46))
                    }
                } else {
                    VStack(spacing: 0) {
                        routeMap
                        guidanceCard
                    }
                }
            }
        }
        .background(Color.black)
        .accessibilityIdentifier(AccessibilityID.plannedNavigation)
        .onAppear(perform: frameRider)
        .onChange(of: display.puckLatitude) { _, _ in frameRider() }
        .onChange(of: display.puckLongitude) { _, _ in frameRider() }
    }

    private var routeMap: some View {
        Map(position: $cameraPosition) {
            if let polyline = lockedPolyline {
                MapPolyline(polyline)
                    .stroke(Color.cyan, lineWidth: 8)
            }
            UserAnnotation()
        }
        .mapStyle(.standard)
        .accessibilityLabel("Planned route")
    }

    private var lockedPolyline: MKPolyline? {
        guard routeCoordinates.count >= 2 else { return nil }
        var coordinates = routeCoordinates
        return MKPolyline(coordinates: &coordinates, count: coordinates.count)
    }

    private var guidanceCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button(action: onEnd) {
                    Text("End")
                        .font(.title3.weight(.bold))
                        .frame(minWidth: 72, minHeight: 56)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityIdentifier(AccessibilityID.endNavigation)
                Spacer()
            }

            if let banner = display.statusBanner {
                Text(banner)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Image(systemName: display.arrowSymbol)
                .font(.system(size: 96, weight: .bold))
                .foregroundStyle(.yellow)
                .frame(maxWidth: .infinity, minHeight: 110)
                .accessibilityIdentifier(AccessibilityID.nextTurnArrow)
                .accessibilityLabel(display.instruction)

            Text(display.distanceText)
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .accessibilityIdentifier(AccessibilityID.nextTurnDistance)

            Text(display.streetName)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityIdentifier(AccessibilityID.nextTurnStreet)

            Text(display.instruction)
                .font(.title3.weight(.medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .minimumScaleFactor(0.7)

            if display.phase == .offRoutePrompt || display.phase == .returning {
                offRouteActions
            }

            Spacer(minLength: 0)

            Label(display.fuelText, systemImage: "fuelpump.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.yellow, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier(AccessibilityID.nextFuelDistance)
                .accessibilityLabel(display.fuelText)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
    }

    /// "Back to my route" is the default: filled, first, and taller.
    /// "Reroute from here" is explicit and secondary. Neither runs on appear.
    private var offRouteActions: some View {
        VStack(spacing: 12) {
            Button(action: onBackToRoute) {
                Text("Back to my route")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 72)
                    .background(Color.yellow, in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.backToMyRoute)
            .accessibilityHint("Default. Keeps your planned line.")

            Button(action: onReroute) {
                Text("Reroute from here")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 64)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(Color.white, lineWidth: 2)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.rerouteFromHere)
            .accessibilityHint("Builds a new line through your remaining stops.")
        }
    }

    private func frameRider() {
        let center: CLLocationCoordinate2D
        if let latitude = display.puckLatitude, let longitude = display.puckLongitude {
            center = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        } else if let first = routeCoordinates.first {
            center = first
        } else {
            return
        }
        guard center.isValidLocation else { return }
        cameraPosition = .region(MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: 0.04, longitudeDelta: 0.04)
        ))
    }
}

/// Presents a session. Location starts when the screen appears and stops
/// when it disappears. The off-route buttons are the only way to reroute.
struct PlannedRouteNavigationScreen: View {
    var session: PlannedRouteNavigationSession
    var onEnd: () -> Void

    var body: some View {
        PlannedRouteNavigationView(
            display: session.display,
            routeCoordinates: session.routeCoordinates,
            onBackToRoute: { session.chooseBackToMyRoute() },
            onReroute: { Task { await session.chooseRerouteFromHere() } },
            onEnd: {
                session.stop()
                onEnd()
            }
        )
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }
}

#Preview {
    PlannedRouteNavigationView(
        display: PlannedNavigationDisplay(
            phase: .onRoute,
            arrowSymbol: "arrow.turn.up.left",
            distanceText: "500 ft",
            streetName: "Ridge Road",
            instruction: "Turn left onto Ridge Road",
            fuelText: "Fuel in 12.0 mi",
            statusBanner: nil,
            puckLatitude: 33.47,
            puckLongitude: -82.01
        ),
        routeCoordinates: [
            CLLocationCoordinate2D(latitude: 33.47, longitude: -82.05),
            CLLocationCoordinate2D(latitude: 33.50, longitude: -82.01),
            CLLocationCoordinate2D(latitude: 33.50, longitude: -81.90),
        ],
        onBackToRoute: {},
        onReroute: {},
        onEnd: {}
    )
}
