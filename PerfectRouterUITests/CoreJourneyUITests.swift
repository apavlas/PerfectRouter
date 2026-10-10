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
            ["Test Origin", "Test Destination"]
        )
        XCTAssertTrue(fuel("Pilot Madison", checked: false, in: app).exists)
        XCTAssertTrue(fuel("On Route Fuel", checked: false, in: app).exists)
        XCTAssertTrue(fuel("Shell Knoxville", checked: false, in: app).exists)
        XCTAssertFalse(fuel("Quick Stop", checked: false, in: app).exists)
        XCTAssertFalse(fuel("Home Fuel", checked: false, in: app).exists)
        assertNoEmptyGasMessage(in: app)
    }

    func testSelectRecommendedChecksInRangeStopsAndSkipsOnRoute() {
        let app = launch()
        planFixedRoute(in: app)
        addOnRouteFuel(in: app)

        let select = app.buttons["selectRecommended"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollUntilHittable(select, in: app)
        select.tap()

        XCTAssertTrue(fuel("Pilot Madison", checked: true, in: app).waitForExistence(timeout: 3))
        XCTAssertTrue(fuel("Shell Knoxville", checked: true, in: app).waitForExistence(timeout: 3))
        XCTAssertFalse(fuel("On Route Fuel", checked: true, in: app).exists)
        XCTAssertFalse(fuel("On Route Fuel", checked: false, in: app).exists)
        XCTAssertFalse(fuel("Quick Stop", checked: true, in: app).exists)
        XCTAssertFalse(fuel("Home Fuel", checked: true, in: app).exists)

        let apply = app.buttons["applyStops"].firstMatch
        XCTAssertTrue(apply.waitForExistence(timeout: 3))
        XCTAssertTrue(
            apply.label.contains("Apply 2 stops"),
            "Select recommended included a stop that is not an in-range recommendation: \(apply.label)"
        )
        XCTAssertEqual(waypointNames(in: app).filter { $0 == "On Route Fuel" }.count, 1)
    }

    func testApplyReplansOnceWithStopsInRideOrder() {
        let app = launch()
        planFixedRoute(in: app)
        addOnRouteFuel(in: app)
        tapSelectRecommended(in: app)

        let before = routeGeneration(in: app)
        tapApply(in: app)

        assertReplanBanner(contains: "Fastest", in: app)
        waitForBannerToFinish(in: app)
        waitForFuelName("Pilot Madison", in: app)

        XCTAssertEqual(routeGeneration(in: app), before + 1)
        XCTAssertFalse(identified("routeGeneration.\(before + 2)", in: app).exists)
        XCTAssertEqual(
            waypointNames(in: app),
            ["Test Origin", "Pilot Madison", "On Route Fuel", "Shell Knoxville", "Test Destination"]
        )
        assertNoEmptyGasMessage(in: app)
    }

    func testSelectRecommendedAgainAddsNoDuplicates() {
        let app = launch()
        planFixedRoute(in: app)
        addOnRouteFuel(in: app)
        tapSelectRecommended(in: app)

        tapApply(in: app)
        assertReplanBanner(contains: "Fastest", in: app)
        waitForBannerToFinish(in: app)
        waitForFuelName("Pilot Madison", in: app)

        let afterApply = waypointNames(in: app)
        let select = app.buttons["selectRecommended"]
        if select.waitForExistence(timeout: 2) {
            scrollUntilHittable(select, in: app)
            select.tap()
            if app.buttons["applyStops"].waitForExistence(timeout: 1) {
                tapApply(in: app)
                waitForBannerToFinish(in: app)
                waitForFuelName("Pilot Madison", in: app)
            }
        }

        let names = waypointNames(in: app)
        XCTAssertEqual(names, afterApply)
        XCTAssertEqual(Set(names).count, names.count, "Duplicate waypoints: \(names)")
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
            XCTAssertTrue(app.buttons["Navigate"].waitForExistence(timeout: 10))
            waitForFuelName("Pilot Madison", in: app)
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

        let slider = app.sliders["tankRangeSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5))
        scrollUntilHittable(slider, in: app)
        slider.adjust(toNormalizedSliderPosition: 0.55)
        assertReplanDoesNotClaimTheRoadIsEmpty(in: app)

        let leaveLater = app.switches["leaveLaterToggle"]
        XCTAssertTrue(leaveLater.waitForExistence(timeout: 5))
        scrollUntilHittable(leaveLater, in: app)
        leaveLater.tap()
        assertReplanDoesNotClaimTheRoadIsEmpty(in: app)
        XCTAssertTrue(app.buttons["Navigate"].waitForExistence(timeout: 10))
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
        waitForFuelName("Pilot Madison", in: app)
        waitForFuelName("On Route Fuel", in: app)
        waitForFuelName("Shell Knoxville", in: app)
        assertNoEmptyGasMessage(in: app)
    }

    private func addOnRouteFuel(in app: XCUIApplication) {
        search("On Route Fuel", in: app)
        XCTAssertTrue(identified("waypoint.On Route Fuel", in: app).waitForExistence(timeout: 5))
        assertReplanBanner(contains: "Fastest", in: app)
        waitForBannerToFinish(in: app)
        waitForFuelName("Pilot Madison", in: app)
        waitForFuelName("Shell Knoxville", in: app)
        XCTAssertFalse(fuel("On Route Fuel", checked: false, in: app).exists)
        XCTAssertFalse(fuel("On Route Fuel", checked: true, in: app).exists)
    }

    private func search(_ name: String, in app: XCUIApplication) {
        let field = waitForPlaceSearch(in: app)
        scrollUntilHittable(field, in: app)
        field.tap()
        field.typeText(name)
        let result = app.buttons["searchResult.\(name)"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        scrollUntilHittable(result, in: app)
        result.tap()
    }

    /// The planner uses a text field. Wait for either that or a search field
    /// so a regular-width sheet is not pinned to one element type.
    private func waitForPlaceSearch(in app: XCUIApplication, timeout: TimeInterval = 5) -> XCUIElement {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let text = app.textFields["placeSearch"]
            if text.exists { return text }
            let search = app.searchFields["placeSearch"]
            if search.exists { return search }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Place search did not appear")
        return app.textFields["placeSearch"]
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
        XCTFail("Apply was not on screen")
    }

    private func tapSelectRecommended(in app: XCUIApplication) {
        let select = app.buttons["selectRecommended"]
        XCTAssertTrue(select.waitForExistence(timeout: 5))
        scrollUntilHittable(select, in: app)
        select.tap()
        XCTAssertTrue(fuel("Pilot Madison", checked: true, in: app).waitForExistence(timeout: 3))
    }

    // MARK: - Route style

    private func selectRouteStyle(_ style: String, in app: XCUIApplication) {
        var picker = identified("routeStylePicker", in: app)
        if !picker.waitForExistence(timeout: 2) {
            picker = app.buttons["Route style"]
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        scrollUntilHittable(picker, in: app)
        picker.tap()

        let byID = identified("routeStyleOption.\(style)", in: app)
        if byID.waitForExistence(timeout: 2), byID.isHittable {
            byID.tap()
            return
        }
        // iPhone shows a menu of buttons. iPad can show the same choices in a popover
        // whose rows are cells or static texts, so match the label on any hittable element.
        let byLabel = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", style))
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            for index in 0..<byLabel.count {
                let option = byLabel.element(boundBy: index)
                if option.isHittable {
                    option.tap()
                    return
                }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Route style \(style) was not hittable")
    }

    // MARK: - Assertions

    private func assertReplanBanner(contains style: String, in app: XCUIApplication) {
        let banners = app.descendants(matching: .any).matching(identifier: "replanBanner")
        let deadline = Date().addingTimeInterval(8)
        var lastLabel = ""
        while Date() < deadline {
            for index in 0..<banners.count {
                let banner = banners.element(boundBy: index)
                guard banner.exists else { continue }
                lastLabel = banner.label
                if banner.label.contains(style) { return }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Replanning banner for \(style) did not appear (last label: \(lastLabel))")
    }

    private func waitForBannerToFinish(in app: XCUIApplication) {
        let banners = app.descendants(matching: .any).matching(identifier: "replanBanner")
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if banners.count == 0 { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Replanning banner did not finish")
    }

    private func waitForFuelName(_ name: String, in app: XCUIApplication, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fuel(name, checked: false, in: app).exists || fuel(name, checked: true, in: app).exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Fuel stop \(name) did not appear")
    }

    private func assertReplanDoesNotClaimTheRoadIsEmpty(in app: XCUIApplication) {
        let deadline = Date().addingTimeInterval(12)
        var settled = false
        while Date() < deadline {
            assertNoEmptyGasMessage(in: app)
            let searching = app.staticTexts["Searching for gas along the route…"].exists
                || app.staticTexts["Searching along your route…"].exists
                || app.descendants(matching: .any).matching(identifier: "replanBanner").count > 0
            let station = ["Pilot Madison", "On Route Fuel", "Shell Knoxville", "Quick Stop", "Home Fuel"]
                .contains { fuelListed($0, in: app) }
            if !searching && station {
                settled = true
                break
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        }
        assertNoEmptyGasMessage(in: app)
        XCTAssertTrue(settled, "Tank or departure change did not finish with gas still listed")
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
        let element = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'routeGeneration.'"))
            .firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        let suffix = element.identifier.split(separator: ".").last.map(String.init) ?? ""
        return Int(suffix) ?? -1
    }

    private func waypointNames(in app: XCUIApplication) -> [String] {
        scrollToTop(app)
        var ordered: [String] = []
        var seen = Set<String>()
        func collect() {
            let elements = app.descendants(matching: .any)
                .matching(NSPredicate(format: "identifier BEGINSWITH 'waypoint.'"))
                .allElementsBoundByIndex
            let positioned = elements
                .filter { $0.frame.height > 1 && $0.frame.minY > 1 }
                .sorted { $0.frame.minY < $1.frame.minY }
            for element in positioned {
                let name = String(element.identifier.dropFirst("waypoint.".count))
                if seen.insert(name).inserted {
                    ordered.append(name)
                }
            }
        }
        collect()
        // A lazy list only exposes rows that have been brought on screen.
        // Swipe the sheet, not the window: on iPad the map sits beside it.
        for _ in 0..<6 {
            swipePlanningList(in: app, up: true)
            collect()
        }
        return ordered
    }

    private func fuel(_ name: String, checked: Bool, in app: XCUIApplication) -> XCUIElement {
        identified("fuelStop.\(name).\(checked ? "checked" : "unchecked")", in: app)
    }

    private func identified(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func scrollUntilHittable(_ element: XCUIElement, in app: XCUIApplication, maxSwipes: Int = 20) {
        var swipes = 0
        while !element.isHittable && swipes < maxSwipes {
            swipePlanningList(in: app, up: true)
            swipes += 1
        }
        // A tall iPad sheet can leave the row above the fold after those swipes.
        var back = 0
        while !element.isHittable && back < 6 {
            swipePlanningList(in: app, up: false)
            back += 1
        }
        XCTAssertTrue(element.isHittable)
    }

    private func scrollToTop(_ app: XCUIApplication) {
        for _ in 0..<8 {
            swipePlanningList(in: app, up: false)
        }
    }

    /// Scrolls the planning sheet's list. A window-level swipe lands on the
    /// map beside the sheet when the iPad is regular width.
    private func swipePlanningList(in app: XCUIApplication, up: Bool) {
        let list = planningList(in: app)
        if list.elementType != .application, list.exists {
            if up {
                list.swipeUp()
            } else {
                list.swipeDown()
            }
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
