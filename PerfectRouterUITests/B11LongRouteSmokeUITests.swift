import UIKit
import XCTest

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
        XCTAssertEqual(final.total, 1_622, accuracy: 60, "Final total: \(final.raw)")
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
        if scrollTo("gasDay.\(lastDay)", app) {
            snap("b_final_gas_day\(lastDay)", app)
            swipe(app, up: true)
            snap("b_final_gas_day\(lastDay)_more", app)
        } else {
            XCTFail("gasDay.\(lastDay) not found in the final gas list")
        }
        if scrollTo("hotelDay.2", app) {
            snap("b_final_hotel_day2", app)
        } else {
            XCTFail("hotelDay.2 not found")
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

    private func scrollTo(_ identifier: String, _ app: XCUIApplication) -> Bool {
        let element = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        let frame = list(app).frame
        func visible() -> Bool {
            element.exists && element.frame.minY >= frame.minY && element.frame.maxY <= frame.maxY
                && element.frame.height > 0
        }
        // Down first, then back up: the lazy list may have passed the row.
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
                swipe(app, up: direction, fraction: 0.4)
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
