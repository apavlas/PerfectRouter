import XCTest

/// Simulator coverage for the ride planner. The app is launched with
/// `-UITestStubServices`, so directions and stop search use canned data
/// instead of live MapKit.
///
/// Identifiers match `AccessibilityID` in the app target.
final class CoreJourneyUITests: XCTestCase {

    private let stubArgument = "-UITestStubServices"
    private let noGasCopy = "No gas stations found along this route."
    private let gasFailedCopy = "Couldn't load gas — tap to retry"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testLaunchShowsPlanRide() {
        let app = launch()
        assertPlannerVisible(app)
        XCTAssertTrue(waitForPlaceSearch(in: app).exists)
    }

    func testPlanRouteBetweenTwoFixedPointsShowsFuelStops() {
        let app = launch()
        planFixedRoute(in: app)

        XCTAssertEqual(
            waypointNames(in: app),
            ["Test Origin", "Test Destination"],
            diagnosticTree(app)
        )
        let fuels = scanFuelRows(in: app)
        assertFuelRow("Pilot Madison", checked: false, in: fuels, app: app)
        assertFuelRow("On Route Fuel", checked: false, in: fuels, app: app)
        assertFuelRow("Shell Knoxville", checked: false, in: fuels, app: app)
        XCTAssertFalse(fuels.mentions("Quick Stop"), "Quick Stop was listed as a fuel row. \(fuels)\n\(diagnosticTree(app))")
        XCTAssertFalse(fuels.mentions("Home Fuel"), "Home Fuel was listed as a fuel row. \(fuels)\n\(diagnosticTree(app))")
        assertNoEmptyGasMessage(in: app)
    }

    func testRideHighlightDescriptionIsClippedUnderTheNameAndExpands() {
        let app = launch()
        planFixedRoute(in: app)

        let header = reveal("rideHighlights", in: app)
        XCTAssertTrue(header.exists, diagnosticTree(app))

        let name = reveal("highlight.Tallulah Gorge.name", in: app)
        let description = reveal("highlight.Tallulah Gorge.description", in: app)
        XCTAssertTrue(name.exists, diagnosticTree(app))
        XCTAssertTrue(description.exists, diagnosticTree(app))
        scrollUntilHittable(description, in: app)

        XCTAssertGreaterThanOrEqual(
            description.frame.minY,
            name.frame.maxY - 4,
            "Description was not under the name. name=\(name.frame) description=\(description.frame)\n\(diagnosticTree(app))"
        )
        let clippedLabel = description.label
        XCTAssertTrue(
            clippedLabel.hasPrefix("UI test fixture sentence one"),
            clippedLabel
        )
        XCTAssertFalse(
            clippedLabel.contains("UI test fixture sentence three"),
            "The row showed more than the first two sentences: \(clippedLabel)"
        )
        // The label is the first two sentences. The frame is those sentences
        // clipped to two lines of subheadline.
        XCTAssertGreaterThan(description.frame.height, 12, "Description had no height")
        XCTAssertLessThan(
            description.frame.height,
            110,
            "Description was not clipped to two lines. height=\(description.frame.height) labelCount=\(description.label.count)"
        )
        attachScreenshot("Ride highlight description clipped", of: app)

        let plainName = reveal("highlight.Bare Overlook.name", in: app)
        XCTAssertTrue(plainName.exists, diagnosticTree(app))
        XCTAssertFalse(
            identified("highlight.Bare Overlook.description", in: app).exists,
            "A highlight with no published text showed a description.\n\(diagnosticTree(app))"
        )

        let clipped = reveal("highlight.Tallulah Gorge.description", in: app)
        scrollUntilHittable(clipped, in: app)
        let rowHeight = clipped.frame.height
        clipped.tap()

        let full = identified("highlight.Tallulah Gorge.description.full", in: app)
        XCTAssertTrue(
            full.waitForExistence(timeout: 5),
            "Tapping the clipped description did not open the full text.\n\(diagnosticTree(app))"
        )
        XCTAssertTrue(full.label.hasPrefix("UI test fixture sentence one"), full.label)
        XCTAssertTrue(
            full.label.contains("UI test fixture sentence two is also on the row"),
            full.label
        )
        XCTAssertFalse(
            full.label.contains("UI test fixture sentence three"),
            "The sheet showed a sentence past the two-sentence cap: \(full.label)"
        )
        XCTAssertGreaterThan(
            full.frame.height,
            rowHeight,
            "The sheet clipped the two sentences instead of showing them in full. sheet=\(full.frame) rowHeight=\(rowHeight)"
        )
        attachScreenshot("Ride highlight description expanded", of: app)
    }

    /// The camera leaves the device location and fits the stub ride. The
    /// label is the framed center ("lat,lon"). Ontario is north of 42°.
    func testRouteMapFramesTheStubRide() {
        let app = launch()
        planFixedRoute(in: app)

        let marker = app.descendants(matching: .any)["routeMapFrame"]
        XCTAssertTrue(
            marker.waitForExistence(timeout: 8),
            "The map did not publish a framed camera.\n\(diagnosticTree(app))"
        )
        let parts = marker.label.split(separator: ",").compactMap { Double(String($0)) }
        XCTAssertEqual(parts.count, 2, marker.label)
        XCTAssertGreaterThan(parts[0], 30, "Camera latitude was not the stub ride: \(marker.label)")
        XCTAssertLessThan(parts[0], 42, "Camera latitude was not the stub ride: \(marker.label)")
        XCTAssertGreaterThan(parts[1], -84, "Camera longitude was not the stub ride: \(marker.label)")
        XCTAssertLessThan(parts[1], -80, "Camera longitude was not the stub ride: \(marker.label)")
    }

