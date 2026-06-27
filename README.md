# MotoRoute — iOS Starter Code

A SwiftUI + MapKit starter for a motorcycle ride-planning app with multi-stop routing and recommended stops (gas, food, coffee, scenic) along the route corridor.

## Requirements
- Xcode 15 or later
- iOS 17.0+ deployment target (uses the new SwiftUI `Map` APIs: `Marker`, `MapPolyline`, `Annotation`)

## Setup
1. In Xcode: **File → New → Project → iOS → App**. Name it `MotoRoute`, interface **SwiftUI**, language **Swift**.
2. Delete the generated `ContentView.swift` and drag these four files into the project:
   - `MotoRouteApp.swift` (replace the generated one)
   - `ContentView.swift`
   - `RoutePlannerViewModel.swift`
   - `StopSuggestionService.swift`
   - `Models.swift`
3. Add location permission: in the target's **Info** tab, add:
   - `Privacy - Location When In Use Usage Description` →
     "MotoRoute uses your location to show your position and plan rides from where you are."
4. Build and run on a simulator or device. In the simulator, set a location via **Features → Location**.

## How it works
- **Multi-stop routing**: `RoutePlannerViewModel.recalculateRoute()` runs one `MKDirections` request per consecutive waypoint pair and stores each leg's `MKRoute`.
- **Stop recommendations**: `StopSuggestionService` walks the route polylines, samples a point every ~25 miles, runs an `MKLocalSearch` for the selected category around each point, keeps results within ~5 miles of the route, and de-duplicates.
- **Fuel awareness**: `fuelRangeMeters` (default ~120 mi) drives a banner that recommends the last gas station reachable within one tank, or warns when none was found.

## Tuning knobs
- `StopSuggestionService.sampleIntervalMeters` — search density along the route
- `StopSuggestionService.corridorRadiusMeters` — how far off-route a stop may be
- `RoutePlannerViewModel.fuelRangeMeters` — rider's tank range (expose this in a settings screen later)

## Known limitations / next steps
- `MKLocalSearch` is rate-limited; for long rides increase the sample interval or batch by region.
- Fuel-range logic only considers distance from the ride start, not remaining fuel after a stop is added — track "distance since last gas stop" for v2.
- Apple routing won't prefer twisty roads. For "scenic/curvy route" options, integrate HERE or Mapbox Directions.
- Persist rides with SwiftData and add CloudKit sync for sharing routes with riding groups.
