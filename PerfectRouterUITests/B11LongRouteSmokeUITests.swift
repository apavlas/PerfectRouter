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

        /// Riding day of the last gas-list leg. Legs start at the route start
        /// and at each recommended fill, and a leg is listed under the day it
        /// starts (GasListGrouping), so a short last day after the final
        /// fill has no `gasDay` header of its own.
        var lastGasListDay: Int {
            var cursor = 0.0
            var spans: [(day: Int, start: Double, end: Double)] = []
            for (day, miles) in days {
                spans.append((day, cursor, cursor + miles))
                cursor += miles
            }
            let lastStart = fuel.max() ?? 0
            return spans.first { lastStart >= $0.start - 0.5 && lastStart < $0.end - 0.5 }?.day
                ?? spans.last?.day ?? 1
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
        // Tank miles: FUEL-7 floor is 35% (100→35 mi, 170→~60 mi). Override
        // with TEST_RUNNER_SMOKE_TANK_MILES for the 100 mi default check.
        let tankMiles = ProcessInfo.processInfo.environment["SMOKE_TANK_MILES"] ?? "170"
        app.launchArguments = [
            "-UITestSkipOnboarding",
            "-RideSummaryProbe",
            "-RideDepartureOverride", "2026-10-23T08:00",
            "-RideTankMiles", tankMiles,
        ]
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
        PlaceSearchTyping.type("Denver", into: field, in: app)
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
        // ~700 mi/day: the 1,404 mi variant splits as 2 days or 2 + a ~10 mi third.
        XCTAssert((2...3).contains(final.days.count), "Expected two or three riding days: \(final.raw)")
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

        // FUEL-7 shot first: find "Fuel stop 1:" with a short scroll budget so
        // iPad does not burn minutes hunting gasDay chrome on a 400-page list.
        let firstStop = app.descendants(matching: .any).matching(
            NSPredicate(format: "label BEGINSWITH %@", "Fuel stop 1:")
        ).firstMatch
        if !firstStop.exists {
            for _ in 0..<30 {
                list(app).swipeDown(velocity: .fast)
                if firstStop.exists { break }
            }
        }
        if !firstStop.exists {
            for _ in 0..<40 {
                list(app).swipeUp(velocity: .fast)
                if firstStop.exists { break }
            }
        }
        if firstStop.exists {
            print("B11SMOKE firstStop=\(firstStop.label)")
            snap("b_final_gas_day1", app)
            swipe(app, up: true)
            snap("b_final_gas_day1_more", app)
        } else {
            print("B11SMOKE skipped early first-stop shot: Fuel stop 1 not found")
        }

        // Screenshots: final gas list at Day 3, and the Day 2 hotels.
        // Day 1 gas section: on a route whose first pump is past the tank,
        // this is where a visible "Past your range" would be.
        // iPad opens with Suggested Gas collapsed, so the day headers are not
        // in the tree at all. Open it from its header first.
        let gasHeaderFound = scrollTo("gasListHeader", app, upFirst: true)
        if gasHeaderFound {
            let dayOne = app.descendants(matching: .any).matching(identifier: "gasDay.1").firstMatch
            if !dayOne.waitForExistence(timeout: 2) {
                let header = app.descendants(matching: .any).matching(identifier: "gasListHeader").firstMatch
                if header.exists { header.tap() }
                // iPad sidebar can take a beat to publish day rows after expand.
                print("B11SMOKE expanded gas list: gasDay.1 exists=\(dayOne.waitForExistence(timeout: 8))")
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
        } else if gasHeaderFound {
            // Still capture the open gas list for FUEL-7 shots when day chrome
            // is slow on iPad — probe already recorded first-fill miles.
            print("B11SMOKE gasDay.1 missing after expand; snapping open gas list")
            snap("b_final_gas_day1", app)
            swipe(app, up: true)
            snap("b_final_gas_day1_more", app)
        } else {
            print("B11SMOKE skipped (section not present): gasDay.1")
        }
        // The last day header the gas list should have. A miss fails.
        let lastGasDay = final.lastGasListDay
        print("B11SMOKE lastGasListDay=\(lastGasDay) lastRidingDay=\(lastDay)")
        let lastGasDayFound = gasHeaderFound && scrollTo("gasDay.\(lastGasDay)", app)
        XCTAssertTrue(lastGasDayFound, "gasDay.\(lastGasDay) not reachable in the open gas list: \(final.raw)")
        if lastGasDayFound {
            snap("b_final_gas_day\(lastGasDay)", app)
            swipe(app, up: true)
            snap("b_final_gas_day\(lastGasDay)_more", app)
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
                snap("b_final_gas_day\(lastGasDay)_last", app)
            } else {
                print("B11SMOKE skipped (section not present): Fuel stop \(final.fuel.count) (last Day \(lastDay) stop) not found")
            }
        }
        // Every overnight has hotels (check 3), so its evening header must be
        // reachable: a miss here fails instead of skipping the screenshot.
        for (evening, _) in final.days.dropLast() {
            let found = scrollTo("hotelDay.\(evening)", app)
            XCTAssertTrue(found, "hotelDay.\(evening) not reachable though the probe lists hotels: \(final.raw)")
            if found { snap("b_final_hotel_day\(evening)", app) }
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

    private enum ScrollResult {
        case found
        /// The list scrolled to the id and no such row came into the tree.
        case notPresent
        /// The row is in the list but never settled inside it.
        case gaveUp
    }

    /// True when `identifier` is in view. `upFirst` is unused; the list
    /// jumps straight to the row.
    private func scrollTo(_ identifier: String, _ app: XCUIApplication, upFirst: Bool = false) -> Bool {
        switch scrollToRow(identifier, app) {
        case .found:
            return true
        case .notPresent:
            print("B11SMOKE scrollTo \(identifier): no such row in the list")
        case .gaveUp:
            XCTFail("\(identifier) is in the planning list but never came into view")
        }
        return false
    }

    /// Asks the app to scroll the row into view by its id (the planning
    /// list's ScrollViewReader, UI-test launch only), then nudges it inside
    /// the list frame. Swiping hunted for these headers through hundreds of
    /// lazy rows and missed `gasDay.3` and `hotelDay.2` on iPad and iPhone.
    /// A row the list never builds after the jump is not in the list.
    private func scrollToRow(_ identifier: String, _ app: XCUIApplication) -> ScrollResult {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        /// One snapshot: reading `frame` on a row the lazy list just dropped
        /// fails the test instead of returning nil.
        func rowFrame() -> CGRect? { (try? element.snapshot())?.frame }
        func visible(_ frame: CGRect) -> Bool {
            // iPad's split sheet can clip a header by a point or two, so
            // a header whose top is inside the list counts.
            guard let rowFrame = rowFrame() else { return false }
            return rowFrame.height > 0
                && rowFrame.minY >= frame.minY - 2 && rowFrame.minY < frame.maxY - 40
        }
        if visible(list(app).frame) { return .found }
        for attempt in 0..<2 {
            PlaceSearchTyping.postScrollRequest(identifier)
            if element.waitForExistence(timeout: attempt == 0 ? 3 : 5) { break }
        }
        guard element.exists else {
            snap("notpresent_\(identifier)", app)
            return .notPresent
        }
        for _ in 0..<12 {
            let frame = list(app).frame
            if visible(frame) { return .found }
            guard let rowFrame = rowFrame() else {
                PlaceSearchTyping.postScrollRequest(identifier)
                _ = element.waitForExistence(timeout: 2)
                continue
            }
            // Short drag toward the row, ending with a hold so the list
            // does not coast past it.
            let towardBottom = rowFrame.minY >= frame.maxY - 40
            let target = list(app)
            let start = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardBottom ? 0.65 : 0.35))
            let end = target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: towardBottom ? 0.35 : 0.65))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: 800, thenHoldForDuration: 0.15)
        }
        print("B11SMOKE scrollTo \(identifier) gave up frame=\(String(describing: rowFrame())) list=\(list(app).frame)")
        snap("giveup_\(identifier)", app)
        return visible(list(app).frame) ? .found : .gaveUp
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
