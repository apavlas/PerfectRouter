import SwiftUI
import UIKit
import XCTest
@testable import PerfectRouter

final class PlanningChromeTests: XCTestCase {

    func testIPhonePortraitStaysSheet() {
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 393, height: 852),
                horizontalSizeClass: .compact,
                idiom: .phone,
                runsOnMac: false
            ),
            .sheet
        )
    }

    func testIPhoneLandscapePlusStaysSheet() {
        // Plus and Max phones are regular width in landscape. They still
        // keep the bottom sheet.
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 932, height: 430),
                horizontalSizeClass: .regular,
                idiom: .phone,
                runsOnMac: false
            ),
            .sheet
        )
    }

    func testIPadPortraitStaysSheet() {
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 834, height: 1194),
                horizontalSizeClass: .regular,
                idiom: .pad,
                runsOnMac: false
            ),
            .sheet
        )
    }

    func testIPadLandscapeUsesSidebar() {
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 1194, height: 834),
                horizontalSizeClass: .regular,
                idiom: .pad,
                runsOnMac: false
            ),
            .sidebar
        )
    }

    func testIPadSquareStaysSheet() {
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 800, height: 800),
                horizontalSizeClass: .regular,
                idiom: .pad,
                runsOnMac: false
            ),
            .sheet
        )
    }

    func testIPadCompactSplitStaysSheet() {
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 320, height: 800),
                horizontalSizeClass: .compact,
                idiom: .pad,
                runsOnMac: false
            ),
            .sheet
        )
    }

    func testMacUsesSidebarEvenWhenTheWindowIsTall() {
        XCTAssertEqual(
            PlanningChrome.resolve(
                container: CGSize(width: 500, height: 900),
                horizontalSizeClass: .compact,
                idiom: .pad,
                runsOnMac: true
            ),
            .sidebar
        )
    }
}
