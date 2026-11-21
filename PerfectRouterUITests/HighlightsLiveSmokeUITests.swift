import UIKit
import XCTest
import CoreLocation

/// Highlights live check (H-4) on real MapKit: Oklahoma City to Amarillo.
/// Live MapKit decides which landmarks come back, so the test does not
/// require any one place. At least one highlight must be listed with detour
/// copy, and adding one must show the Undo banner, put it on the ride,
/// keep the fuel stops already there, and mark the row Added. Cadillac
/// Ranch or Slug Bug Ranch is preferred as the added row when listed, and
/// Slug Bug Ranch, when listed, must never carry another landmark's text.
///
/// Screenshots go to `SMOKE_SHOTS_DIR` when set
/// (`TEST_RUNNER_SMOKE_SHOTS_DIR=... xcodebuild test`).
final class HighlightsLiveSmokeUITests: XCTestCase {

    private var shotsDir: URL?
    private let oklahomaCity = CLLocation(latitude: 35.4676, longitude: -97.5164)
    /// Text that belongs to another landmark. None of it may sit on Slug Bug Ranch.
    private let otherPlaceText = ["cadillac", "72oz", "72 oz", "steak challenge", "steak ranch"]
    /// Names to treat as not returned (`TEST_RUNNER_SMOKE_HIGHLIGHT_SKIP=Cadillac Ranch,Slug Bug`),
    /// to exercise the path where live MapKit leaves the known landmarks out.
    private let skippedNames = (ProcessInfo.processInfo.environment["SMOKE_HIGHLIGHT_SKIP"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

    override func setUpWithError() throws {
        continueAfterFailure = true
        if let dir = ProcessInfo.processInfo.environment["SMOKE_SHOTS_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            shotsDir = url
        }
    }

    func testOklahomaCityToAmarilloHighlights() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSkipOnboarding", "-RideSummaryProbe"]
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for title in ["Allow While Using App", "Allow Once", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        XCUIDevice.shared.location = XCUILocation(location: oklahomaCity)
        app.launch()
        XCTAssertTrue(
            app.navigationBars["Plan Ride"].waitForExistence(timeout: 15)
                || app.staticTexts["Plan Ride"].exists,
            "Plan Ride did not appear"
        )
        expandSheet(app)

        let field = placeSearch(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "placeSearch missing")
        PlaceSearchTyping.type("Amarillo", into: field, in: app)
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchResult.Amarillo'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "No Amarillo search result")
        result.tap()
        if app.keyboards.firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tapIfExists() }

        // Highlights publish after the line and the sights search.
        let header = element("highlightsListHeader", app)
        let deadline = Date().addingTimeInterval(240)
        var names: [String] = []
        // Wait until the rows stop changing: the same non-empty list on two
        // polls in a row. Both known landmarks listed ends the wait early.
        var stablePolls = 0
        while Date() < deadline {
            if revealHighlights(app) {
                let current = highlightNames(app)
                stablePolls = (!current.isEmpty && current == names) ? stablePolls + 1 : 0
                names = current
                let both = names.contains(where: { $0.localizedCaseInsensitiveContains("Cadillac Ranch") })
                    && names.contains(where: { $0.localizedCaseInsensitiveContains("Slug Bug") })
                if both || stablePolls >= 2 { break }
            }
            sleep(3)
        }
        // Descriptions load after the rows; give them a moment.
        if !names.isEmpty {
            sleep(6)
            _ = revealHighlights(app)
            names = highlightNames(app)
        }
        XCTAssertTrue(header.exists, "Highlights header never appeared")
        print("HLSMOKE header=\(header.label) names=\(names)")
        XCTAssertTrue(header.label.contains("Highlights ("), header.label)
        record("header", header.label)
        record("names", names.joined(separator: " | "))

        XCTAssertFalse(names.isEmpty, "No highlight rows on OKC -> Amarillo")
        // Which landmarks live MapKit returned today. Recorded, not required.
        let cadillac = names.first { $0.localizedCaseInsensitiveContains("Cadillac Ranch") }
        let slug = names.first { $0.localizedCaseInsensitiveContains("Slug Bug") }
        print("HLSMOKE cadillacListed=\(cadillac != nil) slugBugListed=\(slug != nil)")
        record("known landmarks", "Cadillac Ranch listed=\(cadillac != nil)\nSlug Bug Ranch listed=\(slug != nil)")
        var rowsWithDetour = 0

        for name in names {
            let description = element("highlight.\(name).description", app)
            let detail = element("highlight.\(name).detail", app)
            let text = description.exists ? description.label : "<no description line>"
            print("HLSMOKE row name=\(name) detail=\(detail.exists ? detail.label : "?") description=\(text)")
            record("row \(name)", "detail=\(detail.exists ? detail.label : "?")\ndescription=\(text)")
            if detail.exists {
                rowsWithDetour += 1
                XCTAssertTrue(
                    (detail.label.contains("On route") || detail.label.contains("off route")) && !detail.label.contains("~"),
                    "Detour copy missing on \(name): \(detail.label)"
                )
                // Clara Luper Sit-in Plaza is a block from the downtown OKC
                // start. It read "~20 mi from start" off the search sample.
                if name.localizedCaseInsensitiveContains("Clara Luper") {
                    let miles = Double(detail.label.split(separator: " ").first ?? "") ?? 0
                    XCTAssertTrue(detail.label.hasPrefix("At start") || miles < 5,
                                  "Clara Luper is at the start, not \(detail.label)")
                }
            }
        }
        XCTAssertGreaterThan(rowsWithDetour, 0, "No highlight row showed detour copy: \(names)")
        if let slug {
            let description = element("highlight.\(slug).description", app)
            if description.exists {
                let lower = description.label.lowercased()
                for wrong in otherPlaceText {
                    XCTAssertFalse(lower.contains(wrong), "Slug Bug Ranch showed another place's text: \(description.label)")
                }
            }
        }
        _ = revealHighlights(app)
        snap("01_okc_amarillo_highlights", app)

        // Fuel first, so there is something to keep.
        let probe = element("rideSummaryProbe", app)
        if probe.exists { print("HLSMOKE probe=\(probe.label)") }
        let fuelRows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'Fuel stop '")).allElementsBoundByIndex
            .compactMap { (try? $0.snapshot())?.label }
        print("HLSMOKE fuelRows=\(fuelRows)")
        record("fuel rows", fuelRows.joined(separator: "\n"))
        let waypointsBeforeFuel = element("committedWaypoints", app).label.split(separator: "|").map(String.init)
        // Evidence for review: the fuel list as the rider sees it.
        if scrollTo("gasListHeader", app) { snap("00_okc_amarillo_fuel_list", app) }
        // Leg copy evidence: every leg header and its rows, top to bottom,
        // in overlapping shots that review stitches into one image.
        if ProcessInfo.processInfo.environment["SMOKE_LEG_SHOTS"] == "1", scrollTo("gasListHeader", app) {
            if let row = try? element("gasListHeader", app).snapshot(),
               let pane = try? list(app).snapshot(),
               row.frame.minY > pane.frame.minY + pane.frame.height * 0.2 {
                swipe(app, up: true, fraction: 0.4)
            }
            var titles: [Int: String] = [:]
            var tightLegs: [String] = []
            for shot in 0..<7 {
                for number in 1...8 {
                    let header = element("gasLeg.\(number)", app)
                    if header.exists, titles[number] == nil { titles[number] = header.label }
                }
                // FUEL-9: "Tight leg" lines under stops whose next leg rides into the reserve.
                for row in app.descendants(matching: .any)
                    .matching(NSPredicate(format: "identifier BEGINSWITH 'fuelTightLeg.'")).allElementsBoundByIndex {
                    guard let snap = try? row.snapshot() else { continue }
                    let item = "\(snap.identifier)=\(snap.label)"
                    if !tightLegs.contains(item) { tightLegs.append(item) }
                }
                snap("00_legs_\(shot)", app)
                swipe(app, up: true, fraction: 0.3)
                sleep(1)
            }
            print("HLSMOKE legTitles=\(titles.keys.sorted().compactMap { titles[$0] })")
            print("HLSMOKE tightLegs=\(tightLegs)")
        }
        let planText = probe.exists ? probe.label : ""
        func probeField(_ key: String) -> String {
            planText.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } ?? ""
        }
        let planMiles = probeField("fuel").split(separator: ",").compactMap { Double($0) }
        let totalMiles = Double(probeField("total")) ?? 0
        let tankMiles = Double(probeField("tank")) ?? 0
        let marks = [0] + planMiles + [totalMiles]
        let legMiles = zip(marks.dropFirst(), marks).map { (($0 - $1) * 10).rounded() / 10 }
        print("HLSMOKE fuelPlanMiles=\(planMiles) legs=\(legMiles) tank=\(tankMiles)")
        if scrollTo("selectRecommended", app) {
            element("selectRecommended", app).tap()
            sleep(8)
        }
        let committed = element("committedWaypoints", app)
        let before = committed.exists ? committed.label.split(separator: "|").map(String.init) : []
        print("HLSMOKE before=\(before)")
        if scrollTo("gasListHeader", app) { snap("00b_okc_amarillo_fuel_after_select", app) }
        // FUEL-8: every planned stop is committed, and no leg is past the tank.
        let fuelAdded = before.filter { !waypointsBeforeFuel.contains($0) }
        print("HLSMOKE fuel8 added=\(fuelAdded)")
        XCTAssertEqual(fuelAdded.count, planMiles.count, "Select recommended dropped planned stops: plan=\(planMiles) added=\(fuelAdded)")
        XCTAssertGreaterThanOrEqual(planMiles.count, 3, "Fewer than 3 fuel stops on OKC -> Amarillo: \(planMiles)")
        if tankMiles > 0 {
            XCTAssertTrue(legMiles.allSatisfy { $0 <= tankMiles }, "Leg past the \(tankMiles) mi tank: \(legMiles)")
        }
        // FUEL-7: what Select recommended added must all be working pumps.
        let notAPump = ["restored", "historic", "museum", "replica", "memorial", "monument", "landmark"]
        for stop in before where !waypointsBeforeFuel.contains(stop) {
            XCTAssertFalse(
                notAPump.contains { stop.lowercased().contains($0) },
                "Select recommended added a place that is not a pump: \(stop)"
            )
            XCTAssertFalse(names.contains(stop), "Select recommended added a highlight as fuel: \(stop)")
        }

        // Prefer a known landmark; otherwise any listed row. One that is
        // already on the ride (start or destination) cannot be added.
        let candidates = [cadillac, slug].compactMap { $0 } + names
        guard let target = candidates.first(where: { name in
            let add = element("highlight.\(name).add", app)
            return !add.exists || (add.value as? String) != "Added"
        }) else {
            XCTFail("Every highlight was already Added before the test added one: \(names)")
            return
        }
        print("HLSMOKE target=\(target)")
        record("added", target)
        XCTAssertTrue(scrollTo("highlight.\(target).add", app), "Add button for \(target) not reachable")
        element("highlight.\(target).add", app).tap()
        let banner = element("highlightUndoBanner", app)
        XCTAssertTrue(banner.waitForExistence(timeout: 4), "No Undo banner after adding \(target)")
        if banner.exists { print("HLSMOKE banner=\(banner.label)") }
        snap("02_okc_amarillo_after_add", app)

        var after: [String] = []
        for _ in 0..<30 {
            after = committed.label.split(separator: "|").map(String.init)
            if after.contains(target) { break }
            sleep(1)
        }
        print("HLSMOKE after=\(after)")
        record("waypoints", "before=\(before)\nafter=\(after)")
        XCTAssertTrue(after.contains(target), "\(target) not on the ride: \(after)")
        for stop in before {
            XCTAssertTrue(after.contains(stop), "\(stop) was dropped when \(target) was added: \(after)")
        }
        sleep(10)
        XCTAssertTrue(scrollTo("highlight.\(target).add", app), "\(target) row gone after the replan")
        let added = element("highlight.\(target).add", app)
        XCTAssertEqual(added.value as? String, "Added", "\(target) row not marked Added")
        snap("03_okc_amarillo_after_replan", app)
    }