    func testSelectRecommendedChecksInRangeStopsAndSkipsOnRoute() {
        let app = launch()
        planFixedRoute(in: app)
        addOnRouteFuel(in: app)

        let before = routeGeneration(in: app)
        tapSelectRecommended(in: app)

        XCTAssertEqual(routeGeneration(in: app), before + 1)
        XCTAssertFalse(identified("routeGeneration.\(before + 2)", in: app).exists)
        XCTAssertEqual(
            waypointNames(in: app),
            ["Test Origin", "Pilot Madison", "On Route Fuel", "Shell Knoxville", "Test Destination"]
        )
        XCTAssertEqual(waypointNames(in: app).filter { $0 == "On Route Fuel" }.count, 1)
        XCTAssertFalse(fuel("Pilot Madison", checked: true, in: app).exists)
        XCTAssertFalse(fuel("Pilot Madison", checked: false, in: app).exists)
        XCTAssertFalse(fuel("Shell Knoxville", checked: true, in: app).exists)
        XCTAssertFalse(fuel("Shell Knoxville", checked: false, in: app).exists)
        XCTAssertFalse(fuel("Quick Stop", checked: false, in: app).exists)
        XCTAssertFalse(fuel("Home Fuel", checked: false, in: app).exists)
        XCTAssertFalse(app.buttons["applyStops"].firstMatch.exists, diagnosticTree(app))
        assertNoEmptyGasMessage(in: app)
    }

    func testApplyReplansOnceWithStopsInRideOrder() {
        let app = launch()
        planFixedRoute(in: app)
        addOnRouteFuel(in: app)
        let before = routeGeneration(in: app)
        tapSelectRecommended(in: app)

        assertWaypointListed("Pilot Madison", in: app)
        XCTAssertEqual(routeGeneration(in: app), before + 1)
        XCTAssertFalse(identified("routeGeneration.\(before + 2)", in: app).exists)
        XCTAssertEqual(
            waypointNames(in: app),
            ["Test Origin", "Pilot Madison", "On Route Fuel", "Shell Knoxville", "Test Destination"]
        )
        XCTAssertFalse(app.buttons["selectRecommended"].firstMatch.exists, diagnosticTree(app))
        assertNoEmptyGasMessage(in: app)
    }

    func testSelectRecommendedAgainAddsNoDuplicates() {
        let app = launch()
        planFixedRoute(in: app)
        addOnRouteFuel(in: app)
        tapSelectRecommended(in: app)
        assertWaypointListed("Pilot Madison", in: app)

        let afterApply = waypointNames(in: app)
        let select = app.buttons["selectRecommended"]
        if select.waitForExistence(timeout: 2) {
            scrollUntilHittable(select, in: app)
            select.tap()
            if app.buttons["applyStops"].waitForExistence(timeout: 1) {
                tapApply(in: app)
                waitForBannerToFinish(in: app)
                assertWaypointListed("Pilot Madison", in: app)
            }
        }

        let names = waypointNames(in: app)
        XCTAssertEqual(names, afterApply, "Waypoint rows changed: \(names)")
        XCTAssertEqual(
            Set(names).count,
            names.count,
            "Duplicate waypoints: \(names)"
        )
        XCTAssertEqual(
            names,
            ["Test Origin", "Pilot Madison", "On Route Fuel", "Shell Knoxville", "Test Destination"],
            "Waypoint rows: \(names)"
        )
        for name in ["Pilot Madison", "On Route Fuel", "Shell Knoxville"] {
            XCTAssertEqual(names.filter { $0 == name }.count, 1, name)
        }
    }

