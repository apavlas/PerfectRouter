import UIKit
import XCTest
import CoreLocation

/// Build 11 long-route smoke test on live MapKit: the simulator's current
/// location (set it to the Atlanta area with `simctl location`) to Denver,
/// about 1,622 mi over three riding days.
///
/// Reads the app's `rideSummaryProbe` (launched with `-RideSummaryProbe`)
/// so the checks do not depend on which rows the lazy list has built.
/// Screenshots go to `SMOKE_SHOTS_DIR` when set
/// (`TEST_RUNNER_SMOKE_SHOTS_DIR=... xcodebuild test`).
final class B11LongRouteSmokeUITests: XCTestCase {

    private struct Probe {
        var raw: String
        var total: Double
        var days: [(day: Int, miles: Double)]
        var routePastRange: Set<Int>
        var gasPastRange: Set<Int>
        var hotels: [Int: Int]
        var noLodging: Set<Int>
        var tank: Double
        var fuel: [Double]
        var loading: Bool

        init?(_ raw: String) {
            var fields: [String: String] = [:]
            for part in raw.split(separator: " ") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                fields[pair[0]] = pair.count > 1 ? pair[1] : ""
            }
            guard let total = fields["total"].flatMap(Double.init) else { return nil }
            func ints(_ key: String) -> Set<Int> {
                Set((fields[key] ?? "").split(separator: ",").compactMap { Int($0) })
            }
            func pairs(_ key: String) -> [(Int, String)] {
                (fields[key] ?? "").split(separator: ",").compactMap { item in
                    let bits = item.split(separator: ":").map(String.init)
                    guard bits.count == 2, let day = Int(bits[0]) else { return nil }
                    return (day, bits[1])
                }
            }
            self.raw = raw
            self.total = total
            days = pairs("days").compactMap { day, miles in Double(miles).map { (day, $0) } }
            routePastRange = ints("routePastRange")
            gasPastRange = ints("gasPastRange")
            hotels = Dictionary(pairs("hotels").compactMap { day, count in Int(count).map { (day, $0) } },
                                uniquingKeysWith: { first, _ in first })
            noLodging = ints("noLodging")
            tank = fields["tank"].flatMap(Double.init) ?? 0
            fuel = (fields["fuel"] ?? "").split(separator: ",").compactMap { Double($0) }
            loading = fields["loading"] == "true"
        }