    // MARK: - Helpers

    /// The header plus its rows. The lazy list only builds rows on screen,
    /// and a taller ride summary (three fuel stops with food) can leave the
    /// header at the bottom edge with every row below it.
    private func revealHighlights(_ app: XCUIApplication) -> Bool {
        guard scrollTo("highlightsListHeader", app) else { return false }
        if let row = try? element("highlightsListHeader", app).snapshot(),
           let pane = try? list(app).snapshot(),
           row.frame.midY > pane.frame.midY {
            swipe(app, up: true, fraction: 0.4)
        }
        return true
    }

    private func highlightNames(_ app: XCUIApplication) -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'highlight.' AND identifier ENDSWITH '.name'"))
            .allElementsBoundByIndex
        var names: [String] = []
        for row in rows {
            let id = row.identifier
            let name = String(id.dropFirst("highlight.".count).dropLast(".name".count))
            if skippedNames.contains(where: { name.localizedCaseInsensitiveContains($0) }) { continue }
            if !names.contains(name) { names.append(name) }
        }
        return names
    }

    private func element(_ id: String, _ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func record(_ name: String, _ text: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func placeSearch(_ app: XCUIApplication) -> XCUIElement {
        for candidate in [app.textFields["placeSearch"], app.searchFields["placeSearch"]] where candidate.exists {
            return candidate
        }
        return app.descendants(matching: .any).matching(identifier: "placeSearch").firstMatch
    }

    private func list(_ app: XCUIApplication) -> XCUIElement {
        for candidate in [app.collectionViews["planningList"], app.tables["planningList"]] where candidate.exists {
            return candidate
        }
        return app.collectionViews.firstMatch
    }

    private func swipe(_ app: XCUIApplication, up: Bool, fraction: CGFloat = 0.4) {
        let target = list(app)
        guard target.exists, target.frame.height > 40 else {
            if up { app.swipeUp() } else { app.swipeDown() }
            return
        }
        let low: CGFloat = 0.5 + fraction / 2
        let high: CGFloat = 0.5 - fraction / 2
        let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? low : high))
        let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: up ? high : low))
        start.press(forDuration: 0.05, thenDragTo: end)
    }

    /// Brings `identifier` into the visible list. Highlights sit just under
    /// the ride summary, so this walks down from the top, then back up.
    private func scrollTo(_ identifier: String, _ app: XCUIApplication) -> Bool {
        let target = element(identifier, app)
        func visible() -> Bool {
            // One snapshot: the replan rebuilds the rows, and reading
            // `frame` on a row that just left the tree fails the test
            // instead of returning false.
            guard let row = try? target.snapshot(), let pane = try? list(app).snapshot() else { return false }
            return row.frame.height > 0
                && row.frame.minY >= pane.frame.minY - 2 && row.frame.maxY <= pane.frame.maxY + 2
        }
        if visible() { return true }
        for direction in [true, false, true] {
            for _ in 0..<14 {
                if visible() { return true }
                swipe(app, up: direction)
            }
        }
        return visible()
    }

    private func expandSheet(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        guard grabber.exists else { return }
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: top)
    }

    private func snap(_ name: String, _ app: XCUIApplication) {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = "\(device)_\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotsDir {
            try? shot.pngRepresentation.write(to: dir.appendingPathComponent("highlights_\(device)_\(name).png"))
        }
    }
}

private extension XCUIElement {
    func tapIfExists() {
        if exists, isHittable { tap() }
    }
}
