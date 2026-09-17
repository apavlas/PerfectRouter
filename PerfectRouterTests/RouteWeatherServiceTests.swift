import XCTest
@testable import PerfectRouter

final class RouteWeatherServiceTests: XCTestCase {

    /// Debug (the configuration Xcode uses for Run) must not require WeatherKit.
    func testWeatherKitDisabledInDebug() {
#if DEBUG
        XCTAssertFalse(RouteWeatherService.isEnabled)
#else
        XCTAssertTrue(RouteWeatherService.isEnabled)
#endif
    }

    func testRainForecastIsNilWhenWeatherKitDisabled() async {
        guard !RouteWeatherService.isEnabled else { return }
        let forecast = await RouteWeatherService().rainForecast(alongLegs: [], departure: Date())
        XCTAssertNil(forecast)
    }
}