    func testRouteStyleChangesShowReplanBannerAndFinish() {
        let app = launch()
        planFixedRoute(in: app)

        for style in ["Avoid Highways", "Scenic", "Twisty", "Fastest"] {
            selectRouteStyle(style, in: app)
            assertReplanBanner(contains: style, in: app)
            waitForBannerToFinish(in: app)
            waitForNavigate(in: app)
            // A bowed style can recommend a different pump. Wait for the
            // stations the planner published, not a name that is only a pin.
            _ = waitForPublishedRecommendations(in: app)
            assertNoEmptyGasMessage(in: app)
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Routing failed'")).firstMatch.exists
            )
            XCTAssertFalse(
                app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No route found'")).firstMatch.exists
            )
        }
    }

    func testTankRangeAndLeaveLaterReplanWithoutFalseEmptyGas() {
        let app = launch()
        planFixedRoute(in: app)

        _ = reveal("tankRangeSlider", in: app)
        let slider = app.sliders["tankRangeSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3), diagnosticTree(app))
        scrollUntilHittable(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 0.55)
        assertReplanDoesNotClaimTheRoadIsEmpty(in: app)

        // The slider is already on screen. Leave later is the next section,
        // and a tall iPad list does not create that switch until it is
        // scrolled into view. reveal() goes back to the top and nudges, which
        // runs out before the row exists.
        let leaveLater = scrollPlanningListUntilExists("leaveLaterToggle", in: app, maxSwipes: 16)
        XCTAssertTrue(leaveLater.waitForExistence(timeout: 3), diagnosticTree(app))
        scrollUntilHittable(leaveLater, in: app)
        leaveLater.tap()
        assertReplanDoesNotClaimTheRoadIsEmpty(in: app)
        waitForNavigate(in: app)
    }

    // MARK: - Launch and search

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [stubArgument]
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            let allow = alert.buttons["Allow While Using App"]
            if allow.exists {
                allow.tap()
                return true
            }
            let once = alert.buttons["Allow Once"]
            if once.exists {
                once.tap()
                return true
            }
            return false
        }
        app.launch()
        assertPlannerVisible(app, timeout: 8)
        expandPlanningSheet(app)
        return app
    }

    /// The title lives in the sheet's navigation bar on iPhone and iPad.
    /// A regular-width sheet can expose it as a static text instead of the bar's label.
    private func assertPlannerVisible(_ app: XCUIApplication, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if app.navigationBars["Plan Ride"].exists || app.staticTexts["Plan Ride"].exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Plan Ride did not appear")
    }

    private func planFixedRoute(in app: XCUIApplication) {
        search("Test Origin", in: app)
        search("Test Destination", in: app)
        expandPlanningSheet(app)
        let names = waitForPublishedRecommendations(in: app)
        XCTAssertEqual(
            names,
            ["Pilot Madison", "On Route Fuel", "Shell Knoxville"],
            "The 100-mile stub plan did not match the fixture.\n\n\(diagnosticTree(app))"
        )
        assertNoEmptyGasMessage(in: app)
    }

    private func addOnRouteFuel(in app: XCUIApplication) {
        search("On Route Fuel", in: app)
        XCTAssertTrue(identified("waypoint.On Route Fuel", in: app).waitForExistence(timeout: 5))
        assertReplanBanner(contains: "Fastest", in: app)
        waitForBannerToFinish(in: app)
        let names = waitForPublishedRecommendations(in: app)
        XCTAssertFalse(
            names.contains("On Route Fuel"),
            "On Route Fuel stayed a recommendation after it was a waypoint: \(names)\n\n\(diagnosticTree(app))"
        )
        XCTAssertFalse(fuel("On Route Fuel", checked: false, in: app).exists)
        XCTAssertFalse(fuel("On Route Fuel", checked: true, in: app).exists)
    }

    private func search(_ name: String, in app: XCUIApplication) {
        dismissKeyboard(app)
        expandPlanningSheet(app)
        let field = waitForPlaceSearch(in: app)
        scrollUntilHittable(field, in: app)
        // A field tucked under the sheet's navigation bar is still "hittable",
        // but typeText's tap lands on the bar and the field never takes focus.
        scrollSearchFieldBelowChrome(field, in: app)
        focusPlaceSearch(field, in: app)
        field.typeText(name)
        let result = app.buttons["searchResult.\(name)"]
        XCTAssertTrue(
            result.waitForExistence(timeout: 6),
            "Search result \(name) did not appear.\n\n\(diagnosticTree(app))"
        )
        scrollUntilHittable(result, in: app)
        result.tap()
        dismissKeyboard(app)
        expandPlanningSheet(app)
    }

    /// `isHittable` stays true while the field still sits under the sheet
    /// bar. `typeText` taps that overlap and the field never becomes first
    /// responder, which is the iPhone "no keyboard focus" failure.
    private func scrollSearchFieldBelowChrome(_ field: XCUIElement, in app: XCUIApplication) {
        let bar = app.navigationBars["Plan Ride"]
        let chromeBottom = (bar.exists ? bar.frame.maxY : 0) + 28
        let lowerBand = app.frame.height * 0.5
        var nudges = 0
        while nudges < 8 {
            guard field.exists, field.frame.height > 1 else { return }
            let midY = field.frame.midY
            if midY > chromeBottom, midY < lowerBand { return }
            nudgePlanningList(in: app, up: midY >= lowerBand)
            nudges += 1
        }
    }

    /// Tap the text itself, then wait for the keyboard that tap summoned.
    /// A keyboard left up by the previous search does not count.
    private func focusPlaceSearch(_ field: XCUIElement, in app: XCUIApplication) {
        dismissKeyboard(app)
        let point = field.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.5))
        point.tap()
        if app.keyboards.firstMatch.waitForExistence(timeout: 3) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
            return
        }
        point.tap()
        _ = app.keyboards.firstMatch.waitForExistence(timeout: 3)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }

    /// The planner uses a text field. iPhone exposes it as a text field;
    /// iPad's regular-width sheet can expose the same identifier on a search
    /// field or a plain descendant, and a prior scroll drops it out of the
    /// lazy list until the sheet is back at the top.
    private func waitForPlaceSearch(in app: XCUIApplication, timeout: TimeInterval = 12) -> XCUIElement {
        expandPlanningSheet(app)
        scrollToTop(app)
        let deadline = Date().addingTimeInterval(timeout)
        var nudges = 0
        while Date() < deadline {
            if let field = placeSearchField(in: app) {
                return field
            }
            swipePlanningList(in: app, up: false)
            nudges += 1
            if nudges % 4 == 0 {
                expandPlanningSheet(app)
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        XCTFail("Place search did not appear\n\n\(diagnosticTree(app))")
        return app.textFields["placeSearch"]
    }

    /// Any element carrying `placeSearch`, including the placeholder the
    /// iPad sheet uses when the identifier is not on a text field.
    private func placeSearchField(in app: XCUIApplication) -> XCUIElement? {
        let identified = [
            app.textFields["placeSearch"],
            app.searchFields["placeSearch"],
            app.textViews["placeSearch"],
            app.otherElements["placeSearch"],
            app.descendants(matching: .any).matching(identifier: "placeSearch").firstMatch
        ]
        for field in identified where field.exists {
            return field
        }
        let byPlaceholder = app.descendants(matching: .any).matching(
            NSPredicate(format: "placeholderValue CONTAINS[c] 'destination' OR label == 'Add a destination or stop'")
        ).firstMatch
        if byPlaceholder.exists {
            return byPlaceholder
        }
        return nil
    }

    /// Navigate stays in the summary for as long as the route has legs. It is
    /// not removed by a replan. A half-list fling jumps over that one row, so
    /// walk down from the search field in short steps.
    private func waitForNavigate(in app: XCUIApplication, timeout: TimeInterval = 20) {
        expandPlanningSheet(app)
        scrollToTop(app)
        let deadline = Date().addingTimeInterval(timeout)
        var down = 0
        while Date() < deadline {
            if navigateButton(in: app).exists { return }
            if down >= 10 {
                scrollToTop(app)
                down = 0
            } else {
                nudgePlanningList(in: app, up: true)
                down += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        let labeled = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Navigate'"))
            .firstMatch
        XCTFail(
            "Navigate did not appear. id=\(identified("navigate", in: app).exists) label=\(labeled.exists) '\(labeled.label)'\n\n\(diagnosticTree(app))"
        )
    }

    /// The summary hand-off. Identifier first: the symbol on the button can
    /// change the accessibility label without changing the control.
    private func navigateButton(in app: XCUIApplication) -> XCUIElement {
        let byID = identified("navigate", in: app)
        if byID.exists { return byID }
        let button = app.buttons["Navigate"].firstMatch
        if button.exists { return button }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == 'Navigate' OR label BEGINSWITH 'Navigate,'"))
            .firstMatch
    }

    /// A short, slow drag. The planning-list swipe is half the sheet and
    /// keeps going after the finger lifts, which skips the Navigate row.
    private func nudgePlanningList(in app: XCUIApplication, up: Bool) {
        let list = planningList(in: app)
        guard list.elementType != .application, list.exists, list.frame.width > 40, list.frame.height > 40 else {
            swipePlanningList(in: app, up: up)
            return
        }
        let startY: CGFloat = up ? 0.58 : 0.42
        let endY: CGFloat = up ? 0.42 : 0.58
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.25, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.2)
    }

    private func tapApply(in app: XCUIApplication) {
        let buttons = app.buttons.matching(identifier: "applyStops")
        XCTAssertTrue(buttons.firstMatch.waitForExistence(timeout: 3))
        var swipes = 0
        while swipes < 14 {
            for index in 0..<buttons.count {
                let button = buttons.element(boundBy: index)
                if button.isHittable {
                    button.tap()
                    return
                }
            }
            swipePlanningList(in: app, up: true)
            swipes += 1
        }
        XCTFail("Apply was not on screen\n\n\(diagnosticTree(app))")
    }

    private func tapSelectRecommended(in app: XCUIApplication) {
        let select = reveal("selectRecommended", in: app)
        scrollUntilHittable(select, in: app)
        select.tap()
        assertReplanBanner(contains: "Fastest", in: app)
        waitForBannerToFinish(in: app)
        assertWaypointListed("Pilot Madison", in: app)
    }

    // MARK: - Route style

    private func selectRouteStyle(_ style: String, in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        var down = 0
        var picker: XCUIElement?
        while Date() < deadline {
            let byID = identified("routeStylePicker", in: app)
            if byID.exists {
                picker = byID
                break
            }
            let byLabel = app.buttons["Route style"]
            if byLabel.exists {
                picker = byLabel
                break
            }
            if down >= 14 {
                scrollToTop(app)
                down = 0
            } else {
                swipePlanningList(in: app, up: true)
                down += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        guard let picker else {
            XCTFail("Route style control did not appear.\n\n\(diagnosticTree(app))")
            return
        }
        scrollUntilHittable(picker, in: app)
        // Highlights lengthen the list, so this picker is found at the bottom
        // edge. An iPad menu opened from there sits off the sheet and Twisty
        // exists but is not hittable. Lift the anchor into the upper half.
        var lifts = 0
        while picker.exists, picker.frame.midY > app.frame.height * 0.45, lifts < 8 {
            nudgePlanningList(in: app, up: true)
            lifts += 1
        }
        if !picker.isHittable {
            scrollUntilHittable(picker, in: app)
        }
        picker.tap()

        let started = Date()
        let optionDeadline = started.addingTimeInterval(5)
        while Date() < optionDeadline {
            // Give the menu a moment to become hittable. A coordinate tap
            // before that can hit the closed picker instead of Twisty.
            let allowCoordinate = Date().timeIntervalSince(started) > 1.5
            if tapRouteStyleOption(style, in: app, allowCoordinate: allowCoordinate) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Route style \(style) was not hittable")
    }

    /// Menu row for `style`. Prefer a hittable control. A visible iPad popover
    /// row can report not hittable while its center is still on screen; a
    /// coordinate tap hits that point.
    private func tapRouteStyleOption(
        _ style: String,
        in app: XCUIApplication,
        allowCoordinate: Bool
    ) -> Bool {
        var candidates = [identified("routeStyleOption.\(style)", in: app)]
        let labeled = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", style))
        for index in 0..<labeled.count {
            candidates.append(labeled.element(boundBy: index))
        }
        let visible = candidates.filter { option in
            guard option.exists, option.frame.width > 8, option.frame.height > 8 else { return false }
            return app.frame.contains(CGPoint(x: option.frame.midX, y: option.frame.midY))
        }
        if let hittable = visible.first(where: \.isHittable) {
            hittable.tap()
            return true
        }
        if allowCoordinate, let option = visible.first {
            option.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return true
        }
        return false
    }

    // MARK: - Assertions

    private func assertReplanBanner(contains style: String, in app: XCUIApplication) {
        // The stub is still calculating when this starts. Look immediately.
        // Scrolling the sheet to the top first used to burn the whole
        // request, and the banner is only up while that request runs.
        if bannerShows(style, in: app) { return }
        dismissKeyboard(app)
        expandPlanningSheet(app)
        // Four applied stops are four sequential stub requests. Keep looking
        // until that line can finish, then accept the banner or the completed
        // replan. A gas-search spinner means the route request already ended.
        let deadline = Date().addingTimeInterval(20)
        var lastLabel = ""
        var nudges = 0
        while Date() < deadline {
            if bannerShows(style, in: app, lastLabel: &lastLabel) { return }
            // A cached style (Fastest, after the other three) finishes before
            // the banner can be read. The summary that proves it landed sits
            // above the highlight rows and is unloaded while the style picker
            // is on screen.
            if !replanBannerIsUp(in: app) {
                if !identified("activeRouteStyle", in: app).exists {
                    scrollToTop(app)
                    if !identified("activeRouteStyle", in: app).exists {
                        nudgePlanningList(in: app, up: true)
                    }
                }
                // A few passes first, so a banner that is about to appear is
                // not treated as already finished. The scroll above is what
                // puts the summary back after the highlight rows unload it.
                if nudges >= 4, routeRequestHasFinished(style: style, in: app) { return }
            }
            // iPad can park the in-list copy under the fold. Alternate
            // toward the top and just past it; the nav-bar copy needs no scroll.
            if nudges % 3 == 2 {
                swipePlanningList(in: app, up: (nudges / 3) % 2 == 1)
            }
            nudges += 1
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        if bannerShows(style, in: app, lastLabel: &lastLabel) { return }
        if routeRequestHasFinished(style: style, in: app) { return }
        let bannerIDs = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier CONTAINS 'replan'"))
            .allElementsBoundByIndex
            .map { "\($0.identifier) label=\($0.label)" }
            .joined(separator: "\n")
        XCTFail("Replanning banner for \(style) did not appear (last label: \(lastLabel))\nBanner ids:\n\(bannerIDs)\n\n\(diagnosticTree(app))")
    }

    /// The route request is done. Gas search may still be spinning; that
    /// starts only after `isCalculating` drops and the banner comes down.
    /// A style control that is on screen must already show `style`, so a
    /// leftover plan from the previous style does not count.
    private func routeRequestHasFinished(style: String, in app: XCUIApplication) -> Bool {
        if replanBannerIsUp(in: app) { return false }
        let failed = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Routing failed'")).firstMatch.exists
            || app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No route found'")).firstMatch.exists
        if failed { return false }
        let active = identified("activeRouteStyle", in: app)
        // Off-screen does not count. A fuel plan left over from the previous
        // style is still in the tree until the summary is visited, and the
        // highlight rows are what push that summary out of the lazy list.
        guard active.exists else { return false }
        guard active.label == style || active.label.hasPrefix(style) else { return false }
        // "Searching along your route…" is also the in-list copy while the
        // line is still calculating, so it is not proof the request finished.
        // The gas-search sentence, a republished plan, and Navigate all start
        // after `isCalculating` drops.
        let gasFollowUp = app.staticTexts["Searching for gas along the route…"].exists
            || !publishedFuelNames(in: app).isEmpty
        return gasFollowUp || navigateButton(in: app).exists
    }

    private func waitForBannerToFinish(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(25)
        var quiet = 0
        while Date() < deadline {
            if !replanBannerIsUp(in: app) {
                quiet += 1
                if quiet >= 2 { return }
            } else {
                quiet = 0
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        XCTFail("Replanning banner did not finish\n\n\(diagnosticTree(app))")
    }

    /// True when some on-screen banner names `style`. Map chip and sheet
    /// copy can both exist on iPad; `firstMatch` may be the idle placeholder.
    private func bannerShows(
        _ style: String,
        in app: XCUIApplication,
        lastLabel: inout String
    ) -> Bool {
        let banners = app.descendants(matching: .any).matching(identifier: "replanBanner")
        for index in 0..<banners.count {
            let banner = banners.element(boundBy: index)
            guard banner.exists else { continue }
            lastLabel = banner.label
            if banner.label.localizedCaseInsensitiveContains(style) { return true }
        }
        let status = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Replanning for \(style)")
        ).firstMatch
        if status.exists {
            lastLabel = status.label
            return true
        }
        return false
    }

    private func bannerShows(_ style: String, in app: XCUIApplication) -> Bool {
        var unused = ""
        return bannerShows(style, in: app, lastLabel: &unused)
    }

    /// True only while some element is actually saying "Replanning". An idle
    /// placeholder that still carries `replanBanner` does not count, which is
    /// what left the iPad style test waiting after the line had landed.
    private func replanBannerIsUp(in app: XCUIApplication) -> Bool {
        let banners = app.descendants(matching: .any).matching(identifier: "replanBanner")
        for index in 0..<banners.count {
            let banner = banners.element(boundBy: index)
            if banner.exists && banner.label.localizedCaseInsensitiveContains("Replanning") {
                return true
            }
        }
        return app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'Replanning for'")
        ).firstMatch.exists
    }

    /// Names the summary is currently recommending, in ride order. Empty
    /// while a replan has cleared the rows and not published the next plan.
    private func publishedFuelNames(in app: XCUIApplication) -> [String] {
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'recommendedFuelPlan.'"))
            .firstMatch
        guard element.exists else { return [] }
        let suffix = String(element.identifier.dropFirst("recommendedFuelPlan.".count))
        guard !suffix.isEmpty else { return [] }
        return suffix.split(separator: "|").map(String.init)
    }

    /// Scrolls until every station the planner published is a fuel row or,
    /// after Apply, a waypoint. A map pin alone does not count. The plan id
    /// and a lower row do not have to be on screen in the same frame.
    private func waitForPublishedRecommendations(
        in app: XCUIApplication,
        timeout: TimeInterval = 25
    ) -> [String] {
        expandPlanningSheet(app)
        scrollToTop(app)
        let deadline = Date().addingTimeInterval(timeout)
        var down = 0
        var latest: [String] = []
        var confirmed = Set<String>()
        while Date() < deadline {
            let published = publishedFuelNames(in: app)
            if !published.isEmpty && published != latest {
                latest = published
                confirmed = confirmed.filter { published.contains($0) }
            }
            for name in latest where fuelStopOrWaypoint(name, in: app) {
                confirmed.insert(name)
            }
            if !latest.isEmpty, latest.allSatisfy({ confirmed.contains($0) }) {
                return latest
            }
            if down >= 4 {
                scrollToTop(app)
                down = 0
            } else {
                swipePlanningList(in: app, up: true)
                down += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        let detail = latest.map { name -> String in
            let row = fuelListed(name, in: app) || fuelRowLabel(name, in: app).exists
            let waypoint = identified("waypoint.\(name)", in: app).exists
            let pin = mapShowsStation(name, in: app)
            let seen = confirmed.contains(name)
            return "\(name) row=\(row) waypoint=\(waypoint) pin=\(pin) seen=\(seen)"
        }.joined(separator: "\n")
        XCTFail("Published fuel plan did not appear as rows.\nplan=\(latest)\n\(detail)\n\n\(diagnosticTree(app))")
        return latest
    }

    /// A recommended stop leaves the fuel list once Apply makes it a waypoint.
    private func fuelStopOrWaypoint(_ name: String, in app: XCUIApplication) -> Bool {
        fuelListed(name, in: app)
            || fuelRowLabel(name, in: app).exists
            || identified("waypoint.\(name)", in: app).exists
    }

    /// List rows read "Fuel stop N: Name …". Map pins use the bare name, so
    /// this does not treat a pin as the fuel row.
    private func fuelRowLabel(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Fuel stop' AND label CONTAINS %@", name))
            .firstMatch
    }

    private func assertReplanDoesNotClaimTheRoadIsEmpty(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(20)
        var settled = false
        var swipes = 0
        while Date() < deadline {
            assertNoEmptyGasMessage(in: app)
            let searching = app.staticTexts["Searching for gas along the route…"].exists
                || app.staticTexts["Searching along your route…"].exists
                || replanBannerIsUp(in: app)
            let station = ["Pilot Madison", "On Route Fuel", "Shell Knoxville", "Quick Stop", "Home Fuel"]
                .contains { name in
                    fuelListed(name, in: app)
                        || fuelRowLabel(name, in: app).exists
                        || mapShowsStation(name, in: app)
                }
            if !searching && station {
                settled = true
                break
            }
            if swipes >= 12 {
                scrollToTop(app)
                swipes = 0
            } else {
                swipePlanningList(in: app, up: true)
                swipes += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        assertNoEmptyGasMessage(in: app)
        XCTAssertTrue(settled, "Tank or departure change did not finish with gas still listed\n\n\(diagnosticTree(app))")
    }

    /// Fuel rows are buttons whose label includes the mile marker. Match the
    /// identifier, which stays on the row whether or not it is checked.
    private func fuelListed(_ name: String, in app: XCUIApplication) -> Bool {
        fuel(name, checked: false, in: app).exists || fuel(name, checked: true, in: app).exists
    }

    private func assertNoEmptyGasMessage(in app: XCUIApplication) {
        XCTAssertFalse(app.staticTexts[noGasCopy].exists)
        XCTAssertFalse(identified("noGasStations", in: app).exists)
        XCTAssertFalse(app.staticTexts[gasFailedCopy].exists)
    }

    private func routeGeneration(in app: XCUIApplication) -> Int {
        scrollToTop(app)
        var element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'routeGeneration.'"))
            .firstMatch
        var swipes = 0
        while !element.exists && swipes < 6 {
            swipePlanningList(in: app, up: true)
            element = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'routeGeneration.'"))
                .firstMatch
            swipes += 1
        }
        XCTAssertTrue(element.exists, "Route generation was not exposed.\n\n\(diagnosticTree(app))")
        let suffix = element.identifier.split(separator: ".").last.map(String.init) ?? ""
        return Int(suffix) ?? -1
    }

    /// `waypoint.<name>` only. Highlight identifiers start with `highlight.`
    /// and must not be read as another stop of the same name.
    private func waypointName(from identifier: String) -> String? {
        let prefix = "waypoint."
        guard identifier.hasPrefix(prefix) else { return nil }
        let name = String(identifier.dropFirst(prefix.count))
        guard !name.isEmpty else { return nil }
        return name
    }

    /// True when `names` can be found in `ordered` from left to right.
    /// A repeated name has to occur again later in `ordered`; one earlier
    /// copy does not hide a second stop.
    private func namesAreOrderedSubset(_ names: [String], of ordered: [String]) -> Bool {
        var cursor = ordered.startIndex
        for name in names {
            guard let found = ordered[cursor...].firstIndex(of: name) else { return false }
            cursor = ordered.index(after: found)
        }
        return true
    }

    private func waypointNames(in app: XCUIApplication) -> [String] {
        dismissKeyboard(app)
        expandPlanningSheet(app)
        scrollToTop(app)
        var ordered: [String] = []
        func visibleNames() -> [String] {
            let elements = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'waypoint.'"))
                .allElementsBoundByIndex
                .filter { $0.exists && $0.frame.height > 1 }
                .sorted { $0.frame.minY < $1.frame.minY }
            var names: [String] = []
            var lastFrame: CGRect = .null
            for element in elements {
                // Ride Highlight ids (`highlight.<name>.…`) are not stops on
                // the ride. Only the waypoint prefix counts, even when a
                // highlight row is on screen beside the route list.
                guard let name = waypointName(from: element.identifier) else { continue }
                // The row, its representation, and the title text share one
                // id. Overlapping frames are that one stop. A second stop
                // with the same name is the next row down and does not overlap.
                let slop = lastFrame.insetBy(dx: 0, dy: -2)
                if names.last == name, slop.intersects(element.frame) {
                    lastFrame = lastFrame.union(element.frame)
                    continue
                }
                names.append(name)
                lastFrame = element.frame
            }
            return names
        }
        func absorb(_ names: [String]) {
            guard !names.isEmpty else { return }
            if ordered.isEmpty {
                ordered = names
                return
            }
            // Scrolling past highlights brings the same route rows back.
            // Appending that screen again is how one stop was counted twice.
            if namesAreOrderedSubset(names, of: ordered) { return }
            let limit = min(ordered.count, names.count)
            for overlap in stride(from: limit, through: 0, by: -1) {
                if Array(ordered.suffix(overlap)) == Array(names.prefix(overlap)) {
                    ordered.append(contentsOf: names.dropFirst(overlap))
                    return
                }
            }
            ordered.append(contentsOf: names)
        }
        absorb(visibleNames())
        for _ in 0..<12 {
            swipePlanningList(in: app, up: true)
            absorb(visibleNames())
        }
        return ordered
    }

    private func fuel(_ name: String, checked: Bool, in app: XCUIApplication) -> XCUIElement {
        identified("fuelStop.\(name).\(checked ? "checked" : "unchecked")", in: app)
    }

    private func identified(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 8) {
        expandPlanningSheet(app)
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            swipePlanningList(in: app, up: !element.exists || element.frame.minY > app.frame.midY)
            swipes += 1
        }
        XCTAssertTrue(element.isHittable, "Control was not on screen.\n\n\(diagnosticTree(app))")
    }

    /// Route rows only. Map pins use the bare station name and are not stops
    /// on the ride. The failure names the rows that were found so a pin dump
    /// is not read as a duplicate list.
    private func assertWaypointListed(
        _ name: String,
        in app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        expandPlanningSheet(app)
        scrollToTop(app)
        var names = waypointNames(in: app)
        if !names.contains(name) {
            scrollToTop(app)
            names = waypointNames(in: app)
        }
        let pins = ["Pilot Madison", "On Route Fuel", "Shell Knoxville", "Quick Stop", "Home Fuel"]
            .filter { mapShowsStation($0, in: app) }
        XCTAssertTrue(
            names.contains(name),
            """
            \(name) was not a route row.
            Route rows: \(names)
            Map pins: \(pins)
            \(diagnosticTree(app))
            """,
            file: file,
            line: line
        )
    }

    /// Scrolls `planningList` from its current offset until `identifier` exists.
    /// Swipes down first (Leave later sits below the tank slider), then back
    /// up in case a drag passed the row. The count is bounded.
    private func scrollPlanningListUntilExists(
        _ identifier: String,
        in app: XCUIApplication,
        maxSwipes: Int
    ) -> XCUIElement {
        expandPlanningSheet(app)
        if let found = control(identifier, in: app) { return found }
        for pass in 0..<2 {
            let up = pass == 0
            for _ in 0..<maxSwipes {
                dragPlanningList(in: app, up: up)
                if let found = waitForControl(identifier, in: app, timeout: 0.6) { return found }
            }
        }
        return identified(identifier, in: app)
    }

    private func control(_ identifier: String, in app: XCUIApplication) -> XCUIElement? {
        let any = identified(identifier, in: app)
        if any.exists { return any }
        let toggle = app.switches[identifier]
        if toggle.exists { return toggle }
        return nil
    }

    private func waitForControl(
        _ identifier: String,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let found = control(identifier, in: app) { return found }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return control(identifier, in: app)
    }

    /// A planning-list drag of about a third of the sheet. Slow, and held at
    /// the end, so the lazy row is created instead of flung past the poll.
    private func dragPlanningList(in app: XCUIApplication, up: Bool) {
        let list = planningList(in: app)
        guard list.elementType != .application, list.exists, list.frame.width > 40, list.frame.height > 40 else {
            swipePlanningList(in: app, up: up)
            return
        }
        let startY: CGFloat = up ? 0.78 : 0.32
        let endY: CGFloat = up ? 0.42 : 0.68
        let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
        let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.15)
    }

    /// Brings `id` on screen. Does not fail; callers assert and attach the tree.
    private func reveal(_ id: String, in app: XCUIApplication, timeout: TimeInterval = 20) -> XCUIElement {
        revealEither([id], in: app, timeout: timeout)
    }

    private func revealEither(_ ids: [String], in app: XCUIApplication, timeout: TimeInterval) -> XCUIElement {
        expandPlanningSheet(app)
        scrollToTop(app)
        let deadline = Date().addingTimeInterval(timeout)
        var down = 0
        while Date() < deadline {
            for id in ids {
                let element = identified(id, in: app)
                if element.exists { return element }
            }
            // A half-list swipe jumps over the highlight rows. They are short,
            // and the poll only sees the list between drags.
            if down >= 40 {
                scrollToTop(app)
                down = 0
            } else {
                nudgePlanningList(in: app, up: true)
                down += 1
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.12))
        }
        return identified(ids[0], in: app)
    }

    private struct FuelScan: CustomStringConvertible {
        var identifiers: [String]
        var labels: [String]

        func mentions(_ name: String) -> Bool {
            identifiers.contains { $0.contains(name) } || labels.contains { $0.contains(name) }
        }

        /// Checked state lives on the identifier. A "Fuel stop" label still
        /// counts as unchecked, which is how a List cell exposes the row when
        /// it does not forward the button's identifier.
        func shows(_ name: String, checked: Bool) -> Bool {
            let suffix = checked ? "checked" : "unchecked"
            if identifiers.contains("fuelStop.\(name).\(suffix)") { return true }
            if checked { return false }
            return labels.contains { $0.contains("Fuel stop") && $0.contains(name) }
        }

        var description: String {
            "ids=\(identifiers) labels=\(labels)"
        }
    }

    private func assertFuelRow(
        _ name: String,
        checked: Bool,
        in scan: FuelScan,
        app: XCUIApplication,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(
            scan.shows(name, checked: checked),
            "\(name) checked=\(checked) was not in the fuel list. \(scan)\n\(diagnosticTree(app))",
            file: file,
            line: line
        )
    }

    private func scanFuelRows(in app: XCUIApplication) -> FuelScan {
        dismissKeyboard(app)
        expandPlanningSheet(app)
        scrollToTop(app)
        var identifiers: [String] = []
        var labels: [String] = []
        var seenIDs = Set<String>()
        var seenLabels = Set<String>()
        func collect() {
            let idElements = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'fuelStop.'"))
                .allElementsBoundByIndex
            for element in idElements where element.exists && seenIDs.insert(element.identifier).inserted {
                identifiers.append(element.identifier)
            }
            let labelElements = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Fuel stop'"))
                .allElementsBoundByIndex
            for element in labelElements where element.exists && seenLabels.insert(element.label).inserted {
                labels.append(element.label)
            }
        }
        collect()
        for _ in 0..<8 {
            swipePlanningList(in: app, up: true)
            collect()
        }
        return FuelScan(identifiers: identifiers, labels: labels)
    }

    /// Full accessibility hierarchy. The first lines are the map, so a prefix
    /// clip hid the planning list and made a missing fuel row look like the
    /// whole failure.
    private func diagnosticTree(_ app: XCUIApplication) -> String {
        let full = app.debugDescription
        let keywords = [
            "fuelStop", "Fuel stop", "recommendedFuelPlan", "Pilot", "Madison", "Shell", "On Route",
            "Quick Stop", "Home Fuel", "selectRecommended", "tankRange",
            "leaveLater", "routeStyle", "waypoint.", "noGas", "replan",
            "Plan Ride", "gas station", "Navigate", "Apply", "placeSearch",
            "rideHighlights", "Ride Highlights", "highlight.", "Tallulah", "Bare Overlook",
            "routeMapFrame"
        ]
        let highlights = full.split(separator: "\n").filter { line in
            keywords.contains { line.localizedCaseInsensitiveContains($0) }
        }
        return """
        Matching lines (\(highlights.count)):
        \(highlights.joined(separator: "\n"))

        Accessibility tree (\(full.count) chars):
        \(full)
        """
    }

    private func scrollToTop(_ app: XCUIApplication) {
        expandPlanningSheet(app)
        for _ in 0..<12 {
            if let field = placeSearchField(in: app),
               field.frame.height > 1,
               field.frame.minY < app.frame.height * 0.55 {
                return
            }
            swipePlanningList(in: app, up: false)
        }
        expandPlanningSheet(app)
    }

    /// Drags the sheet grabber to the large detent. A half-height sheet only
    /// exposes the first list rows, so fuel stops and the destination never
    /// appear in the accessibility tree.
    private func expandPlanningSheet(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        guard grabber.exists else { return }
        for _ in 0..<3 {
            let value = (grabber.value as? String) ?? ""
            let nearTop = grabber.frame.minY < app.frame.height * 0.22
            if nearTop || value.localizedCaseInsensitiveContains("full") { return }
            let start = grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
            start.press(forDuration: 0.05, thenDragTo: top)
            RunLoop.current.run(until: Date().addingTimeInterval(0.35))
        }
    }

    private func attachScreenshot(_ name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        let hide = app.buttons["Hide keyboard"]
        if hide.exists && hide.isHittable {
            hide.tap()
        } else if app.keyboards.firstMatch.exists {
            let search = app.keyboards.buttons["Search"]
            if search.exists && search.isHittable {
                search.tap()
            }
        }
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, app.keyboards.firstMatch.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    /// Map pins stay up when the fuel list is scrolled off the sheet.
    private func mapShowsStation(_ name: String, in app: XCUIApplication) -> Bool {
        let pin = app.otherElements.matching(
            NSPredicate(format: "identifier == 'VKPointFeature' AND label CONTAINS %@", name)
        ).firstMatch
        if pin.exists { return true }
        return app.otherElements.matching(NSPredicate(format: "label == %@", name)).firstMatch.exists
    }

    /// Scrolls the planning sheet's list by about a third of its height.
    /// A full-screen swipe can skip a row, and a window swipe hits the map
    /// beside the sheet on a regular-width iPad.
    private func swipePlanningList(in app: XCUIApplication, up: Bool) {
        let list = planningList(in: app)
        // iPad can report the sheet list as not hittable while a drag inside
        // its frame still scrolls it. Require a real frame, not isHittable.
        if list.elementType != .application, list.exists, list.frame.width > 40, list.frame.height > 40 {
            let startY: CGFloat = up ? 0.8 : 0.3
            let endY: CGFloat = up ? 0.3 : 0.8
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: startY))
            let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end)
            return
        }
        // No list query yet. Drag under the sheet's navigation bar so the
        // gesture stays in the sheet on a wide iPad.
        let bar = app.navigationBars["Plan Ride"]
        guard bar.exists else {
            if up { app.swipeUp() } else { app.swipeDown() }
            return
        }
        let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 8 : 3))
        let end = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? 3 : 8))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// The sheet's list contains the search field. On iOS 17 that list is a
    /// table; later systems use a collection view. Either way it is not the map.
    private func planningList(in app: XCUIApplication) -> XCUIElement {
        for candidate in [
            app.collectionViews["planningList"],
            app.tables["planningList"],
            app.scrollViews["planningList"]
        ] where candidate.exists {
            return candidate
        }
        let tables = app.tables.containing(.textField, identifier: "placeSearch")
        if tables.count > 0 {
            return tables.element(boundBy: tables.count - 1)
        }
        let searchFields = app.tables.containing(.searchField, identifier: "placeSearch")
        if searchFields.count > 0 {
            return searchFields.element(boundBy: searchFields.count - 1)
        }
        let collections = app.collectionViews.containing(.textField, identifier: "placeSearch")
        if collections.count > 0 {
            return collections.element(boundBy: collections.count - 1)
        }
        let collectionSearch = app.collectionViews.containing(.searchField, identifier: "placeSearch")
        if collectionSearch.count > 0 {
            return collectionSearch.element(boundBy: collectionSearch.count - 1)
        }
        let scrolls = app.scrollViews.containing(.textField, identifier: "placeSearch")
        if scrolls.count > 0 {
            return scrolls.element(boundBy: scrolls.count - 1)
        }
        return app
    }
}
