import SwiftUI
import MapKit
import UIKit

/// Nav-bar copy of the replan sentence. A large iPad sheet covers the map
/// chip, and the in-list row is gone once that section scrolls away. The
/// idle glyph stays in the item so the bar never drops to zero focus children.
private struct NavigationReplanBanner: View {
    var calculating: Bool
    var status: String

    var body: some View {
        Text(verbatim: calculating ? status : "·")
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .opacity(calculating ? 1 : 0)
            .accessibilityIdentifier(calculating ? AccessibilityID.replanBanner : "replanNavIdle")
            .accessibilityLabel(calculating ? status : "Idle")
            .accessibilityHidden(!calculating)
            .allowsHitTesting(false)
            .focusable()
    }
}

struct ContentView: View {
    /// Becomes `true` once the launch splash has faded, signaling that it's a
    /// good time to ask for location permission (so the system alert doesn't
    /// pop up over the splash animation). Defaults to `true` for previews.
    var readyForPermissions = true
    /// When `false` (first-run still showing), the planning sheet stays hidden
    /// so it cannot cover the intro. Defaults to `true` for previews.
    var planningSheetEnabled = true

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var viewModel = RoutePlannerViewModel()
    /// Map selection for waypoint and stop pins. Only the sidebar map reads it.
    @State private var selectedPinID: UUID?
    /// Kept at `.all` so iPad landscape and Mac show the list and the map
    /// together. Not written during focus changes.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var cameraPosition: MapCameraPosition = .userLocation(
        fallback: .region(MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105), // Augusta, GA fallback
            span: MKCoordinateSpan(latitudeDelta: 0.5, longitudeDelta: 0.5)
        ))
    )
    /// Set when a route is framed. The label is the camera center so a UI
    /// test can tell the ride from the device location.
    @State private var framedRoute: RouteMapFrame?
    /// Padding from the last route fit. Label is "top,left,bottom,right".
    @State private var mapFitPadding = MapFitPadding.zero
    /// Advances on load, replan, and Apply. A sheet drag does not advance it.
    @State private var mapFitGeneration = 0
    @State private var mapGlobalFrame: CGRect = .zero
    @State private var sheetGlobalFrame: CGRect = .zero
    @State private var topControlsGlobalFrame: CGRect = .zero
    @State private var mapSafeArea = EdgeInsets()
    @State private var mapUsesSidebar = false
    /// A fit is waiting for the sheet and chip bar to report frames.
    @State private var fitAwaitingChrome = false
    /// True after the current legs have been fitted. A grabber drag must
    /// not fit again; the next load, replan, or Apply clears this.
    @State private var didFitCurrentLegs = false
    /// Camera callbacks caused by our own fit. A rider pan lands at zero.
    @State private var programmaticCameraEvents = 0
    /// True after the rider pans or zooms since the last route fit.
    @State private var riderAdjustedCamera = false
    /// The sheet frame has held still long enough to be the resting detent.
    /// The presentation animation reports the large host first; fitting that
    /// frame locks the camera under the card.
    @State private var sheetStable = false
    @State private var sheetStableTask: Task<Void, Never>?
    @State private var visibleRegion: MKCoordinateRegion?
    @State private var showSheet = true
    @State private var sheetDetent: PresentationDetent = UITestStubLaunch.isEnabled ? .large : .medium
    @State private var showingSaveDialog = false
    @State private var saveRouteName = ""
    @State private var showingSettings = false
    @State private var showingHistory = false
    @State private var showingShareRide = false
    @State private var showingRiderGroups = false
    /// Full place description. Held here, not on a list row: a `.sheet` inside
    /// a `List` section does not present when the row handles the tap.
    @State private var openPlaceDescription: OpenPlaceDescription?

    var body: some View {
        GeometryReader { geo in
            // One branch per layout. It flips when the window crosses from
            // portrait to landscape (or onto a Mac), not when a text field
            // resigns — that swap is what left iPad's focus system with an
            // empty container.
            let sidebar = PlanningChrome.resolve(
                container: geo.size,
                horizontalSizeClass: horizontalSizeClass,
                idiom: UIDevice.current.userInterfaceIdiom,
                runsOnMac: PlanningChrome.runsOnMac
            ) == .sidebar
            Group {
                if sidebar {
                    NavigationSplitView(columnVisibility: $columnVisibility) {
                        planningSheet
                            .environment(\.planningUsesSidebar, true)
                            .navigationSplitViewColumnWidth(min: 300, ideal: 380, max: 480)
                            .accessibilityIdentifier("routeSidebar")
                    } detail: {
                        mapColumn(usesSidebar: true)
                            // The detail column's own bar would sit on top of
                            // the map. The route list keeps "Plan Ride".
                            .toolbar(.hidden, for: .navigationBar)
                    }
                    .navigationSplitViewStyle(.balanced)
                } else {
                    mapColumn(usesSidebar: false)
                        .sheet(isPresented: Binding(
                            get: { showSheet && planningSheetEnabled },
                            set: { showSheet = $0 }
                        )) {
                            planningSheet
                                .environment(\.planningUsesSidebar, false)
                                .presentationDetents(
                                    // The first detent is what the system uses if it ignores the
                                    // selection binding. UI tests need the large one so list rows
                                    // are in the accessibility tree; riders still open at medium.
                                    UITestStubLaunch.isEnabled
                                        ? [.large, .medium, .fraction(0.15)]
                                        : [.fraction(0.15), .medium, .large],
                                    selection: $sheetDetent
                                )
                                // A downward drag at the top of the list otherwise shrinks the
                                // sheet, which drops the fuel rows out of the accessibility tree.
                                .presentationContentInteraction(UITestStubLaunch.isEnabled ? .scrolls : .automatic)
                                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                                .interactiveDismissDisabled()
                        }
                }
            }
            .onChange(of: viewModel.mapCenterToken) { _, _ in
                guard sidebar, let coordinate = viewModel.mapCenterCoordinate else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    recenter(on: coordinate, spanDelta: 0.35)
                }
            }
            .onChange(of: viewModel.highlightedStopID) { _, id in
                guard sidebar, selectedPinID != id else { return }
                selectedPinID = id
            }
            // GeometryReader does not always pass a bounded size through to
            // NavigationSplitView. Pin the column to the window.
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// MapReader exposes a proxy that converts a pressed screen point into a
    /// map coordinate, so a long press can drop a start point.
    private func mapColumn(usesSidebar: Bool) -> some View {
        MapReader { proxy in
            map(usesSidebar: usesSidebar)
                .gesture(dropStartGesture(proxy: proxy))
        }
    }

    /// Phone and portrait use the original map. The sidebar map adds
    /// selection so a pin tap can point at a row. Two initializers keep the
    /// phone map from growing a selection binding.
    @ViewBuilder
    private func map(usesSidebar: Bool) -> some View {
        if usesSidebar {
            decoratedMap(Map(position: $cameraPosition, selection: $selectedPinID) {
                mapContents(usesSidebar: true)
            }, usesSidebar: true)
        } else {
            decoratedMap(Map(position: $cameraPosition) {
                mapContents(usesSidebar: false)
            }, usesSidebar: false)
        }
    }

    private func decoratedMap<V: View>(_ map: V, usesSidebar: Bool) -> some View {
        map
        .overlay {
            MapFitViewportReporter { frame, insets in
                noteMapViewport(frame, safeArea: insets)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            visibleRegion = context.region
            if programmaticCameraEvents > 0 {
                programmaticCameraEvents -= 1
                return
            }
            // A pan or zoom after the fit belongs to the rider until the
            // next load, replan, or Apply. Sheet drags never reach here.
            guard mapFitGeneration > 0 else { return }
            riderAdjustedCamera = true
            fitAwaitingChrome = false
        }
        .onChange(of: readyForPermissions, initial: true) { _, ready in
            // Wait for the splash (and first-run, when shown) to clear before
            // prompting for location, so the system alert doesn't sit over
            // those screens. Riders already authorized from a previous launch
            // keep tracking (started in the view model's init) regardless.
            if ready {
                viewModel.applySettings(seedFuelRange: true)
                // UI tests stub location and must not raise the system alert.
                if !UITestStubLaunch.isEnabled {
                    viewModel.requestLocationPermission()
                }
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
            // A new line is a load, a replan, or Apply. Fit once for that
            // line. Dragging the sheet does not publish legs, so it leaves
            // the camera where the rider put it.
            guard !legs.isEmpty else { return }
            didFitCurrentLegs = false
            riderAdjustedCamera = false
            fitRouteToVisibleMap(legs)
        }
        .onChange(of: usesSidebar) { _, sidebar in
            mapUsesSidebar = sidebar
        }
        .onAppear {
            mapUsesSidebar = usesSidebar
            // A detent drag can rebuild the map. That appearance is not a
            // new route, so it must not move the camera.
            guard !viewModel.legs.isEmpty, !didFitCurrentLegs else { return }
            riderAdjustedCamera = false
            fitRouteToVisibleMap(viewModel.legs)
        }
        .onChange(of: selectedPinID) { _, id in
            // Marker taps set the binding. Annotation buttons set it too.
            // Phone and portrait have no selection binding, so this stays nil.
            guard usesSidebar else { return }
            guard let id else {
                if viewModel.highlightedStopID != nil {
                    viewModel.highlightedStopID = nil
                }
                return
            }
            guard viewModel.highlightedStopID != id else { return }
            viewModel.highlightListedStop(id: id)
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
        .safeAreaInset(edge: .top, spacing: 0) {
            // Two complete stacks. A banner `if` inside the chip stack is an
            // empty focus container on the frames it is hidden, which is
            // when a replan starts and ends.
            mapTopChrome
        }
        .overlay(alignment: .topLeading) {
            // Always in the tree. Hidden until a route is framed, then the
            // label is the camera center ("lat,lon").
            Text(verbatim: framedRoute?.accessibilityLabel ?? "")
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(width: 8, height: 8)
                .accessibilityIdentifier(AccessibilityID.routeMapFrame)
                .accessibilityLabel(framedRoute?.accessibilityLabel ?? "")
                .accessibilityHidden(framedRoute == nil)
                .allowsHitTesting(false)
        }
    }

    /// Sidebar pin tap highlights the matching row. Phone and portrait keep
    /// the add / toggle action.
    private func handlePinTap(id: UUID, usesSidebar: Bool, action: () -> Void) {
        if usesSidebar {
            selectedPinID = id
            viewModel.highlightListedStop(id: id)
        } else {
            action()
        }
    }

    @MapContentBuilder
    private func mapContents(usesSidebar: Bool) -> some MapContent {
            UserAnnotation()

            // Waypoint markers. An empty ForEach is omitted: during a replan
            // it is a focus container with no children. Tags are inert on the
            // phone map, which has no selection binding.
            if !viewModel.waypoints.isEmpty {
                ForEach(Array(viewModel.waypoints.enumerated()), id: \.element.id) { index, waypoint in
                    Marker(waypoint.name, systemImage: markerIcon(for: index), coordinate: waypoint.coordinate)
                        .tint(index == 0 ? .green : (index == viewModel.waypoints.count - 1 ? .red : .orange))
                        .tag(waypoint.id)
                }
            }

            // Route polylines, one per leg
            if !viewModel.legs.isEmpty {
                ForEach(viewModel.legs, id: \.self) { leg in
                    MapPolyline(leg.polyline)
                        .stroke(
                            viewModel.dimsRouteLine ? Color.blue.opacity(0.35) : Color.blue,
                            lineWidth: 5
                        )
                }
            }


            // Non-recommended gas stations — only while the sheet's
            // "All gas on route" list is open. Recommended pumps and the
            // selected-category pins stay regardless. Hidden in Gas, where
            // the suggestions layer already covers stations.
            if viewModel.showsAllGasPins, !extraGasPins.isEmpty {
                ForEach(extraGasPins) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        Button {
                            handlePinTap(id: stop.id, usesSidebar: usesSidebar) {
                                viewModel.toggleBufferedGasStop(stop)
                            }
                        } label: {
                            Image(systemName: viewModel.isGasBuffered(stop) ? "checkmark" : "fuelpump.fill")
                                .font(.caption)
                                .padding(6)
                                .background(viewModel.isGasBuffered(stop) ? Color.blue : Color.gray, in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    .tag(stop.id)
                }
            }

            // Suggested stops for the selected category — tap a pin to add it.
            // Recommended fuel stops and ride highlights are excluded here so
            // they aren't drawn twice (their own highlighted layers cover them).
            if !categoryPins.isEmpty {
            ForEach(categoryPins) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Button {
                        handlePinTap(id: stop.id, usesSidebar: usesSidebar) {
                            viewModel.addStop(from: stop)
                        }
                    } label: {
                        Image(systemName: stop.category == .gas && viewModel.isGasBuffered(stop)
                              ? "checkmark"
                              : stop.category.systemImage)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                    }
                }
                .tag(stop.id)
            }
            }

            // Recommended ride highlights — purple star pins so places worth
            // a stop stand out from ordinary suggestions.
            if !highlightPins.isEmpty {
            ForEach(highlightPins) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Button {
                        handlePinTap(id: stop.id, usesSidebar: usesSidebar) {
                            viewModel.addStop(from: stop)
                        }
                    } label: {
                        Image(systemName: "star.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(.purple, in: Circle())
                            .padding(2.5)
                            .background(.white, in: Circle())
                            .shadow(radius: 3)
                    }
                }
                .tag(stop.id)
            }
            }

            if FeatureFlags.hotelsAlongRoute, !hotelPins.isEmpty {
                ForEach(hotelPins) { stop in
                    Annotation(stop.name, coordinate: stop.coordinate) {
                        Button {
                            viewModel.toggleBufferedHotelStop(stop)
                        } label: {
                            Image(systemName: viewModel.isHotelBuffered(stop) ? "checkmark" : "bed.double.fill")
                                .font(.caption)
                                .padding(6)
                                .background(viewModel.isHotelBuffered(stop) ? Color.indigo : Color.indigo.opacity(0.85), in: Circle())
                                .foregroundStyle(.white)
                        }
                    }
                    .tag(stop.id)
                }
            }

            // Recommended fuel stops (one per tank) — drawn last so they sit on
            // top, and highlighted (larger, ringed green pump) so they're easy
            // to pick out in any category. Exactly one marker per recommended
            // stop, across all the layers above.
            if !fuelPins.isEmpty {
            ForEach(fuelPins) { stop in
                Annotation(stop.name, coordinate: stop.coordinate) {
                    Button {
                        handlePinTap(id: stop.id, usesSidebar: usesSidebar) {
                            viewModel.toggleBufferedGasStop(stop)
                        }
                    } label: {
                        Image(systemName: viewModel.isGasBuffered(stop) ? "checkmark" : "fuelpump.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(9)
                            .background(viewModel.isGasBuffered(stop) ? Color.blue : Color.green, in: Circle())
                            .padding(2.5)
                            .background(.white, in: Circle())
                            .shadow(radius: 3)
                    }
                }
                .tag(stop.id)
            }
            }
    }

    private var showsMapReplanBanner: Bool {
        RoutePlannerViewModel.showsMapReplanBanner(
            isCalculating: viewModel.isCalculating,
            hasLegs: !viewModel.legs.isEmpty
        )
    }

    /// Pinned under the sheet's navigation bar. The in-list copy scrolls off
    /// on iPad after Apply adds stops; this one does not. A one-point row
    /// stays in the inset when nothing is replanning, so the container never
    /// drops to zero children.
    private var sheetReplanBanner: some View {
        // The map chip waits for an existing line. This one is the copy that
        // stays in the sheet for the whole calculation, including the moment
        // a large iPad sheet covers the map.
        let showing = viewModel.isCalculating
        let status = RoutePlannerViewModel.routeReplanStatus(style: viewModel.routeStyle)
        return Text(showing ? status : " ")
            .font(showing ? .subheadline.weight(.semibold) : .system(size: 1))
            .foregroundStyle(showing ? Color.primary : Color.clear)
            .frame(maxWidth: .infinity)
            .frame(maxHeight: showing ? nil : CGFloat(1))
            .padding(.vertical, showing ? 8 : 0)
            .background(showing ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(.clear))
            .accessibilityIdentifier(showing ? AccessibilityID.replanBanner : "replanSheetIdle")
            .accessibilityLabel(showing ? status : "Idle")
            .accessibilityHidden(!showing)
            .focusable()
    }

    private var mapTopChrome: some View {
        // One stack the whole time. Swapping the inset's root when a replan
        // starts left a frame with no focus children.
        VStack(spacing: 0) {
            categoryPicker
            mapReplanBanner
                .padding(.top, showsMapReplanBanner ? 4 : 0)
                .padding(.horizontal, showsMapReplanBanner ? 16 : 0)
                .padding(.bottom, showsMapReplanBanner ? 8 : 0)
                .opacity(showsMapReplanBanner ? 1 : 0)
                .accessibilityHidden(!showsMapReplanBanner)
                // A zero-height clip leaves the stack with no focus region.
                // One point, fully transparent, still has a child.
                .frame(maxHeight: showsMapReplanBanner ? nil : CGFloat(1))
                .clipped()
        }
        .frame(maxWidth: .infinity)
        .background {
            MapFitFrameReporter { frame in
                noteTopControlsFrame(frame)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// Floats on the map, under the category chips, so a style switch is
    /// visible while the planning sheet is collapsed or scrolled past the
    /// summary. Same layout on iPhone, iPad, and Mac.
    ///
    /// The hairline used to be an overlay. That overlay is a focus container
    /// with no children, and iPad aborts in UIFocusSystem when the banner
    /// appears during a replan.
    private var mapReplanBanner: some View {
        let status = RoutePlannerViewModel.routeReplanStatus(style: viewModel.routeStyle)
        return HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            // The spinner is hidden from focus. A space-only title is not a
            // focus item either, so this stack had zero children at launch
            // and iPad aborted in UIFocusSystem. The idle glyph is a real
            // character. Its label is "Idle", not a space, so the tree does
            // not fall back to the glyph while the id is still `replanBanner`.
            // The id sits on this text, and only while the text is the
            // "Replanning for …" sentence.
            Text(verbatim: showsMapReplanBanner ? status : "·")
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .focusable()
                .accessibilityIdentifier(showsMapReplanBanner ? AccessibilityID.replanBanner : "mapReplanIdle")
                .accessibilityLabel(showsMapReplanBanner ? status : "Idle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        .accessibilityElement(children: .contain)
        .accessibilityHidden(!showsMapReplanBanner)
        .allowsHitTesting(false)
    }

    // MARK: - Category chips

    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(StopCategory.plannerCases) { category in
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
            ScrollViewReader { proxy in
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
                    RideHighlightsSection(
                        viewModel: viewModel,
                        openDescription: $openPlaceDescription
                    )
                } else {
                    FocusPlaceholderRow()
                }
                SuggestionsSection(
                    viewModel: viewModel,
                    openDescription: $openPlaceDescription
                )
                GasStationsSectionGate(viewModel: viewModel)
                if viewModel.showsHotelSection {
                    HotelsAlongRouteSection(viewModel: viewModel)
                } else {
                    FocusPlaceholderRow()
                }
                FuelRangeSection(viewModel: viewModel)
                DepartureSection(viewModel: viewModel)
                RouteStyleSection(viewModel: viewModel)
                SavedRoutesSection(viewModel: viewModel, onLoad: loadSaved)
            }
            .accessibilityIdentifier("planningList")
            .sheet(item: $openPlaceDescription) { item in
                PlaceDescriptionSheet(
                    name: item.name,
                    text: item.text,
                    textIdentifier: item.textIdentifier
                )
            }
            // Placeholder rows are one point tall. The default minimum would
            // turn each absent `if` into a full blank cell.
            .environment(\.defaultMinListRowHeight, 1)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Stays on screen while the summary is scrolled off the large
                // iPad sheet. Always has a child, so the inset is not an
                // empty focus container when the replan starts or ends.
                // The proof rows are one point and are direct children, so a
                // nested stack cannot swallow their identifiers. The list
                // below is lazy, and a tall waypoint section unloads the
                // summary that used to be the only `activeRouteStyle`.
                VStack(spacing: 0) {
                    sheetReplanBanner
                    Text(verbatim: viewModel.routeStyle.rawValue)
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                        .accessibilityIdentifier(AccessibilityID.activeRouteStyle)
                        .accessibilityLabel(viewModel.routeStyle.rawValue)
                        .focusable()
                    Text(verbatim: "\(viewModel.lastCompletedReplanStyle)|\(viewModel.lastCompletedReplanGeneration)")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                        .accessibilityIdentifier(AccessibilityID.lastCompletedReplanStyle)
                        .accessibilityLabel("\(viewModel.lastCompletedReplanStyle)|\(viewModel.lastCompletedReplanGeneration)")
                        .accessibilityValue("\(viewModel.lastCompletedReplanStyle)|\(viewModel.lastCompletedReplanGeneration)")
                        .focusable()
                    // On the sheet, not the map. An iPad sheet hides the map
                    // from the accessibility tree until the card moves, which
                    // made these markers look missing until a grabber drag.
                    Text(verbatim: mapFitPadding.accessibilityLabel)
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                        .accessibilityIdentifier(AccessibilityID.mapFitInsets)
                        .accessibilityLabel(mapFitPadding.accessibilityLabel)
                        .focusable()
                    Text(verbatim: "\(mapFitGeneration)")
                        .font(.system(size: 1))
                        .foregroundStyle(.clear)
                        .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                        .accessibilityIdentifier(AccessibilityID.mapFitGeneration)
                        .accessibilityLabel("\(mapFitGeneration)")
                        .focusable()
                }
                .accessibilityElement(children: .contain)
            }
            .navigationTitle("Plan Ride")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if UITestStubLaunch.isEnabled {
                    sheetDetent = .large
                }
            }
            .toolbar {
                // The sheet list drops its banner row when that section is
                // scrolled off, and the map chip sits behind a large iPad
                // sheet. This bar item stays on screen for the whole
                // calculation. Idle text is a glyph, not an empty container.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationReplanBanner(
                        calculating: viewModel.isCalculating,
                        status: RoutePlannerViewModel.routeReplanStatus(style: viewModel.routeStyle)
                    )
                }
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
            .onChange(of: viewModel.scrollToWaypointID) { _, id in
                guard let id else { return }
                proxy.scrollTo(id, anchor: .center)
            }
            .onChange(of: viewModel.scrollToHotelToken) { _, _ in
                guard let day = viewModel.scrollToHotelDay else { return }
                proxy.scrollTo(AccessibilityID.hotelDay(day), anchor: .center)
            }
            }
        }
        .background {
            MapFitFrameReporter { frame in
                noteSheetFrame(frame)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: - Actions & helpers

    private var currentRegion: MKCoordinateRegion {
        visibleRegion ?? MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 33.4735, longitude: -82.0105),
            span: MKCoordinateSpan(latitudeDelta: 1, longitudeDelta: 1)
        )
    }

    /// Frames the route and every applied stop in the map area above the
    /// sheet and below the chip bar. `.region` replaces user tracking.
    /// Called for a new line only — load, replan, and Apply — never because
    /// the sheet detent moved.
    private func fitRouteToVisibleMap(_ legs: [MKRoute]) {
        guard !didFitCurrentLegs else { return }
        let measurement = currentMapFitMeasurement()
        guard measurement.mapSize.width > 1, measurement.mapSize.height > 1 else {
            fitAwaitingChrome = true
            return
        }
        guard mapFitChromeIsReady(measurement) else {
            fitAwaitingChrome = true
            return
        }
        var padding = MapFitInsets.padding(for: measurement)
        if !mapUsesSidebar && !MapFitInsets.leavesABand(measurement) {
            // The large detent covers the map. Still frame the ride, in the
            // top of the screen, instead of waiting for a card that is not
            // coming. A medium card and a floating iPad card leave a real
            // band and keep the padding from the grabber.
            padding = MapFitInsets.fitting(
                padding,
                in: measurement.mapSize,
                minimumBand: measurement.mapSize.height * 0.35
            )
        }
        var coordinates = legs.flatMap { RouteGeometry.coordinates(of: $0.polyline) }
        for waypoint in viewModel.waypoints where waypoint.coordinate.isValidLocation {
            coordinates.append(waypoint.coordinate)
        }
        guard let frame = RouteMapFraming.region(
            containing: coordinates,
            mapSize: measurement.mapSize,
            insets: padding
        ), frame.center.isValidLocation else {
            fitAwaitingChrome = false
            didFitCurrentLegs = true
            return
        }
        fitAwaitingChrome = false
        didFitCurrentLegs = true
        framedRoute = frame
        mapFitPadding = padding
        mapFitGeneration += 1
        programmaticCameraEvents += 1
        withAnimation(.easeInOut(duration: 0.6)) {
            cameraPosition = .region(MKCoordinateRegion(center: frame.center, span: frame.span))
        }
    }

    private func currentMapFitMeasurement() -> MapFitMeasurement {
        MapFitMeasurement(
            mapSize: mapGlobalFrame.size,
            safeTop: mapSafeArea.top,
            safeLeft: mapSafeArea.leading,
            safeBottom: mapSafeArea.bottom,
            safeRight: mapSafeArea.trailing,
            topControls: MapFitInsets.mapLocalFrame(topControlsGlobalFrame, mapFrame: mapGlobalFrame),
            sheet: MapFitInsets.mapLocalFrame(sheetGlobalFrame, mapFrame: mapGlobalFrame)
        )
    }

    /// Sidebar layouts have no sheet on the map. Phone and iPad portrait
    /// wait until the sheet frame has stopped moving, so the fit is the
    /// resting detent and not a frame from the presentation animation.
    private func mapFitChromeIsReady(_ measurement: MapFitMeasurement) -> Bool {
        guard measurement.mapSize.width > 1, measurement.mapSize.height > 1 else { return false }
        guard measurement.topControls.height > 1 else { return false }
        if mapUsesSidebar { return true }
        guard sheetStable else { return false }
        return measurement.sheet.width > 1 && measurement.sheet.height > 1
    }

    private func followUpFitIfNeeded() {
        // Only the fit that is still waiting on a first measurement. A later
        // grabber drag changes the sheet frame and must leave the camera.
        guard fitAwaitingChrome, !didFitCurrentLegs, !riderAdjustedCamera else { return }
        guard !viewModel.legs.isEmpty else { return }
        fitRouteToVisibleMap(viewModel.legs)
    }

    private func noteMapViewport(_ frame: CGRect, safeArea: UIEdgeInsets) {
        let insets = EdgeInsets(
            top: safeArea.top,
            leading: safeArea.left,
            bottom: safeArea.bottom,
            trailing: safeArea.right
        )
        let frameChanged = frame.width > 1 && framesDiffer(frame, mapGlobalFrame)
        let safeChanged = insetsDiffer(insets, mapSafeArea)
        if frameChanged { mapGlobalFrame = frame }
        if safeChanged { mapSafeArea = insets }
        if frameChanged || safeChanged { followUpFitIfNeeded() }
    }

    private func noteSheetFrame(_ frame: CGRect) {
        guard frame.width > 1, frame.height > 1, framesDiffer(frame, sheetGlobalFrame) else { return }
        sheetGlobalFrame = frame
        guard !mapUsesSidebar else {
            followUpFitIfNeeded()
            return
        }
        // A detent animation publishes several frames. Fit the one that
        // stays, which is the card the rider is looking at.
        sheetStable = false
        sheetStableTask?.cancel()
        sheetStableTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            sheetStable = true
            followUpFitIfNeeded()
        }
    }

    private func noteTopControlsFrame(_ frame: CGRect) {
        guard frame.width > 1, frame.height > 1, framesDiffer(frame, topControlsGlobalFrame) else { return }
        topControlsGlobalFrame = frame
        followUpFitIfNeeded()
    }

    private func framesDiffer(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) > 1
            || abs(lhs.minY - rhs.minY) > 1
            || abs(lhs.width - rhs.width) > 1
            || abs(lhs.height - rhs.height) > 1
    }

    private func insetsDiffer(_ lhs: EdgeInsets, _ rhs: EdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) > 0.5
            || abs(lhs.leading - rhs.leading) > 0.5
            || abs(lhs.bottom - rhs.bottom) > 0.5
            || abs(lhs.trailing - rhs.trailing) > 0.5
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

    private var hotelPins: [SuggestedStop] {
        var seen = Set<String>()
        return viewModel.hotelEvenings.flatMap(\.options).filter { stop in
            guard !viewModel.isStopOnRoute(stop) else { return false }
            let key = "\(stop.latitude)|\(stop.longitude)"
            return seen.insert(key).inserted
        }
    }

    private var extraGasPins: [SuggestedStop] {
        viewModel.gasStations.filter {
            !viewModel.isRecommendedFuelStop($0) && !viewModel.isStopOnRoute($0)
        }
    }

    private var categoryPins: [SuggestedStop] {
        viewModel.suggestedStops.filter {
            !viewModel.isRecommendedFuelStop($0)
                && !viewModel.isRideHighlight($0)
                && !viewModel.isStopOnRoute($0)
        }
    }

    private var highlightPins: [SuggestedStop] {
        viewModel.rideHighlights.filter { !viewModel.isStopOnRoute($0) }
    }

    private var fuelPins: [SuggestedStop] {
        viewModel.fuelStops.filter { !viewModel.isStopOnRoute($0) }
    }

    private func markerIcon(for index: Int) -> String {
        if index == 0 { return "flag.fill" }
        if FeatureFlags.hotelsAlongRoute, viewModel.waypoints[index].isOvernight { return "bed.double.fill" }
        if index == viewModel.waypoints.count - 1 { return "flag.checkered" }
        return "mappin"
    }
}

