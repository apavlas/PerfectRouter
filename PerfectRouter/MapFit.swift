import CoreGraphics
import Foundation

/// Edge padding, in points, that keeps a fitted route in the part of the map
/// the rider can actually see.
///
/// `bottom` is the distance from the map's bottom edge up to the sheet's
/// visible top (the grabber), plus a small margin. It is not the sheet
/// view's bounds height: a medium detent lays that view out taller than the
/// card and the extra hangs below the screen. `top` clears the category
/// chips when they overlap the map. A floating card with almost no map above
/// it and a wide gap beside it pads that side instead.
struct MapFitPadding: Equatable {
    var top: CGFloat
    var left: CGFloat
    var bottom: CGFloat
    var right: CGFloat

    static let zero = MapFitPadding(top: 0, left: 0, bottom: 0, right: 0)

    /// "top,left,bottom,right" in whole points.
    var accessibilityLabel: String {
        "\(Self.point(top)),\(Self.point(left)),\(Self.point(bottom)),\(Self.point(right))"
    }

    private static func point(_ value: CGFloat) -> Int {
        Int(value.rounded())
    }
}

/// What was on screen the moment a route was fitted.
struct MapFitMeasurement: Equatable {
    var mapSize: CGSize
    var safeTop: CGFloat = 0
    var safeLeft: CGFloat = 0
    var safeBottom: CGFloat = 0
    var safeRight: CGFloat = 0
    /// Chip bar in the map's coordinate space. Zero when it has not been
    /// laid out.
    var topControls: CGRect = .zero
    /// Planning sheet in the map's coordinate space. Zero, or a rect that
    /// does not meet the map, when the list is a sidebar.
    var sheet: CGRect = .zero
    var margin: CGFloat = MapFitInsets.margin
}

/// Turns a measured sheet frame into the padding passed to the camera fit.
enum MapFitInsets {
    /// Gap between the fitted route and the chip bar, sheet, or screen edge.
    static let margin: CGFloat = 16

    /// Extra padding around the coordinates so a marker glyph stays inside
    /// the band. The anchor is the coordinate; the pin hangs below it.
    static let pinClearance: CGFloat = 36

    /// Insets passed to the camera. The published chrome insets stay as
    /// measured; this only keeps the glyph off the chips and the sheet.
    static func cameraInsets(around chrome: MapFitPadding) -> MapFitPadding {
        MapFitPadding(
            top: chrome.top + pinClearance,
            left: chrome.left,
            bottom: chrome.bottom + pinClearance,
            right: chrome.right
        )
    }

    /// `frame` expressed in the map view's coordinates. Zero when either
    /// rect has not been laid out.
    static func mapLocalFrame(_ frame: CGRect, mapFrame: CGRect) -> CGRect {
        guard mapFrame.width > 1, mapFrame.height > 1 else { return .zero }
        guard frame.width > 1, frame.height > 1 else { return .zero }
        return CGRect(
            x: frame.minX - mapFrame.minX,
            y: frame.minY - mapFrame.minY,
            width: frame.width,
            height: frame.height
        )
    }

    static func padding(for measurement: MapFitMeasurement) -> MapFitPadding {
        let map = measurement.mapSize
        guard map.width > 1, map.height > 1 else { return .zero }

        let margin = max(0, measurement.margin)
        let mapRect = CGRect(origin: .zero, size: map)
        let top = topObstruction(
            measurement.topControls,
            safeTop: measurement.safeTop,
            mapHeight: map.height
        ) + margin

        var bottom = max(0, measurement.safeBottom)
        var left = max(0, measurement.safeLeft)
        var right = max(0, measurement.safeRight)

        let sheet = measurement.sheet
        if sheet.width > 1, sheet.height > 1, sheet.intersects(mapRect) {
            let overlap = sheet.intersection(mapRect)
            if overlap.width > 8, overlap.height > 8 {
                apply(
                    sheet: overlap,
                    map: map,
                    top: top,
                    margin: margin,
                    safeLeft: measurement.safeLeft,
                    safeRight: measurement.safeRight,
                    bottom: &bottom,
                    left: &left,
                    right: &right
                )
            }
        }

        return fitting(
            MapFitPadding(
                top: min(max(0, top), map.height),
                left: min(max(0, left + margin), map.width),
                bottom: min(max(0, bottom), map.height),
                right: min(max(0, right + margin), map.width)
            ),
            in: map
        )
    }

