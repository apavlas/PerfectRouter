import CoreGraphics
import CoreLocation
import XCTest
@testable import PerfectRouter

/// Sheet frames become the padding that keeps a fitted route above the sheet
/// and below the chip bar.
final class MapFitInsetsTests: XCTestCase {

    func testPaddingLabelIsTopLeftBottomRight() {
        let padding = MapFitPadding(top: 72.4, left: 16.2, bottom: 421.6, right: 15.5)
        XCTAssertEqual(padding.accessibilityLabel, "72,16,422,16")
    }

    func testPhoneMediumSheetInsetsMatchTheSheetHeight() {
        let sheetHeight: CGFloat = 422
        let map = CGSize(width: 390, height: 844)
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 47,
            safeLeft: 0,
            safeBottom: 34,
            safeRight: 0,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 56),
            sheet: CGRect(x: 0, y: map.height - sheetHeight, width: map.width, height: sheetHeight)
        ))

        // Visible coverage is the sheet height; the margin sits above the grabber.
        XCTAssertEqual(padding.bottom, sheetHeight + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.top, 72, accuracy: 0.5)
        XCTAssertEqual(padding.left, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.right, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.accessibilityLabel, "72,16,438,16")
    }

    /// The medium sheet's hosting view is laid out at the large height and
    /// hangs below the screen. The inset follows the grabber, not that height.
    func testPhoneSheetTallerThanTheScreenUsesTheGrabber() {
        let map = CGSize(width: 402, height: 874)
        let grabberY: CGFloat = 410
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 59,
            topControls: CGRect(x: 0, y: 62, width: map.width, height: 58),
            sheet: CGRect(x: 0, y: grabberY, width: map.width, height: 778)
        ))

        XCTAssertEqual(padding.bottom, map.height - grabberY + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.top, 136, accuracy: 0.5)
        XCTAssertEqual(padding.left, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.right, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertLessThan(padding.bottom, 500)
    }

    func testIPadFloatingCardInsetsKeepTheRouteAboveTheCard() {
        let cardHeight: CGFloat = 600
        let map = CGSize(width: 834, height: 1194)
        // Centered card, flush with the bottom, inset from both sides.
        let card = CGRect(x: 80, y: map.height - cardHeight, width: map.width - 160, height: cardHeight)
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 24,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 64),
            sheet: card
        ))

        XCTAssertEqual(padding.bottom, cardHeight + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.top, 80, accuracy: 0.5)
        // Side gaps stay open. The route uses the full width above the card.
        XCTAssertEqual(padding.left, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.right, MapFitInsets.margin, accuracy: 0.5)
    }

    func testSidebarBesideTheMapDoesNotPadTheBottom() {
        let map = CGSize(width: 800, height: 700)
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeBottom: 21,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 52),
            sheet: CGRect(x: -420, y: 0, width: 400, height: map.height)
        ))

        XCTAssertEqual(padding.bottom, 21, accuracy: 0.5)
        XCTAssertEqual(padding.top, 68, accuracy: 0.5)
        XCTAssertEqual(padding.left, MapFitInsets.margin, accuracy: 0.5)
    }

    func testTallLeadingPanelPadsThatSide() {
        let map = CGSize(width: 834, height: 1194)
        let panelWidth: CGFloat = 320
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 60),
            sheet: CGRect(x: 0, y: 0, width: panelWidth, height: map.height)
        ))

        XCTAssertEqual(padding.left, panelWidth + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.bottom, 0, accuracy: 0.5)
        XCTAssertEqual(padding.right, MapFitInsets.margin, accuracy: 0.5)
    }

    func testChipsAboveTheMapDoNotDoubleCount() {
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: CGSize(width: 390, height: 700),
            safeTop: 0,
            topControls: CGRect(x: 0, y: -70, width: 390, height: 70),
            sheet: CGRect(x: 0, y: 350, width: 390, height: 350)
        ))
        XCTAssertEqual(padding.top, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.bottom, 350 + MapFitInsets.margin, accuracy: 0.5)
    }

    func testCenteredIPadCardFitsTheBandAboveTheCard() {
        let map = CGSize(width: 834, height: 1194)
        let card = CGRect(x: 117, y: 380, width: 600, height: 480)
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 24,
            topControls: CGRect(x: 0, y: 20, width: map.width, height: 60),
            sheet: card
        ))

        XCTAssertEqual(padding.bottom, map.height - card.minY + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.top, 96, accuracy: 0.5)
        XCTAssertEqual(padding.left, MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.right, MapFitInsets.margin, accuracy: 0.5)
    }

    func testFloatingCardWithNoRoomAboveUsesTheSideGap() {
        let map = CGSize(width: 834, height: 1194)
        let card = CGRect(x: 220, y: 80, width: 400, height: 900)
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 50),
            sheet: card
        ))

        XCTAssertEqual(padding.bottom, 0, accuracy: 0.5)
        XCTAssertEqual(padding.right, map.width - card.minX + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.left, MapFitInsets.margin, accuracy: 0.5)
    }

    func testEmptyMapProducesZeroPadding() {
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: .zero,
            sheet: CGRect(x: 0, y: 0, width: 200, height: 200)
        ))
        XCTAssertEqual(padding, .zero)
    }

    func testMapLocalFrameConvertsWindowCoordinates() {
        let map = CGRect(x: 100, y: 40, width: 800, height: 600)
        let sheet = CGRect(x: 180, y: 340, width: 640, height: 300)
        let local = MapFitInsets.mapLocalFrame(sheet, mapFrame: map)
        XCTAssertEqual(local, CGRect(x: 80, y: 300, width: 640, height: 300))
        XCTAssertEqual(MapFitInsets.mapLocalFrame(sheet, mapFrame: .zero), .zero)
    }

    func testStubRideFitsAboveAPhoneSheetAndBelowTheChips() {
        let map = CGSize(width: 390, height: 844)
        let coordinates = stubLine()
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 47,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 56),
            sheet: CGRect(x: 0, y: 422, width: map.width, height: 422)
        ))
        guard let frame = RouteMapFraming.region(
            containing: coordinates,
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }

        for coordinate in coordinates {
            XCTAssertTrue(
                frame.contains(coordinate, mapSize: map, insets: padding),
                "\(coordinate.latitude) was outside the visible band. center \(frame.centerLatitude) span \(frame.latitudeDelta)"
            )
        }
        XCTAssertGreaterThan(frame.centerLatitude, 30)
        XCTAssertLessThan(frame.centerLatitude, 42)
        XCTAssertLessThan(abs(frame.centerLatitude), 70)
    }

    func testStubRideFitsAboveAnIPadFloatingCard() {
        let map = CGSize(width: 834, height: 1194)
        let cardHeight: CGFloat = 600
        let coordinates = stubLine()
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 24,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: 64),
            sheet: CGRect(x: 80, y: map.height - cardHeight, width: map.width - 160, height: cardHeight)
        ))
        guard let frame = RouteMapFraming.region(
            containing: coordinates,
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }
        for coordinate in coordinates {
            XCTAssertTrue(frame.contains(coordinate, mapSize: map, insets: padding))
        }
        XCTAssertGreaterThan(frame.centerLatitude, 30)
        XCTAssertLessThan(frame.centerLatitude, 42)
    }

    func testAppliedStopBesideTheLineStaysInTheFit() {
        let map = CGSize(width: 390, height: 844)
        var coordinates = stubLine()
        let stop = CLLocationCoordinate2D(latitude: coordinates[0].latitude + 1, longitude: coordinates[0].longitude + 0.2)
        coordinates.append(stop)
        let padding = MapFitPadding(top: 72, left: 16, bottom: 422, right: 16)
        guard let frame = RouteMapFraming.region(
            containing: coordinates,
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }
        XCTAssertTrue(frame.contains(stop, mapSize: map, insets: padding))
    }

    func testShortRouteDoesNotZoomInAbsurdly() {
        let start = CLLocationCoordinate2D(latitude: 33.47, longitude: -82.01)
        let end = CLLocationCoordinate2D(latitude: 33.4701, longitude: -82.0101)
        let frame = RouteMapFraming.region(
            containing: [start, end],
            mapSize: CGSize(width: 390, height: 844),
            insets: MapFitPadding(top: 80, left: 16, bottom: 400, right: 16)
        )
        XCTAssertNotNil(frame)
        XCTAssertGreaterThanOrEqual(frame?.latitudeDelta ?? 0, RouteMapFraming.minimumSpan)
        XCTAssertGreaterThanOrEqual(frame?.longitudeDelta ?? 0, RouteMapFraming.minimumSpan)
        XCTAssertEqual(frame?.centerLatitude ?? 0, 33.47, accuracy: 1)
    }

    func testSheetThatCoversAlmostTheWholeMapDoesNotPanToTheArctic() {
        let coordinates = stubLine()
        let map = CGSize(width: 834, height: 1194)
        let padding = MapFitPadding(top: 40, left: 16, bottom: 1100, right: 16)
        guard let frame = RouteMapFraming.region(
            containing: coordinates,
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }
        XCTAssertLessThan(abs(frame.centerLatitude), 75)
        XCTAssertGreaterThan(frame.centerLatitude, -70)
        for coordinate in coordinates {
            XCTAssertTrue(
                frame.contains(coordinate, mapSize: map, insets: padding),
                "\(coordinate.latitude) left the sliver above the sheet"
            )
        }
    }

    /// A sheet that stays at the large detent never leaves a band. The
    /// fallback still frames the ride over its own coordinates.
    func testLargeDetentFallbackKeepsTheStubRideOnTheMap() {
        let map = CGSize(width: 402, height: 874)
        let raw = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            topControls: CGRect(x: 0, y: 59, width: map.width, height: 56),
            sheet: CGRect(x: 0, y: 62, width: map.width, height: 812)
        ))
        let padding = MapFitInsets.fitting(raw, in: map, minimumBand: map.height * 0.35)
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        guard let frame = RouteMapFraming.region(
            containing: stubLine(),
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }
        XCTAssertGreaterThan(frame.centerLatitude, 30)
        XCTAssertLessThan(frame.centerLatitude, 42)
        XCTAssertGreaterThan(frame.centerLongitude, -84)
        XCTAssertLessThan(frame.centerLongitude, -80)
    }

    func testPaddingFitsInsideTheScreen() {
        let map = CGSize(width: 402, height: 874)
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            topControls: CGRect(x: 0, y: 59, width: map.width, height: 56),
            sheet: CGRect(x: 0, y: 62, width: map.width, height: 812)
        ))
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        XCTAssertLessThan(padding.left + padding.right, map.width)
    }

    func testLargeHostDoesNotLeaveABandAndTheMediumCardDoes() {
        let map = CGSize(width: 402, height: 874)
        let chips = CGRect(x: 0, y: 59, width: map.width, height: 56)
        let large = MapFitMeasurement(
            mapSize: map,
            topControls: chips,
            sheet: CGRect(x: 0, y: 62, width: map.width, height: 812)
        )
        XCTAssertFalse(MapFitInsets.leavesABand(large))

        let medium = MapFitMeasurement(
            mapSize: map,
            topControls: chips,
            sheet: CGRect(x: 0, y: 410, width: map.width, height: 464)
        )
        XCTAssertTrue(MapFitInsets.leavesABand(medium))
        let padding = MapFitInsets.padding(for: medium)
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        XCTAssertEqual(padding.bottom, map.height - 410 + MapFitInsets.margin, accuracy: 0.5)
    }

    func testIPadHostFrameDoesNotLeaveABandAndTheFloatingCardDoes() {
        let map = CGSize(width: 834, height: 1210)
        let chips = CGRect(x: 0, y: 28, width: map.width, height: 58)
        let host = MapFitMeasurement(
            mapSize: map,
            topControls: chips,
            sheet: CGRect(x: 0, y: 105, width: map.width, height: 1105)
        )
        XCTAssertFalse(MapFitInsets.leavesABand(host))

        let cardTop: CGFloat = 270
        let card = MapFitMeasurement(
            mapSize: map,
            topControls: chips,
            sheet: CGRect(x: 0, y: cardTop, width: map.width, height: map.height - cardTop)
        )
        XCTAssertTrue(MapFitInsets.leavesABand(card))
        let padding = MapFitInsets.padding(for: card)
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        XCTAssertEqual(padding.bottom, map.height - cardTop + MapFitInsets.margin, accuracy: 0.5)
    }

    /// Augusta to Amarillo is a few degrees tall and about twenty wide.
    /// On a portrait phone MapKit used to widen the latitude until the ride
    /// sat on the sheet. The whole box has to land in the inset band.
    func testEastWestRideProjectsIntoThePhoneBand() {
        let map = CGSize(width: 402, height: 874)
        let augusta = CLLocationCoordinate2D(latitude: 33.4735, longitude: -81.9748)
        let amarillo = CLLocationCoordinate2D(latitude: 35.2220, longitude: -101.8313)
        let padding = MapFitPadding(top: 180, left: 16, bottom: 486, right: 16)
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        guard let frame = RouteMapFraming.region(
            containing: [augusta, amarillo],
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }
        let bandTop = padding.top
        let bandBottom = map.height - padding.bottom
        for coordinate in [augusta, amarillo] {
            XCTAssertTrue(frame.contains(coordinate, mapSize: map, insets: padding))
            guard let point = frame.viewPoint(for: coordinate, mapSize: map) else {
                XCTFail("Expected a projection")
                return
            }
            XCTAssertGreaterThanOrEqual(point.y, bandTop - 8)
            XCTAssertLessThanOrEqual(point.y, bandBottom + 8, "Pin at \(point.y) is on the sheet, band ends at \(bandBottom)")
        }
        XCTAssertLessThan(frame.centerLatitude, 33, "The camera stayed on the route instead of shifting into the band")
        XCTAssertGreaterThan(frame.centerLatitude, 10)
    }

    /// A background probe that fills the map is not the chip bar. Counting
    /// it shrinks the bottom inset and drops the ride behind the floating card.
    func testFullMapChipProbeDoesNotCoverTheBandAboveAFloatingCard() {
        let map = CGSize(width: 834, height: 1210)
        let cardTop: CGFloat = 270
        let measurement = MapFitMeasurement(
            mapSize: map,
            safeTop: 24,
            topControls: CGRect(x: 0, y: 0, width: map.width, height: map.height),
            sheet: CGRect(x: 0, y: cardTop, width: map.width, height: map.height - cardTop)
        )
        let padding = MapFitInsets.padding(for: measurement)
        XCTAssertEqual(padding.bottom, map.height - cardTop + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertEqual(padding.top, 24 + MapFitInsets.margin, accuracy: 0.5)
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        XCTAssertGreaterThan(map.height - padding.top - padding.bottom, 100)
        XCTAssertNil(MapFitInsets.largeDetentFallbackBand(for: measurement))
        let bandBottom = map.height - padding.bottom
        XCTAssertLessThanOrEqual(bandBottom, cardTop)
    }

    func testLargeDetentFallbackDoesNotApplyToAFloatingCard() {
        let map = CGSize(width: 834, height: 1210)
        let floating = MapFitMeasurement(
            mapSize: map,
            safeTop: 24,
            topControls: CGRect(x: 0, y: 24, width: map.width, height: 56),
            sheet: CGRect(x: 0, y: 270, width: map.width, height: map.height - 270)
        )
        XCTAssertNil(MapFitInsets.largeDetentFallbackBand(for: floating))

        let large = MapFitMeasurement(
            mapSize: CGSize(width: 402, height: 874),
            safeTop: 59,
            topControls: CGRect(x: 0, y: 59, width: 402, height: 56),
            sheet: CGRect(x: 0, y: 62, width: 402, height: 812)
        )
        XCTAssertEqual(
            MapFitInsets.largeDetentFallbackBand(for: large) ?? 0,
            874 * 0.35,
            accuracy: 0.5
        )
    }

    func testEastWestRideProjectsAboveACenteredIPadCard() {
        let map = CGSize(width: 834, height: 1210)
        let cardTop: CGFloat = 270
        let padding = MapFitInsets.padding(for: MapFitMeasurement(
            mapSize: map,
            safeTop: 24,
            topControls: CGRect(x: 0, y: 28, width: map.width, height: 58),
            sheet: CGRect(x: 80, y: cardTop, width: map.width - 160, height: 655)
        ))
        XCTAssertLessThan(padding.top + padding.bottom, map.height)
        XCTAssertEqual(padding.bottom, map.height - cardTop + MapFitInsets.margin, accuracy: 0.5)
        let augusta = CLLocationCoordinate2D(latitude: 33.4735, longitude: -81.9748)
        let amarillo = CLLocationCoordinate2D(latitude: 35.2220, longitude: -101.8313)
        guard let frame = RouteMapFraming.region(
            containing: [augusta, amarillo],
            mapSize: map,
            insets: padding
        ) else {
            XCTFail("Expected a frame")
            return
        }
        let bandBottom = map.height - padding.bottom
        for coordinate in [augusta, amarillo] {
            XCTAssertTrue(frame.contains(coordinate, mapSize: map, insets: padding))
            guard let point = frame.viewPoint(for: coordinate, mapSize: map) else {
                XCTFail("Expected a projection")
                return
            }
            XCTAssertGreaterThanOrEqual(point.y, padding.top - 8)
            XCTAssertLessThan(point.y, cardTop, "Pin at \(point.y) is behind the card that starts at \(cardTop)")
            XCTAssertLessThanOrEqual(point.y, bandBottom + 8)
        }
    }

    private func stubLine() -> [CLLocationCoordinate2D] {
        [
            UITestFixture.origin,
            UITestFixture.coordinate(milesNorth: UITestFixture.routeMiles, eastMeters: 0)
        ]
    }
}