        /// Days whose longest hop between anchors (start, each overnight is
        /// NOT a fill, recommended pumps, the destination) exceeds the tank.
        func daysWithHopPastTank() -> Set<Int> {
            var result = Set<Int>()
            let anchors = ([0] + fuel).sorted()
            var starts: [(Int, Double, Double)] = []
            var cursor = 0.0
            for (day, miles) in days {
                starts.append((day, cursor, cursor + miles))
                cursor += miles
            }
            func day(of mile: Double) -> Int? {
                starts.first { mile > $0.1 + 0.5 && mile <= $0.2 + 0.5 }?.0 ?? starts.last?.0
            }
            for (index, point) in (anchors.dropFirst() + [total]).enumerated() {
                let previous = anchors[index]
                if point - previous > tank, let number = day(of: point) {
                    result.insert(number)
                }
            }
            return result
        }
    }

    private var shotsDir: URL?

    override func setUpWithError() throws {
        continueAfterFailure = true
        if let dir = ProcessInfo.processInfo.environment["SMOKE_SHOTS_DIR"], !dir.isEmpty {
            let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
            let url = URL(fileURLWithPath: dir).appendingPathComponent(device)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            shotsDir = url
        }
    }

    func testAtlantaToDenverLongRouteSmoke() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-RideSummaryProbe", "-RideDepartureOverride", "2026-10-23T08:00"]
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for title in ["Allow While Using App", "Allow Once", "OK"] where alert.buttons[title].exists {
                alert.buttons[title].tap()
                return true
            }
            return false
        }
        // Pin the origin in-test: a stale simulator location (seen on iPad,
        // Alabama instead of Atlanta) changes the whole route.
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(latitude: 33.749, longitude: -84.388))
        app.launch()
        XCTAssertTrue(
            app.navigationBars["Plan Ride"].waitForExistence(timeout: 15)
                || app.staticTexts["Plan Ride"].exists,
            "Plan Ride did not appear"
        )
        expandSheet(app)
        snap("00_launch", app)

        // Route: Current Location -> Denver.
        let field = placeSearch(app)
        XCTAssertTrue(field.waitForExistence(timeout: 15), "placeSearch missing")
        field.tap()
        if !app.keyboards.firstMatch.waitForExistence(timeout: 4), field.isHittable { field.tap() }
        field.typeText("Denver")
        let result = app.buttons["searchResult.Denver"]
        XCTAssertTrue(result.waitForExistence(timeout: 30), "No Denver search result")
        result.tap()
        let started = Date()

        // Check 1: the list scrolls while loading (no main-actor freeze).
        // Also record what loading showed for totals and range labels.
        var maxSwipe: TimeInterval = 0
        var loadingTotals: [Double] = []
        var loadingRoutePastRange = Set<Int>()
        var loadingSamples = 0
        var settledSince: Date?
        var last: Probe?
        var up = true
        var swipes = 0
        while Date().timeIntervalSince(started) < 480 {
            let t0 = Date()
            swipe(app, up: up)
            let took = Date().timeIntervalSince(t0)
            maxSwipe = max(maxSwipe, took)
            swipes += 1
            if swipes % 4 == 0 { up.toggle() }
            if swipes % 6 == 1 { snap(String(format: "a_load_%02d", swipes / 6), app) }

            guard let probe = readProbe(app) else { continue }
            last = probe
            if probe.loading, probe.total > 0 {
                loadingSamples += 1
                loadingTotals.append(probe.total)
                loadingRoutePastRange.formUnion(probe.routePastRange)
            }
            let ready = !probe.loading && probe.total > 0 && !probe.fuel.isEmpty
                && probe.days.count >= 2 && !probe.hotels.isEmpty
            if ready {
                if settledSince == nil { settledSince = Date() }
                if let since = settledSince, Date().timeIntervalSince(since) > 12 { break }
            } else {
                settledSince = nil
            }
        }
        XCTAssertLessThan(maxSwipe, 8, "A list swipe took \(maxSwipe)s while the route loaded")
        guard let final = readProbe(app) ?? last else {
            XCTFail("rideSummaryProbe never appeared")
            return
        }
        print("B11SMOKE final probe: \(final.raw)")
        print("B11SMOKE loading samples=\(loadingSamples) totals=\(Set(loadingTotals.map { Int($0.rounded()) }).sorted()) routePastRangeWhileLoading=\(loadingRoutePastRange.sorted()) maxSwipe=\(String(format: "%.2f", maxSwipe))s")
        XCTAssertFalse(final.loading, "Route never finished loading: \(final.raw)")

        // Check 2: ~1,622 mi while loading and final; days sum within 1 mi.
        // MapKit picks 1,404 / 1,476 / 1,622 mi variants for this ride.
        XCTAssert((1_350...1_700).contains(final.total), "Final total outside 1,350–1,700 mi: \(final.raw)")
        for total in loadingTotals {
            XCTAssertEqual(total, final.total, accuracy: 1, "Loading total \(total) != final \(final.total)")
        }
        XCTAssertEqual(final.days.count, 3, "Expected three riding days: \(final.raw)")
        let daySum = final.days.reduce(0) { $0 + $1.miles }
        XCTAssertEqual(daySum, final.total, accuracy: 1, "Day legs \(final.days) sum \(daySum) vs \(final.total)")

        // Check 3: hotels at every overnight, no "no lodging".
        for (day, _) in final.days.dropLast() {
            XCTAssertGreaterThan(final.hotels[day] ?? 0, 0, "No hotels for evening \(day): \(final.raw)")
        }
        XCTAssertTrue(final.noLodging.isEmpty, "No-lodging evenings: \(final.noLodging)")
        XCTAssertFalse(
            app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No lodging'")).firstMatch.exists,
            "A no-lodging message is on screen"
        )

        // Check 4: Day 3 "Past your range" in the FINAL list matches the
        // finished fuel plan, and loading never shows a label the final plan
        // does not (the build 11 flash).
        let expected = final.daysWithHopPastTank()
        let lastDay = final.days.last?.day ?? 3
        XCTAssertEqual(
            final.routePastRange.contains(lastDay), expected.contains(lastDay),
            "Day \(lastDay) route label disagrees with the plan (hops past tank on days \(expected.sorted())): \(final.raw)"
        )
        XCTAssertEqual(
            final.gasPastRange.contains(lastDay), expected.contains(lastDay),
            "Day \(lastDay) gas list label disagrees with the plan: \(final.raw)"
        )
        XCTAssertTrue(
            loadingRoutePastRange.isSubset(of: final.routePastRange),
            "Loading showed Past your range on days \(loadingRoutePastRange.sorted()) the final plan does not: \(final.raw)"
        )
        let onScreen = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS 'Past your range'")).count
        print("B11SMOKE expectedPastRangeDays=\(expected.sorted()) pastRangeElementsInTree=\(onScreen)")

        // Screenshots: final gas list at Day 3, and the Day 2 hotels.
        // Day 1 gas section: on a route whose first pump is past the tank,
        // this is where a visible "Past your range" would be.
        // iPad opens with Suggested Gas collapsed, so the day headers are not
        // in the tree at all. Open it from its header first.
        let gasHeaderFound = scrollTo("gasListHeader", app, upFirst: true)
        if gasHeaderFound {
            let dayOne = app.descendants(matching: .any).matching(identifier: "gasDay.1").firstMatch
            if !dayOne.waitForExistence(timeout: 2) {
                app.descendants(matching: .any).matching(identifier: "gasListHeader").firstMatch.tap()
                print("B11SMOKE expanded gas list: gasDay.1 exists=\(dayOne.waitForExistence(timeout: 5))")
            }
        }
        if gasHeaderFound, scrollTo("gasDay.1", app) {
            let warn = app.descendants(matching: .any)
                .matching(NSPredicate(format: "label CONTAINS 'Past your range'")).firstMatch
            print("B11SMOKE day1GasWarningVisible=\(warn.exists && warn.isHittable)")
            snap("b_final_gas_day1", app)
            swipe(app, up: true)
            print("B11SMOKE day1GasWarningVisibleAfterSwipe=\(warn.exists && warn.isHittable)")
            snap("b_final_gas_day1_more", app)
        } else {
            print("B11SMOKE skipped (section not present): gasDay.1")
        }
        if gasHeaderFound, scrollTo("gasDay.\(lastDay)", app) {
            snap("b_final_gas_day\(lastDay)", app)
            swipe(app, up: true)
            snap("b_final_gas_day\(lastDay)_more", app)
            // The last Day 3 stop sits at the bottom of the gas list.
            let lastStop = app.descendants(matching: .any).matching(
                NSPredicate(format: "label BEGINSWITH %@", "Fuel stop \(final.fuel.count):")
            ).firstMatch
            let listFrame = list(app).frame
            var swipes = 0
            while swipes < 40 && !(lastStop.exists && lastStop.frame.maxY <= listFrame.maxY
                                   && lastStop.frame.minY >= listFrame.minY) {
                swipe(app, up: true); swipes += 1
            }
            if lastStop.exists {
                if lastStop.frame.minY > listFrame.midY { swipe(app, up: true) }
                print("B11SMOKE lastStop=\(lastStop.label)")
                snap("b_final_gas_day\(lastDay)_last", app)
            } else {
                print("B11SMOKE skipped (section not present): Fuel stop \(final.fuel.count) (last Day \(lastDay) stop) not found")
            }
        } else {
            print("B11SMOKE skipped (section not present): gasDay.\(lastDay) not found in the final gas list")
        }
        if scrollTo("hotelDay.2", app) {
            snap("b_final_hotel_day2", app)
        } else {
            print("B11SMOKE skipped (section not present): hotelDay.2 not found")
        }
    }

    // MARK: - Helpers

    private func readProbe(_ app: XCUIApplication) -> Probe? {
        let element = app.descendants(matching: .any).matching(identifier: "rideSummaryProbe").firstMatch
        guard element.exists else { return nil }
        return Probe(element.label)
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

    private func swipe(_ app: XCUIApplication, up: Bool, fraction: CGFloat = 0.5) {
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

    private func scrollTo(_ identifier: String, _ app: XCUIApplication, upFirst: Bool = false) -> Bool {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let frame = list(app).frame
        func visible() -> Bool {
            // iPad's split sheet can clip a header by a point or two, so
            // a header whose top is inside the list counts.
            element.exists && element.frame.height > 0
                && element.frame.minY >= frame.minY - 2 && element.frame.minY < frame.maxY - 40
        }
        // Down first, then back up: the lazy list may have passed the row.
        // Day 1 sits near the top: on a long list, searching downward first
        // walks past ~300 rows before turning back.
        // iPad's floating sheet is short and each fuel stop carries food
        // rows, so slow 40% swipes never get back to Day 1. Fling first.
        if upFirst {
            for flick in 0..<40 {
                if visible() { return true }
                list(app).swipeDown(velocity: .fast)
                if flick % 4 == 3, element.exists { break }
            }
        }
        // swipe(up: true) moves down the list. After the upFirst flings the
        // list is at (or near) the top, so search downward first in both modes;
        // searching "up" first there only bounced off the top.
        // The iPad sheet list runs to ~400 pages (each fuel stop carries
        // food rows), so slow swipes never reach the gas header. Fling down
        // until the element is in the tree, then fine-tune below.
        if !element.exists {
            for _ in 0..<200 {
                list(app).swipeUp(velocity: .fast)
                if element.exists { break }
            }
        }
        for direction in [true, false] {
            for _ in 0..<60 {
                if visible() {
                    // Bring it near the top third of the list.
                    if element.frame.minY > frame.minY + frame.height * 0.4 {
                        swipe(app, up: true, fraction: 0.3)
                        if visible() { return true }
                        continue
                    }
                    return true
                }
                if element.exists {
                    print("B11SMOKE scrollTo \(identifier) exists frame=\(element.frame) list=\(frame)")
                }
                swipe(app, up: direction, fraction: 0.4)
            }
        }
        print("B11SMOKE scrollTo \(identifier) gave up exists=\(element.exists) list=\(frame) lists=\(app.collectionViews.count)")
        let ids = list(app).descendants(matching: .any).allElementsBoundByIndex.prefix(80)
            .map { "\($0.identifier)|\($0.label.prefix(40))" }
        print("B11SMOKE gave-up tree: \(ids.joined(separator: " ; "))")
        snap("giveup_\(identifier)", app)
        return visible()
    }

    private func expandSheet(_ app: XCUIApplication) {
        let grabber = app.buttons["Sheet Grabber"]
        guard grabber.exists else { return }
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08))
        grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.05, thenDragTo: top)
    }

    private func snap(_ name: String, _ app: XCUIApplication) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let dir = shotsDir {
            try? shot.pngRepresentation.write(to: dir.appendingPathComponent("\(name).png"))
        }
    }
}
