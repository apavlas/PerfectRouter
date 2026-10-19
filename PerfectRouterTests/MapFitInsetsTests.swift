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
        let mid = (coordinates[0].latitude + coordinates[1].latitude) / 2
        let frame = RouteMapFraming.region(
            containing: coordinates,
            mapSize: CGSize(width: 834, height: 1194),
            insets: MapFitPadding(top: 40, left: 16, bottom: 1100, right: 16)
        )
        XCTAssertNotNil(frame)
        XCTAssertEqual(frame?.centerLatitude ?? 0, mid, accuracy: 5)
        XCTAssertLessThan(abs(frame?.centerLatitude ?? 90), 70)
        XCTAssertGreaterThan(frame?.centerLatitude ?? 0, 25)
        XCTAssertLessThan(frame?.centerLatitude ?? 0, 45)
    }

    private func stubLine() -> [CLLocationCoordinate2D] {
        [
            UITestFixture.origin,
            UITestFixture.coordinate(milesNorth: UITestFixture.routeMiles, eastMeters: 0)
        ]
    }
}
