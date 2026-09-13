import SwiftUI
import MapKit

struct ContentView: View {
    /// Becomes `true` once the launch splash has faded, signaling that it's a
    /// good time to ask for location permission (so the system alert doesn't
    /// pop up over the splash animation). Defaults to `true` for previews.
    var readyForPermissions = true

    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = RoutePlannerViewModel()
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105), // Augusta, GA fallback
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ))
    )
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var showSheet = true
    @State private var sheetDetent: PresentationDetent = .medium
    @State private var showingSaveDialog = false
    @State private var saveRouteName = ""
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingShareRide = false
    @State private var showingRiderGroups = false

    var body: some View {
        GeometryReader { geo in
            // MapReader exposes a proxy that converts a pressed screen point
            // into a map coordinate, so a long press can drop a start point.
            MapReader { proxy in
                mapView
                    .gesture(dropStartGesture(proxy: proxy))
            }
            // Mirror the planning sheet as a bottom safe-area inset so the
            // map centers content — and frames routes — in the area the sheet
            // doesn't cover. Without this a computed route can sit entirely
            // behind the sheet and look like it never appeared.
            .safeAreaPadding(.bottom, geo.size.height * sheetObscuredFraction)
        }
    }

    /// Roughly how much of the screen the planning sheet covers at the
    /// current detent.
    private var sheetObscuredFraction: CGFloat {
        sheetDetent == .fraction(0.15) ? 0.15 : 0.5
    }

    private var mapView: some View {
        Map(position: $cameraPosition) {
            UserAnnotation()

            // Waypoint markers
            ForEach(Array(viewModel.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                Marker(waypoint.name, systemImage: markerIcon(for: index), coordinate: waypoint.coordinate)
                    .tint(index == 0 ? .green : (index == viewModel.waypoints.count - 1 ? .red : .orange))
            }

            // Route polylines, one per leg
            ForEach(viewModel.legs, id: \.self) { leg in
                MapPolyline(leg.polyline)
                    .stroke(.blue, lineWidth: 5)
            }


            // Non-recommended gas stations along the route — pickable while
            // browsing another category. Drawn neutral/gray and excluding the
            // recommended stops, which get their own highlighted layer below.
            // Hidden in the Gas category, where the suggestions layer covers them.
            if viewModel.selectedCategory != .gas {
                ForEach(viewModel.gasStations.filter { !viewModel.isRecommendedFuelStop($0) }) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        Button {
                            viewModel.addStop(from: stop)
                        } label: {
                            Image(systemName: "fuelpump.fill")
                                .font(.caption)
                                .padding(6)
                                .background(Color.gray, in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                }
            }

            // Suggested stops for the selected category — tap a pin to add it.
            // Recommended fuel stops and ride highlights are excluded here so
            // they aren't drawn twice (their own highlighted layers cover them).
            ForEach(viewModel.suggestedStops.filter {
                !viewModel.isRecommendedFuelStop($0) && !viewModel.isRideHighlight($0)
            }) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Button {
                        viewModel.addStop(from: stop)
                    } label: {
                        Image(systemName: stop.category.systemImage)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                    }
                }
            }

            // Recommended ride highlights — purple star pins so places worth
            // a stop stand out from ordinary suggestions.
            ForEach(viewModel.rideHighlights) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Button {
                        viewModel.addStop(from: stop)
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.purple, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(radius: 3)
                    }
                }
            }

            // Recommended fuel stops (one per tank) — drawn last so they sit on
            // top, and highlighted (larger, ringed green pump) so they're easy
            // to pick out in any category. Exactly one marker per recommended
            // stop, across all the layers above.
            ForEach(viewModel.fuelStops) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Button {
                        viewModel.addStop(from: stop)
                    } label: {
                        Image(systemName: "fuelpump.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.green, in: Circle())
                            .overlay(Circle().stroke(.white, lineWidth: 2.5))
                            .shadow(radius: 3)
                    }
                }
            }
        }
        .onMapCameraChange { context in
            visibleRegion = context.region
        }
        .onChange(of: readyForPermissions, initial: true) { _, ready in
            // Wait for the splash to clear before prompting for location.
            // Riders already authorized from a previous launch keep tracking
            // (started in the view model's init) regardless of this prompt.
            if ready {
                viewModel.requestLocationPermission()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Location updates stop after each fix (battery); grab a fresh fix
            // whenever the rider comes back to the app.
            if phase == .active {
                viewModel.refreshLocation()
            }
        }
        .onChange(of: viewModel.legs) { _, legs in
            // Whenever a route lands, frame the whole ride on screen. Without
            // this the camera stays wherever the rider left it (or centered on
            // the destination), and the polyline can sit entirely behind the
            // planning sheet — "the route doesn't show".
            if !legs.isEmpty {
                frameRoute(legs)
            }
        }
        .task {
            // Debug harness: when launched with --auto-route-test (e.g. via
            // `simctl launch <udid> <bundle-id> --auto-route-test`), add a
            // fixed destination two seconds in — the same `addWaypoint` call a
            // search-result tap makes — so the full route pipeline can be
            // exercised and screenshotted from the CLI without UI taps.
            // Inert in normal launches.
            guard ProcessInfo.processInfo.arguments.contains("--auto-route-test") else { return }
            try? await Task.sleep(for: .seconds(2))
            viewModel.addWaypoint(Waypoint(
                name: "Atlanta",
                coordinate: CLLocationCoordinate2D(latitude: 33.749, longitude: -84.388)
            ))
        }
        .onOpenURL { url in
            if viewModel.importRoute(from: url),
               let start = viewModel.waypoints.first {
                showSheet = true
                recenter(on: start.coordinate, spanDelta: 0.5)
            }
        }
        .safeAreaInset(edge: .top) {
            categoryPicker
        }
        .sheet(isPresented: $showSheet) {
            planningSheet
                .presentationDetents([.fraction(0.15), .medium, .large], selection: $sheetDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
    }

    // MARK: - Category chips

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(StopCategory.allCases) { category in
                    Button {
                        viewModel.selectCategory(category)
                    } label: {
                        Label(category.rawValue, systemImage: category.systemImage)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                viewModel.selectedCategory == category ? Color.blue : Color(.systemBackground),
                                in: Capsule()
                            )
                            .foregroundStyle(viewModel.selectedCategory == category ? .white : .primary)
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    // MARK: - Bottom sheet

    private var planningSheet: some View {
        NavigationStack {
            List {
                // AC-S1: search → waypoints → summary (Navigate) → highlights
                // → suggestions → gas → prefs (fuel / leave later / style) →
                // saved routes. Cold-plan Search + Summary stay above prefs so
                // medium detent can act without scrolling past ride settings.
                SearchSection(
                    viewModel: viewModel,
                    currentRegion: currentRegion,
                    onWaypointAdded: { recenter(on: $0.coordinate, spanDelta: 0.3) }
                )
                WaypointsSection(viewModel: viewModel, onUseMapCenterAsStart: addStartFromMapCenter)
                RideSummarySection(viewModel: viewModel)
                if !viewModel.rideHighlights.isEmpty {
                    RideHighlightsSection(viewModel: viewModel)
                }
                SuggestionsSection(viewModel: viewModel)
                if viewModel.selectedCategory != .gas && !viewModel.legs.isEmpty {
                    GasStationsSection(viewModel: viewModel)
                }
                FuelRangeSection(viewModel: viewModel)
                DepartureSection(viewModel: viewModel)
                RouteStyleSection(viewModel: viewModel)
                SavedRoutesSection(viewModel: viewModel, onLoad: loadSaved)
            }
            .navigationTitle("Plan Ride")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                        }
                        Button {
                            showingHistory = true
                        } label: {
                            Label("Ride History", systemImage: "clock.arrow.circlepath")
                        }
                        Button {
                            showingRiderGroups = true
                        } label: {
                            Label("Rider Groups", systemImage: "person.2")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
                if viewModel.canShareRoute {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            saveRouteName = viewModel.defaultRouteName
                            showingSaveDialog = true
                        } label: {
                            Label("Save Route", systemImage: "bookmark")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingShareRide = true
                        } label: {
                            Label("Share Route", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .alert("Save Route", isPresented: $showingSaveDialog) {
                TextField("Route name", text: $saveRouteName)
                Button("Cancel", role: .cancel) { }
                Button("Save") { viewModel.saveCurrentRoute(name: saveRouteName) }
            } message: {
                Text("Name this ride so you can reload it later.")
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .sheet(isPresented: $showingHistory) {
                RideHistoryView()
            }
            .sheet(isPresented: $showingShareRide) {
                ShareRideView(viewModel: viewModel)
            }
            .sheet(isPresented: $showingRiderGroups) {
                RiderGroupsView(viewModel: viewModel)
            }
            .onChange(of: showingSettings) { _, isShowing in
                // Re-apply preferences when the Settings sheet closes.
                if !isShowing { viewModel.applySettings() }
            }
        }
    }

    // MARK: - Actions & helpers

    private var currentRegion: MKCoordinateRegion {
        visibleRegion ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105),
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )
    }

    /// Frames the full route in the map's visible (safe) area. The bottom
    /// safe-area inset applied in `body` keeps the framing clear of the
    /// planning sheet.
    private func frameRoute(_ legs: [MKRoute]) {
        var rect = MKMapRect.null
        for leg in legs {
            rect = rect.union(leg.polyline.boundingMapRect)
        }
        guard !rect.isNull else { return }
        let padded = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.15)
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .rect(padded)
        }
    }

    /// Recenters the map on a coordinate, ignoring invalid / NaN coordinates
    /// that would trip a MapKit assertion when used as a region center.
    private func recenter(on coordinate: CLLocationCoordinate2D, spanDelta: CLLocationDegrees) {
        guard coordinate.isValidLocation else { return }
        cameraPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: spanDelta, longitudeDelta: spanDelta)
        ))
    }

    /// A long press on the map drops a start point at the pressed location.
    /// Sequencing a zero-distance drag after the long press surfaces the touch
    /// point, which the map proxy converts into a coordinate.
    private func dropStartGesture(proxy: MapProxy) -> some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                guard case let .second(true, drag?) = value,
                      let coordinate = proxy.convert(drag.location, from: .local) else { return }
                dropStart(at: coordinate)
            }
    }

    /// Reverse-geocodes a readable name for the coordinate (best effort) and
    /// adds it as the ride origin.
    private func dropStart(at coordinate: CLLocationCoordinate2D) {
        Task {
            let name = await reverseGeocodedName(for: coordinate) ?? "Start"
            viewModel.addStart(Waypoint(name: name, coordinate: coordinate))
        }
    }

    /// Drops a start point at the center of the visible map, used when there's
    /// no location fix to route from, then recenters on the new origin.
    private func addStartFromMapCenter() {
        let center = currentRegion.center
        dropStart(at: center)
        recenter(on: center, spanDelta: 0.3)
    }

    /// A human-readable name for a coordinate (place name or locality), or
    /// `nil` if reverse geocoding is unavailable.
    private func reverseGeocodedName(for coordinate: CLLocationCoordinate2D) async -> String? {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
        return placemark?.name ?? placemark?.locality
    }

    /// Loads a saved ride and frames its start on the map.
    private func loadSaved(_ saved: SavedRoute) {
        viewModel.loadSavedRoute(saved)
        if let start = viewModel.waypoints.first {
            recenter(on: start.coordinate, spanDelta: 0.5)
        }
    }

    private func markerIcon(for index: Int) -> String {
        if index == 0 { return "flag.fill" }
        if index == viewModel.waypoints.count - 1 { return "flag.checkered" }
        return "mappin"
    }
}

#Preview {
    ContentView()
}
