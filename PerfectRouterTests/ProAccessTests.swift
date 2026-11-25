import StoreKit
import XCTest
@testable import PerfectRouter

/// Free/Pro rules (LaunchPlan "Business model"). The purchase path itself
/// is checked in the TestFlight sandbox (LaunchPlan beta plan).
@MainActor
final class ProAccessTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Entitlement rules

    func testCurrentSubscriptionIsPro() {
        let yearly = ProAccess.Entitlement(productID: ProAccess.yearlyProductID, expirationDate: now.addingTimeInterval(86_400))
        XCTAssertTrue(ProAccess.isActive([yearly], now: now))
    }

    func testExpiredRevokedOrUnknownProductIsNotPro() {
        let expired = ProAccess.Entitlement(productID: ProAccess.monthlyProductID, expirationDate: now.addingTimeInterval(-1))
        let refunded = ProAccess.Entitlement(
            productID: ProAccess.yearlyProductID,
            expirationDate: now.addingTimeInterval(86_400),
            revocationDate: now.addingTimeInterval(-60)
        )
        let other = ProAccess.Entitlement(productID: "com.example.other", expirationDate: nil)
        XCTAssertFalse(ProAccess.isActive([], now: now))
        XCTAssertFalse(ProAccess.isActive([expired, refunded, other], now: now))
    }

    func testPaywallListsYearlyFirst() {
        XCTAssertEqual(ProAccess.ordered(["m", "x", "y"].map(id), id: \.self), [ProAccess.yearlyProductID, ProAccess.monthlyProductID])
    }

    private func id(_ short: String) -> String {
        switch short {
        case "m": return ProAccess.monthlyProductID
        case "y": return ProAccess.yearlyProductID
        default: return "com.example.\(short)"
        }
    }

    func testUITestLaunchesRunAsProUnlessFreeTierIsAsked() {
        XCTAssertEqual(ProAccess.launchOverride(arguments: [ProAccess.freeTierArgument]), false)
    }

    // MARK: Gates

    func testTwistyIsProOnly() {
        XCTAssertEqual(RoutePlannerViewModel.allowedStyle(.twisty, proUnlocked: false), .fastest)
        XCTAssertEqual(RoutePlannerViewModel.allowedStyle(.twisty, proUnlocked: true), .twisty)
        XCTAssertEqual(RoutePlannerViewModel.allowedStyle(.scenic, proUnlocked: false), .scenic)
        XCTAssertEqual(RouteStyle.label(.twisty, proUnlocked: false), "Twisty (Pro)")
        XCTAssertEqual(RouteStyle.label(.twisty, proUnlocked: true), "Twisty")
    }

    /// Free can't switch to Twisty; the plan stays as it was.
    func testFreeRiderCannotSetTwisty() {
        let model = RoutePlannerViewModel()
        model.proUnlocked = false
        model.setRouteStyle(.avoidHighways)
        model.setRouteStyle(.twisty)
        XCTAssertEqual(model.routeStyle, .avoidHighways)
    }

    /// Losing Pro clears the Pro parts of the current plan.
    func testLosingProClearsWeatherAndHotels() {
        let model = RoutePlannerViewModel()
        model.rainForecast = RouteRainForecast(maxChance: 0.8, distanceOfMaxChance: 1_000)
        model.proUnlocked = false
        XCTAssertNil(model.rainForecast)
        XCTAssertNil(model.rainWarning)
        XCTAssertFalse(model.showsHotelSection)
        XCTAssertTrue(model.hotelEvenings.isEmpty)
    }

    // MARK: Paywall wording

    func testDisclosureNamesTrialPriceAndRenewal() {
        XCTAssertEqual(
            PaywallCopy.disclosure(price: "$29.99", period: "year", trialDays: 7),
            "Free for 7 days, then $29.99 a year. Renews automatically until you cancel in Settings at least 24 hours before the period ends."
        )
        XCTAssertTrue(PaywallCopy.disclosure(price: "$4.99", period: "month", trialDays: nil).hasPrefix("$4.99 a month."))
        XCTAssertEqual(PaywallCopy.days(value: 1, unit: .week), 7)
    }

    func testYearlyMonthlyEquivalentRoundsDown() {
        let text = PaywallCopy.monthlyEquivalent(yearly: Decimal(string: "29.99")!, format: .currency(code: "USD").locale(Locale(identifier: "en_US")))
        XCTAssertEqual(text, "$2.49")
    }
}
