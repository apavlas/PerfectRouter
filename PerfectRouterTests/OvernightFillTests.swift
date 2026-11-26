import CoreLocation
import XCTest
@testable import PerfectRouter

/// #61: an Overnight is a Fill only when a gas station sits within 5 miles
/// along the route on either side of it (GLOSSARY.md: Overnight, Fill).
final class OvernightFillTests: XCTestCase {

    private var mile: CLLocationDistance { AppSettings.metersPerMile }

    private func pump(_ miles: Double, off: Double = 0.1) -> (distance: CLLocationDistance, detour: CLLocationDistance) {
        (distance: miles * mile, detour: off * mile)
    }

    private func hasGas(hotelAt miles: Double, _ pumps: [(distance: CLLocationDistance, detour: CLLocationDistance)]) -> Bool {
        RoutePlannerViewModel.overnightHasGas(overnightMeters: miles * mile, pumps: pumps)
    }

    func testPumpFourMilesAheadMakesTheOvernightAFill() {
        XCTAssertTrue(hasGas(hotelAt: 90, [pump(94)]))
    }

    func testPumpFourMilesBeforeTheHotelCountsToo() {
        XCTAssertTrue(hasGas(hotelAt: 90, [pump(86)]))
    }

    func testPumpSixMilesAlongTheRouteDoesNotCount() {
        XCTAssertFalse(hasGas(hotelAt: 90, [pump(96), pump(84)]))
    }

    func testPumpThreeMilesOffTheRouteDoesNotCount() {
        XCTAssertFalse(hasGas(hotelAt: 90, [pump(90, off: 3)]))
    }

    func testNoPumpsMeansNoFill() {
        XCTAssertFalse(hasGas(hotelAt: 90, []))
    }

    /// The issue's fixture: 100 mi tank, last Fill at the start, Overnight
    /// at mile 90, next gas 40 mi past the hotel. The hotel isn't a Fill, so
    /// the planner recommends a stop before it instead of resetting the tank.
    func testNoGasNearTheHotelCarriesFuelOverAndRecommendsAStopBeforeIt() {
        let pumps = [pump(60), pump(130), pump(200)]
        XCTAssertFalse(hasGas(hotelAt: 90, pumps))

        let stations = pumps.map { pump in
            SuggestedStop(
                name: "Gas @\(Int(pump.distance / mile))",
                coordinate: CLLocationCoordinate2D(latitude: 0, longitude: 0),
                category: .gas,
                distanceAlongRoute: pump.distance,
                detourMeters: pump.detour
            )
        }
        let (stops, _) = RoutePlannerViewModel.planFuelStops(
            from: stations,
            totalDistance: 220 * mile,
            range: 100 * mile,
            filledAt: []
        )
        XCTAssertEqual(stops.first.map { Int(($0.distanceAlongRoute / mile).rounded()) }, 60)
    }

    func testNoticeWording() {
        XCTAssertEqual(RoutePlannerViewModel.noGasNearHotelNotice, "No gas near this hotel")
    }
}