    /// Shrinks the larger edge until the padding fits inside the map and
    /// leaves at least `minimumBand` points open. A measured sheet that
    /// still covers the whole screen must not publish a top and bottom
    /// that add up to more than the map.
    static func fitting(
        _ padding: MapFitPadding,
        in map: CGSize,
        minimumBand: CGFloat = 1
    ) -> MapFitPadding {
        guard map.width > 1, map.height > 1 else { return padding }
        var top = max(0, padding.top)
        var left = max(0, padding.left)
        var bottom = max(0, padding.bottom)
        var right = max(0, padding.right)
        let band = min(max(minimumBand, 1), min(map.height, map.width) - 1)
        shrink(first: &top, second: &bottom, limit: map.height - band)
        shrink(first: &left, second: &right, limit: map.width - band)
        return MapFitPadding(top: top, left: left, bottom: bottom, right: right)
    }

    /// The resting card leaves a band between the chip bar and its top.
    /// The large hosting view starts under the status bar, overlaps the
    /// chips, and does not.
    static func leavesABand(_ measurement: MapFitMeasurement, minimum: CGFloat = 72) -> Bool {
        let map = measurement.mapSize
        guard map.width > 1, map.height > 1 else { return false }
        guard measurement.topControls.width > 1, measurement.topControls.height > 1 else { return false }
        let sheet = measurement.sheet
        let mapRect = CGRect(origin: .zero, size: map)
        guard sheet.width > 1, sheet.height > 1, sheet.intersects(mapRect) else { return false }
        let padding = padding(for: measurement)
        let band = map.height - padding.top - padding.bottom
        guard band >= minimum else { return false }
        return sheet.minY >= measurement.topControls.maxY - 4
    }

    private static func shrink(first: inout CGFloat, second: inout CGFloat, limit: CGFloat) {
        let overflow = first + second - limit
        guard overflow > 0 else { return }
        if second >= first {
            let taken = min(second, overflow)
            second -= taken
            first = max(0, first - (overflow - taken))
        } else {
            let taken = min(first, overflow)
            first -= taken
            second = max(0, second - (overflow - taken))
        }
    }

    /// Pads from the sheet's visible top, never from the view's raw height.
    /// `sheet` is already clipped to the map, so a rect that hangs below the
    /// screen contributes only the on-screen part.
    private static func apply(
        sheet: CGRect,
        map: CGSize,
        top: CGFloat,
        margin: CGFloat,
        safeLeft: CGFloat,
        safeRight: CGFloat,
        bottom: inout CGFloat,
        left: inout CGFloat,
        right: inout CGFloat
    ) {
        let spansWidth = sheet.width >= map.width * 0.65
        let spansHeight = sheet.height >= map.height * 0.65
        let attachedBottom = sheet.maxY >= map.height - 12
        let attachedLeading = sheet.minX <= safeLeft + 8
        let attachedTrailing = sheet.maxX >= map.width - safeRight - 8
        let aboveHeight = sheet.minY - top
        let leadingGap = sheet.minX
        let trailingGap = map.width - sheet.maxX

        // A tall panel glued to one side (sidebar-sized) leaves the route
        // on the open side. A bottom sheet, and a floating card with a
        // usable band above it, keep the route above the card's top edge.
        if spansHeight && !spansWidth && attachedLeading != attachedTrailing {
            if attachedLeading {
                left = max(left, sheet.maxX)
            } else {
                right = max(right, map.width - sheet.minX)
            }
            return
        }

        // The card covers the middle and the strip above it is a sliver.
        // The open map is the column beside the card.
        if !attachedBottom && aboveHeight < 100 && max(leadingGap, trailingGap) >= 160 {
            if leadingGap >= trailingGap {
                right = max(right, map.width - sheet.minX)
            } else {
                left = max(left, sheet.maxX)
            }
            return
        }

        let covered = map.height - sheet.minY + margin
        bottom = max(bottom, min(map.height, covered))
    }

    /// How far the chip bar covers the map from the top. A bar that sits
    /// entirely above the map (the list column already gave the map that
    /// space) contributes only the safe area. A background laid out at the
    /// map's height is not the chip row either: counting it makes the top
    /// inset swallow the band above a floating card.
    private static func topObstruction(
        _ controls: CGRect,
        safeTop: CGFloat,
        mapHeight: CGFloat
    ) -> CGFloat {
        let safe = max(0, safeTop)
        guard controls.width > 1, controls.height > 1 else { return safe }
        guard controls.maxY > 1, controls.minY < mapHeight else { return safe }
        if controls.height > 180 { return safe }
        return max(safe, controls.maxY)
    }

    /// Minimum open band when the sheet is still the large detent and the
    /// real gap above it is a sliver. A medium sheet or a floating card
    /// returns nil: those keep the route above the grabber, and shrinking
    /// the bottom inset would slide the ride down behind the card.
    static func largeDetentFallbackBand(for measurement: MapFitMeasurement) -> CGFloat? {
        let map = measurement.mapSize
        guard map.height > 1, map.width > 1 else { return nil }
        guard !leavesABand(measurement) else { return nil }
        let sheet = measurement.sheet
        if sheet.height > 1, sheet.minY > map.height * 0.15 {
            return nil
        }
        return map.height * 0.35
    }
}
