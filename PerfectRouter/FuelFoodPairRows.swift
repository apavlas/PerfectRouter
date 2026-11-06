import CoreLocation
import Foundation

/// Pure nesting rules for food under a fuel stop (FP-1 / FP-2).
enum FuelFoodPairRows {
    enum Row {
        case food(SuggestedStop)
        case noneNearby
    }

    /// Rows to nest under one fuel stop. `pair` is nil while the async
    /// search has not finished for that stop; that yields no rows so the
    /// list does not flash "No food nearby" mid-search.
    static func rows(for pair: FuelFoodStop?) -> [Row] {
        guard let pair else { return [] }
        if pair.nearbyFood.isEmpty {
            return [.noneNearby]
        }
        return pair.nearbyFood.map { .food($0) }
    }

    /// Caption for a food row: how far the place sits from the pump's
    /// planned line. Under ~100 m reads as at the pump.
    static func foodCaption(detourMeters: CLLocationDistance) -> String {
        if detourMeters < 100 {
            return "at the pump"
        }
        return "\(formattedRideDistance(detourMeters)) off route"
    }
}
