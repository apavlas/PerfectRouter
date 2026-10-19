import CoreGraphics
import Foundation

/// Edge padding, in points, that keeps a fitted route in the part of the map
/// the rider can actually see.
///
/// `bottom` is how far the planning sheet covers the map from the bottom
/// edge. On a phone that is the sheet height. On an iPad portrait card that
/// sits on the bottom edge, it is the card's height too. `top` clears the
/// category chips. Leading and trailing grow when a tall panel covers that
/// side; a floating card that only covers the bottom leaves the side gaps
/// open so the route can sit above the card at the full map width.
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
                let spansWidth = overlap.width >= map.width * 0.65
                let spansHeight = overlap.height >= map.height * 0.65
                // A tall panel on one side (not the bottom card) leaves the
                // route beside it. A bottom sheet, including a floating
                // iPad card that does not reach the side edges, keeps the
                // route in the band above the card.
                if spansHeight && !spansWidth {
                    let attachedLeading = overlap.minX <= measurement.safeLeft + 8
                    let attachedTrailing = overlap.maxX >= map.width - measurement.safeRight - 8
                    if attachedLeading && !attachedTrailing {
                        left = max(left, overlap.maxX)
                    } else if attachedTrailing && !attachedLeading {
                        right = max(right, map.width - overlap.minX)
                    } else {
                        bottom = max(bottom, map.height - overlap.minY)
                    }
                } else {
                    let coveredFromBottom = map.height - overlap.minY
                    let flushWithBottom = overlap.maxY >= map.height - 12
                    // A card that starts above the map (the chips already
                    // shortened it) is still as tall as its own frame. Report
                    // that height so the inset matches the presented sheet.
                    if flushWithBottom {
                        bottom = max(bottom, max(coveredFromBottom, sheet.height))
                    } else {
                        bottom = max(bottom, coveredFromBottom)
                    }
                }
            }
        }

        return MapFitPadding(
            top: min(max(0, top), map.height),
            left: min(max(0, left + margin), map.width),
            bottom: max(0, bottom),
            right: min(max(0, right + margin), map.width)
        )
    }

    /// How far the chip bar covers the map from the top. A bar that sits
    /// entirely above the map (the list column already gave the map that
    /// space) contributes only the safe area.
    private static func topObstruction(
        _ controls: CGRect,
        safeTop: CGFloat,
        mapHeight: CGFloat
    ) -> CGFloat {
        let safe = max(0, safeTop)
        guard controls.width > 1, controls.height > 1 else { return safe }
        guard controls.maxY > 1, controls.minY < mapHeight else { return safe }
        return max(safe, controls.maxY)
    }
}