/// Screen frame of a view, including one hosted in a sheet. A sheet window
/// and the map window do not share an origin, so the probe converts through
/// the screen. Not a focus container: iPad aborts when an empty one appears.
private struct MapFitFrameReporter: UIViewRepresentable {
    var onFrame: @MainActor (CGRect) -> Void

    func makeUIView(context: Context) -> MapFitFrameProbe {
        let view = MapFitFrameProbe()
        view.onFrame = onFrame
        return view
    }

    func updateUIView(_ uiView: MapFitFrameProbe, context: Context) {
        uiView.onFrame = onFrame
    }
}

/// Map window frame and the safe area still inside the map.
private struct MapFitViewportReporter: UIViewRepresentable {
    var onViewport: @MainActor (CGRect, UIEdgeInsets) -> Void

    func makeUIView(context: Context) -> MapFitFrameProbe {
        let view = MapFitFrameProbe()
        view.onViewport = onViewport
        return view
    }

    func updateUIView(_ uiView: MapFitFrameProbe, context: Context) {
        uiView.onViewport = onViewport
    }
}

/// Publishes a screen frame from layout. Delivery is the next main-actor
/// turn so a state write is not inside `layoutSubviews`.
@MainActor
private final class MapFitFrameProbe: UIView {
    var onFrame: (@MainActor (CGRect) -> Void)?
    var onViewport: (@MainActor (CGRect, UIEdgeInsets) -> Void)?
    private var lastFrame = CGRect.null
    private var lastSafeArea = UIEdgeInsets(top: -1, left: -1, bottom: -1, right: -1)
    private var deliverScheduled = false
    private var retryScheduled = false
    private var queuedFrame: CGRect?
    private var queuedSafeArea: UIEdgeInsets?
    private var sampleTask: Task<Void, Never>?
    private weak var cachedMapView: MKMapView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        isAccessibilityElement = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        publish()
        scheduleRetries()
        guard window != nil else {
            sampleTask?.cancel()
            sampleTask = nil
            return
        }
        guard sampleTask == nil else { return }
        // The sheet slides to its detent without laying this probe out again.
        // Sampling catches the resting grabber after that animation.
        sampleTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled, self.window != nil else { return }
                self.publish()
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        publish()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        publish()
    }

    /// The presented card is not always in the first layout pass. Two later
    /// reads catch it before the rider can drag the grabber.
    private func scheduleRetries() {
        guard !retryScheduled else { return }
        retryScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            self?.publish()
            try? await Task.sleep(for: .milliseconds(320))
            self?.publish()
            self?.retryScheduled = false
        }
    }

    private func publish() {
        guard window != nil else { return }
        let frame = resolvedFrame()
        guard frame.width > 1, frame.height > 1 else { return }
        let safe = safeAreaInsets
        let frameChanged = lastFrame.isNull || framesDiffer(frame, lastFrame)
        let safeChanged = !safeAreaEqual(safe, lastSafeArea)
        guard frameChanged || safeChanged else { return }
        lastFrame = frame
        lastSafeArea = safe
        queuedFrame = frame
        queuedSafeArea = safe
        guard !deliverScheduled else { return }
        deliverScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.deliverScheduled = false
            guard let frame = self.queuedFrame else { return }
            self.onFrame?(frame)
            if let safe = self.queuedSafeArea {
                self.onViewport?(frame, safe)
            }
        }
    }

    /// Sheet probes report the visible card (grabber included, clipped to
    /// the screen). Map probes report the `MKMapView` the camera fills.
    /// Chip probes report their own screen frame.
    private func resolvedFrame() -> CGRect {
        guard let window else { return .zero }
        let screen = window.screen.bounds
        if onViewport != nil {
            return mapViewFrame(clippedTo: screen)
        }
        if isInsideSheet {
            let card = sheetCardFrame(clippedTo: screen)
            if card.width > 1, card.height > 1 { return card }
        }
        return chromeFrame(clippedTo: screen)
    }

    /// The chip bar. One superview up covers a background probe whose own
    /// bounds are still zero; walking further would report the whole map.
    private func chromeFrame(clippedTo screen: CGRect) -> CGRect {
        guard let window else { return .zero }
        let own = screenFrame(bounds, of: self, window: window).intersection(screen)
        if own.width > 1, own.height > 1 { return own }
        guard let parent = superview else { return own }
        return screenFrame(parent.bounds, of: parent, window: window).intersection(screen)
    }

    private var isInsideSheet: Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               controller.sheetPresentationController != nil {
                return true
            }
            responder = current.next
        }
        return false
    }

    /// The grabber's screen edge. The hosting view is often still the large
    /// detent (top near the status bar) while the card the rider sees sits
    /// lower: a medium iPhone sheet, or a floating card on iPad portrait.
    private func sheetCardFrame(clippedTo screen: CGRect) -> CGRect {
        if let top = grabberTop(clippedTo: screen) {
            return cardCoveringDownward(from: top, screen: screen)
        }
        if let presented = presentedFrame(clippedTo: screen),
           presented.minY > screen.height * 0.18,
           presented.height < screen.height * 0.92 {
            return presented.intersection(screen)
        }
        if let card = heuristicCard(clippedTo: screen) {
            return cardCoveringDownward(from: card.minY, screen: screen)
        }
        if let presented = presentedFrame(clippedTo: screen) {
            return presented.intersection(screen)
        }
        // No detent frame yet. A full-screen ancestor is the container, not
        // the card; publishing it would pad the whole map.
        let own = ownFrame(clippedTo: screen)
        let covers = abs(own.width - screen.width) < 8 && abs(own.height - screen.height) < 8
        return covers ? .zero : own
    }

    /// Pads everything below the card's top, including the part of a floating
    /// card that does not reach the bottom of the screen.
    private func cardCoveringDownward(from top: CGFloat, screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX,
            y: top,
            width: screen.width,
            height: max(1, screen.maxY - top)
        ).intersection(screen)
    }

    private func grabberTop(clippedTo screen: CGRect) -> CGFloat? {
        var roots = sheetSearchRoots()
        if let window, roots.allSatisfy({ $0 !== window }) {
            roots.append(window)
        }
        for root in roots {
            if let grabber = findGrabber(in: root, depth: 0),
               let host = grabber.window ?? window {
                let converted = screenFrame(grabber.bounds, of: grabber, window: host)
                let access = grabber.accessibilityFrame
                let frame = access.height > 1 && access.width > 1 ? access : converted
                if frame.height > 1, frame.minY > screen.minY, frame.minY < screen.maxY - 20 {
                    return frame.minY
                }
            }
        }
        return nil
    }

    /// A rounded card inside a host that is still laid out at the large
    /// detent. The host's top is not the grabber.
    private func heuristicCard(clippedTo screen: CGRect) -> CGRect? {
        var best: CGRect?
        var seen = 0
        func walk(_ view: UIView, depth: Int) {
            guard depth < 24, seen < 500, !(view is MKMapView) else { return }
            seen += 1
            if let host = view.window {
                let frame = screenFrame(view.bounds, of: view, window: host).intersection(screen)
                let tallEnough = frame.height > screen.height * 0.28
                let notTheHost = frame.height < screen.height * 0.78
                let wideEnough = frame.width > screen.width * 0.45
                let belowTheStatusBar = frame.minY > screen.height * 0.12
                if tallEnough, notTheHost, wideEnough, belowTheStatusBar {
                    let area = frame.width * frame.height
                    let bestArea = (best?.width ?? 0) * (best?.height ?? 0)
                    if area > bestArea { best = frame }
                }
            }
            for subview in view.subviews {
                walk(subview, depth: depth + 1)
            }
        }
        for root in sheetSearchRoots() {
            walk(root, depth: 0)
        }
        return best
    }

    private func sheetSearchRoots() -> [UIView] {
        var roots: [UIView] = []
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               let presentation = controller.sheetPresentationController {
                if let presented = presentation.presentedView { roots.append(presented) }
                if let container = presentation.containerView { roots.append(container) }
                break
            }
            responder = current.next
        }
        if roots.isEmpty, let window { roots.append(window) }
        return roots
    }

    private func findGrabber(in view: UIView, depth: Int) -> UIView? {
        guard depth < 28, !(view is MKMapView) else { return nil }
        if isGrabber(view) { return view }
        for subview in view.subviews {
            if let found = findGrabber(in: subview, depth: depth + 1) { return found }
        }
        return nil
    }

    private func isGrabber(_ view: UIView) -> Bool {
        let label = view.accessibilityLabel ?? ""
        let identifier = view.accessibilityIdentifier ?? ""
        if label == "Sheet Grabber" || identifier == "Sheet Grabber" {
            return view.bounds.height > 1 && view.bounds.width > 8
        }
        let name = String(describing: type(of: view))
        guard name.range(of: "Grabber", options: .caseInsensitive) != nil else { return false }
        let bounds = view.bounds
        // The pill or its short bar. A container named Grabber that fills
        // the card is the host, and its top is not the visible edge.
        return bounds.height > 1
            && bounds.height <= 48
            && bounds.width >= 12
            && bounds.height < bounds.width
    }

    private func presentedFrame(clippedTo screen: CGRect) -> CGRect? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController,
               let presentation = controller.sheetPresentationController,
               let container = presentation.containerView,
               let window = container.window {
                let inContainer = presentation.frameOfPresentedViewInContainerView
                guard inContainer.width > 40, inContainer.height > 40 else { return nil }
                let onScreen = screenFrame(inContainer, of: container, window: window)
                let clipped = onScreen.intersection(screen)
                guard clipped.width > 40, clipped.height > 40 else { return nil }
                return clipped
            }
            responder = current.next
        }
        return nil
    }

    private func mapViewFrame(clippedTo screen: CGRect) -> CGRect {
        if let cachedMapView, let mapWindow = cachedMapView.window {
            return screenFrame(cachedMapView.bounds, of: cachedMapView, window: mapWindow).intersection(screen)
        }
        var current: UIView? = self
        var hops = 0
        while let candidate = current, hops < 10 {
            if let map = mapView(in: candidate, depth: 0) {
                cachedMapView = map
                guard let window = map.window else { break }
                return screenFrame(map.bounds, of: map, window: window).intersection(screen)
            }
            current = candidate.superview
            hops += 1
        }
        return ownFrame(clippedTo: screen)
    }

    private func mapView(in view: UIView, depth: Int) -> MKMapView? {
        if depth > 8 { return nil }
        if let map = view as? MKMapView { return map }
        for subview in view.subviews {
            if let map = mapView(in: subview, depth: depth + 1) { return map }
        }
        return nil
    }

    private func ownFrame(clippedTo screen: CGRect) -> CGRect {
        guard let window else { return .zero }
        var current: UIView? = self
        var hops = 0
        while let candidate = current, hops < 5 {
            let clipped = screenFrame(candidate.bounds, of: candidate, window: window).intersection(screen)
            if clipped.width > 40, clipped.height > 40 { return clipped }
            current = candidate.superview
            hops += 1
        }
        return screenFrame(bounds, of: self, window: window).intersection(screen)
    }

    /// Screen coordinates. A sheet and the map can live in different windows,
    /// and converting only as far as the window leaves the card at the wrong y.
    private func screenFrame(_ rect: CGRect, of view: UIView, window: UIWindow) -> CGRect {
        let inWindow = view.convert(rect, to: window)
        return window.convert(inWindow, to: window.screen.coordinateSpace)
    }

    private func safeAreaEqual(_ lhs: UIEdgeInsets, _ rhs: UIEdgeInsets) -> Bool {
        abs(lhs.top - rhs.top) < 0.5
            && abs(lhs.left - rhs.left) < 0.5
            && abs(lhs.bottom - rhs.bottom) < 0.5
            && abs(lhs.right - rhs.right) < 0.5
    }

    private func framesDiffer(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) > 1
            || abs(lhs.minY - rhs.minY) > 1
            || abs(lhs.width - rhs.width) > 1
            || abs(lhs.height - rhs.height) > 1
    }
}

#Preview {
    ContentView()
}
