import UIKit
import XCTest
import CoreLocation

/// Highlights live check (H-4) on real MapKit: Oklahoma City to Amarillo.
/// Cadillac Ranch and Slug Bug Ranch should be listed. Slug Bug Ranch shows
/// a real blurb about itself or no description line, never another
/// landmark's text. Adding a highlight keeps fuel stops already on the ride.
///
/// Screenshots go to `SMOKE_SHOTS_DIR` when set
/// (`TEST_RUNNER_SMOKE_SHOTS_DIR=... xcodebuild test`).
final class HighlightsLiveSmokeUITests: XCTestCase {

    private var shotsDir: URL?
    private let oklahomaCity = CLLocation(latitude: 35.4676, longitude: -97.5164)
    /// Text that belongs to another landmark. None of it may sit on Slug Bug Ranch.
    private let otherPlaceText = ["cadillac", "72oz", "72 oz", "steak challenge", "steak ranch"]

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
        app.launchArguments = ["-RideSummaryProbe"]
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
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 4), field.isHittable { field.tap() }
        field.typeText("Amarillo")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'searchResult.Amarillo'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "No Amarillo search result")
        result.tap()
        if app.keyboards.firstMatch.exists { app.keyboards.buttons["Return"].firstMatch.tapIfExists() }

        // Highlights publish after the line and the sights search.
        let header = element("highlightsListHeader", app)
        let deadline = Date().addingTimeInterval(240)
        var names: [String] = []
        while Date() < deadline {
            if scrollTo("highlightsListHeader", app) {
                names = highlightNames(app)
                let both = names.contains(where: { $0.localizedCaseInsensitiveContains("Cadillac Ranch") })
                    && names.contains(where: { $0.localizedCaseInsensitiveContains("Slug Bug") })
                // Descriptions load after the rows; give them a moment.
                if both {
                    sleep(6)
                    _ = scrollTo("highlightsListHeader", app)
                    names = highlightNames(app)
                    break
                }
                if Date() > deadline.addingTimeInterval(-150), !names.isEmpty { break }
            }
            sleep(3)
        }
        XCTAssertTrue(header.exists, "Highlights header never appeared")
        print("HLSMOKE header=\(header.label) names=\(names)")
        XCTAssertTrue(header.label.contains("Highlights ("), header.label)
        record("header", header.label)
        record("names", names.joined(separator: " | "))

        XCTAssertTrue(
            names.contains { $0.localizedCaseInsensitiveContains("Cadillac Ranch") },
            "Cadillac Ranch not listed: \(names)"
        )
        let slug = names.first { $0.localizedCaseInsensitiveContains("Slug Bug") }
        XCTAssertNotNil(slug, "Slug Bug Ranch not listed on OKC -> Amarillo: \(names)")

        for name in names {
            let description = element("highlight.\(name).description", app)
            let detail = element("highlight.\(name).detail", app)
            let text = description.exists ? description.label : "<no description line>"
            print("HLSMOKE row name=\(name) detail=\(detail.exists ? detail.label : "?") description=\(text)")
            record("row \(name)", "detail=\(detail.exists ? detail.label : "?")\ndescription=\(text)")
            if detail.exists {
                XCTAssertTrue(
                    detail.label.contains("on your route") || detail.label.contains("off route"),
                    "Detour copy missing on \(name): \(detail.label)"
                )
            }
        }
        if let slug {
            let description = element("highlight.\(slug).description", app)
            if description.exists {
                let lower = description.label.lowercased()
                for wrong in otherPlaceText {
                    XCTAssertFalse(lower.contains(wrong), "Slug Bug Ranch showed another place's text: \(description.label)")
                }
            }
        }
        _ = scrollTo("highlightsListHeader", app)
        snap("01_okc_amarillo_highlights", app)

        // Fuel first, so there is something to keep.
        if scrollTo("selectRecommended", app) {
            element("selectRecommended", app).tap()
            sleep(8)
        }
        let committed = element("committedWaypoints", app)
        let before = committed.exists ? committed.label.split(separator: "|").map(String.init) : []
        print("HLSMOKE before=\(before)")

        let target = names.first { $0.localizedCaseInsensitiveContains("Cadillac Ranch") } ?? slug ?? names.first
        guard let target else { return }
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
        _ = scrollTo("highlightsListHeader", app)
        snap("03_okc_amarillo_after_replan", app)
    }

    // MARK: - Helpers

    private func highlightNames(_ app: XCUIApplication) -> [String] {
        let rows = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH 'highlight.' AND identifier ENDSWITH '.name'"))
            .allElementsBoundByIndex
        var names: [String] = []
        for row in rows {
            let id = row.identifier
            let name = String(id.dropFirst("highlight.".count).dropLast(".name".count))
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
            let frame = list(app).frame
            return target.exists && target.frame.height > 0 && target.isHittable
                && target.frame.minY >= frame.minY - 2 && target.frame.maxY <= frame.maxY + 2
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
