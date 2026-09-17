# PerfectRouter

A SwiftUI + MapKit iOS app for planning motorcycle rides: multi-stop routing, fuel-range stops, corridor suggestions (gas, food, coffee, scenic), weather along the route, and save/share.

## Requirements

- Xcode 15 or later
- iOS 17.0+ deployment target

## Setup

1. Clone this repo and open **`PerfectRouter.xcodeproj`** at the repo root. Use the shared **PerfectRouter** scheme (included under `xcshareddata`).
2. Select an iOS Simulator or a signed-in development team for a device, then build and run. In the simulator, set a location via **Features → Location** if you want a GPS fix other than the built-in Augusta, GA default.

Do **not** create a new Xcode project or drag individual Swift files into a blank app — this repo already is the app target plus `PerfectRouterTests`.

## How it works

- **Multi-stop routing**: `RoutePlannerViewModel.recalculateRoute()` runs one `MKDirections` request per consecutive waypoint pair and stores each leg's `MKRoute`.
- **Stop recommendations**: `StopSuggestionService` samples the route corridor and runs `MKLocalSearch` for the selected category.
- **Fuel awareness**: rider-added gas fills (`Waypoint.isGasFill`) and suggested pumps feed `planFuelStops`. Fills persist through save, share, and import.
- **Navigate**: two-stop rides use `MKMapItem.openMaps`; three or more use Apple's unified `maps.apple.com/directions` URL (repeated `waypoint` parameters). Google Maps is used when installed.
- **Save & share**: rides serialize as `SharedRoute` (JSON + `perfectrouter://` link) and are stored locally via `SavedRouteStore`.

## Tests

The **PerfectRouter** scheme includes the `PerfectRouterTests` target. In Xcode: **Product → Test**, or:

```bash
xcodebuild -scheme PerfectRouter -destination 'platform=iOS Simulator,name=iPhone 16' test
```
