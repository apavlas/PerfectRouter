import XCTest
@testable import PerfectRouter

/// WeatherKit terms: weather data always carries Apple Weather attribution.
final class WeatherAttributionTests: XCTestCase {

    /// With no live attribution, the Legal link opens Apple's published page.
    func testFallbackLegalURLIsApplesAttributionPage() {
        let url = WeatherAttributionView.legalURL(from: nil)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "weatherkit.apple.com")
        XCTAssertEqual(url.path, "/legal-attribution.html")
    }

    /// Notifications can't show the mark, so the body names the source.
    func testRainNotificationBodyNamesAppleWeather() {
        let body = WeatherNotificationService.body(for: "Rain likely near mile 120.")
        XCTAssertTrue(body.hasPrefix("Rain likely near mile 120."))
        XCTAssertTrue(body.hasSuffix("Source: Apple Weather"))
    }
}
