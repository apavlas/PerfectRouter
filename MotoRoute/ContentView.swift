import SwiftUI
import MapKit

struct ContentView: View {
    @State private var viewModel = RoutePlannerViewModel()
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105), // Augusta, GA fallback
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ))
    )
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var searchText = ""
    @State private var searchResults: [MKMapItem] = []
    @State private var showSheet = true
    @State private var sheetDetent: PresentationDetent = .medium
    @State private var showingSaveDialog = false
    @State private var saveRouteName = ""
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingMapsChooser = false

    var body: some View {
        // MapReader exposes a proxy that converts a pressed screen point into a
        // map coordinate, so a long press can drop a start point on the map.
        MapReader { proxy in
            mapView
                .gesture(dropStartGesture(proxy: proxy))
        }
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
            // Recommended fuel stops are excluded here so they aren't drawn
            // twice (the Gas category's suggestions include them).
            ForEach(viewModel.suggestedStops.filter { !viewModel.isRecommendedFuelStop($0) }) { stop in
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
        .onAppear {
            viewModel.requestLocationPermission()
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
                searchSection
                rideSummarySection
                fuelRangeSection
                if viewModel.selectedCategory != .gas && !viewModel.legs.isEmpty {
                    gasStationsSection
                }
                waypointsSection
                suggestionsSection
                savedRoutesSection
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
                    if let url = viewModel.sharedRoute.shareURL {
                        ToolbarItem(placement: .topBarTrailing) {
                            ShareLink(
                                item: url,
                                subject: Text("MotoRoute Ride"),
                                message: Text(viewModel.sharedRoute.shareMessage)
                            ) {
                                Label("Share Route", systemImage: "square.and.arrow.up")
                            }
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
            .onChange(of: showingSettings) { _, isShowing in
                // Re-apply preferences when the Settings sheet closes.
                if !isShowing { viewModel.applySettings() }
            }
        }
    }

    /// Lists rides the rider has saved on this device. Tap to reload one,
    /// swipe to delete.
    private var savedRoutesSection: some View {
        Section("Saved Routes") {
            if viewModel.savedRoutes.isEmpty {
                Text("Save a ride with the bookmark button to find it here later.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.savedRoutes) { saved in
                Button {
                    loadSaved(saved)
                } label: {
                    HStack {
                        Image(systemName: "bookmark.fill")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(saved.name)
                            Text(saved.savedAt, format: .dateTime.month().day().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
                .buttonStyle(.plain)
            }
            .onDelete { viewModel.deleteSavedRoutes(at: $0) }
        }
    }

    /// Always-visible search field (replaces .searchable, which was hidden
    /// when the sheet sat at its smallest detent).
    private var searchSection: some View {
        Section {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Add a destination or stop", text: $searchText)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                        searchResults = []
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            // Live search, debounced: re-fires 0.4s after the user stops typing.
            .task(id: searchText) {
                guard !searchText.isEmpty else {
                    searchResults = []
                    return
                }
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled else { return }
                searchResults = await viewModel.searchPlaces(query: searchText, near: currentRegion)
                    .filter { $0.placemark.coordinate.isValidLocation }
            }

            ForEach(searchResults.prefix(6), id: \.self) { item in
                Button {
                    addSearchResult(item)
                } label: {
                    HStack {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Unknown")
                            if let locality = item.placemark.locality {
                                Text(locality)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var rideSummarySection: some View {
        Section {
            if viewModel.isCalculating {
                ProgressView("Calculating route…")
            } else if !viewModel.legs.isEmpty {
                HStack {
                    Label(formattedDistance(viewModel.totalDistanceMeters), systemImage: "road.lanes")
                    Spacer()
                    Label(formattedDuration(viewModel.totalExpectedTravelTime), systemImage: "clock")
                }
                ForEach(Array(viewModel.fuelStops.enumerated()), id: \.element.id) { index, fuelStop in
                    Label("Fuel stop \(index + 1): \(fuelStop.name) (~\(formattedDistance(fuelStop.distanceAlongRoute)) in)",
                          systemImage: "fuelpump.fill")
                        .foregroundStyle(.green)
                }
                if viewModel.hasFuelGap {
                    Label("No gas station found within your fuel range on part of this route — consider a different path.",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                if let rainWarning = viewModel.rainWarning {
                    Label(rainWarning, systemImage: "cloud.rain.fill")
                        .foregroundStyle(.blue)
                } else if viewModel.isCheckingWeather {
                    Label("Checking weather along your route…", systemImage: "cloud.sun.fill")
                        .foregroundStyle(.secondary)
                }
                Button {
                    handleOpenInMaps()
                } label: {
                    Label("Open in Maps", systemImage: "location.north.line.fill")
                }
            }
            if let here = viewModel.currentLocation,
               let shareURL = NavigationLauncher.currentLocationShareURL(here) {
                ShareLink(
                    item: shareURL,
                    subject: Text("My location"),
                    message: Text("Here's where I am right now.")
                ) {
                    Label("Share Current Location", systemImage: "dot.radiowaves.left.and.right")
                }
            }
            if let error = viewModel.errorMessage {
                Text(error).foregroundStyle(.red)
            }
        }
        .confirmationDialog("Open route in", isPresented: $showingMapsChooser, titleVisibility: .visible) {
            Button("Apple Maps") { launchAppleMaps() }
            Button("Google Maps") { launchGoogleMaps() }
            Button("Cancel", role: .cancel) { }
        }
    }

    /// Hands off to a navigation app. If Google Maps is installed the rider can
    /// choose; otherwise Apple Maps opens. The ride is logged only when a
    /// navigation app is actually launched (not if the rider cancels).
    private func handleOpenInMaps() {
        if NavigationLauncher.isGoogleMapsAvailable {
            showingMapsChooser = true
        } else {
            launchAppleMaps()
        }
    }

    private func launchAppleMaps() {
        viewModel.logCurrentRide()
        NavigationLauncher.openInAppleMaps(viewModel.waypoints)
    }

    private func launchGoogleMaps() {
        viewModel.logCurrentRide()
        NavigationLauncher.openInGoogleMaps(viewModel.waypoints)
    }

    /// Lets the rider set their tank range, which drives how often gas stops
    /// are recommended. Re-plans fuel stops when the rider finishes adjusting.
    private var fuelRangeSection: some View {
        Section("Fuel Range") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Tank range", systemImage: "fuelpump.fill")
                    Spacer()
                    Text("\(Int(fuelRangeMiles.rounded())) mi")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: fuelRangeMilesBinding,
                    in: 50...300,
                    step: 10,
                    label: { Text("Tank range") },
                    minimumValueLabel: { Text("50").font(.caption2).foregroundStyle(.secondary) },
                    maximumValueLabel: { Text("300").font(.caption2).foregroundStyle(.secondary) },
                    onEditingChanged: { editing in
                        // Re-plan only when the drag ends. No network search —
                        // just re-selects from the gas stations already loaded.
                        if !editing {
                            viewModel.replanFuelStops()
                        }
                    }
                )
            }
        }
    }

    /// Lists every gas station found along the route so the rider can pick any
    /// of them. The auto-recommended fuel stops are badged. Shown while
    /// browsing a non-gas category (the Gas category already lists these in
    /// the suggestions section).
    private var gasStationsSection: some View {
        Section("Gas Stations on Route") {
            if viewModel.gasStations.isEmpty {
                Text("No gas stations found along this route.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.gasStations) { stop in
                Button {
                    viewModel.addStop(from: stop)
                } label: {
                    HStack {
                        Image(systemName: "fuelpump.fill")
                            .foregroundStyle(viewModel.isRecommendedFuelStop(stop) ? .green : .secondary)
                        VStack(alignment: .leading) {
                            Text(stop.name)
                            Text("~\(formattedDistance(stop.distanceAlongRoute)) from start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewModel.isRecommendedFuelStop(stop) {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.green)
                        }
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var waypointsSection: some View {
        Section("Route (\(viewModel.waypoints.count) stops)") {
            if viewModel.waypoints.isEmpty {
                Text(viewModel.currentLocation == nil
                     ? "Long-press the map or use the button below to set a start, then search for your destination."
                     : "Search for your destination — we'll route from your current location.")
                    .foregroundStyle(.secondary)
            }
            // When there's no location fix to auto-seed the origin, let the
            // rider drop a start point at the center of the visible map. A new
            // start is inserted ahead of any place already added, so it becomes
            // the ride origin.
            if viewModel.currentLocation == nil, viewModel.waypoints.count < 2 {
                Button {
                    addStartFromMapCenter()
                } label: {
                    Label("Use Current Map Area as Start", systemImage: "mappin.and.ellipse")
                }
            }
            ForEach(viewModel.waypoints) { waypoint in
                Label(waypoint.name, systemImage: "mappin.circle.fill")
            }
            .onDelete { viewModel.removeWaypoint(at: $0) }
            .onMove { viewModel.moveWaypoint(from: $0, to: $1) }
        }
    }

    private var suggestionsSection: some View {
        Section("Suggested \(viewModel.selectedCategory.rawValue) Stops") {
            if viewModel.isLoadingSuggestions {
                ProgressView("Searching along your route…")
            } else if viewModel.suggestedStops.isEmpty && !viewModel.legs.isEmpty {
                Text("No \(viewModel.selectedCategory.rawValue.lowercased()) stops found near this route.")
                    .foregroundStyle(.secondary)
            } else if viewModel.legs.isEmpty {
                Text("Add at least two stops to see suggestions.")
                    .foregroundStyle(.secondary)
            }
            ForEach(viewModel.suggestedStops.prefix(15)) { stop in
                Button {
                    viewModel.addStop(from: stop)
                } label: {
                    HStack {
                        Image(systemName: stop.category.systemImage)
                        VStack(alignment: .leading) {
                            Text(stop.name)
                            Text("~\(formattedDistance(stop.distanceAlongRoute)) from start")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus.circle.fill")
                            .foregroundStyle(.blue)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions & helpers

    private static let metersPerMile: CLLocationDistance = 1609.344

    /// The view model's fuel range expressed in miles, for display.
    private var fuelRangeMiles: Double {
        viewModel.fuelRangeMeters / Self.metersPerMile
    }

    /// Two-way binding that exposes the fuel range (stored in meters) as miles
    /// for the slider.
    private var fuelRangeMilesBinding: Binding<Double> {
        Binding(
            get: { viewModel.fuelRangeMeters / Self.metersPerMile },
            set: { viewModel.fuelRangeMeters = $0 * Self.metersPerMile }
        )
    }

    private var currentRegion: MKCoordinateRegion {
        visibleRegion ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105),
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )
    }

    private func addSearchResult(_ item: MKMapItem) {
        let coordinate = item.placemark.coordinate
        // Ignore results with no usable coordinate (invalid / NaN) — adding one
        // would crash MapKit when routing or recentering the map on it.
        guard coordinate.isValidLocation else { return }
        let waypoint = Waypoint(name: item.name ?? "Stop", coordinate: coordinate)
        viewModel.addWaypoint(waypoint)
        searchResults = []
        searchText = ""
        recenter(on: waypoint.coordinate, spanDelta: 0.3)
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

    private func formattedDistance(_ meters: CLLocationDistance) -> String {
        formattedRideDistance(meters)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds).formatted(
            .units(allowed: [.hours, .minutes], width: .abbreviated)
        )
    }
}

#Preview {
    ContentView()
}
