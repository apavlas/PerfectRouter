# PerfectRouter

Ride planning for motorcyclists: building a multi-stop ride, choosing how it should feel to ride, and making sure the rider never runs out of fuel along the way.

## Rides and routes

**Ride**:
The rider's plan for a trip: its waypoints, route style, tank range, and departure time. Rides are what get saved, shared, and navigated.
_Avoid_: Trip, journey

**Route**:
The road geometry, distance, and ETA calculated for a ride. A ride owns exactly one current route.
_Avoid_: Path, directions

**Route style**:
How the route should feel to ride: Fastest, Avoid Highways, Scenic, or Twisty.
_Avoid_: Routing style, route type, mode

**Waypoint**:
An ordered place the rider put on the ride, including the start and the destination. Riders see the intermediate ones as "stops".
_Avoid_: Stop (unqualified), point, location

**Leg**:
The part of a route between two consecutive waypoints.
_Avoid_: Segment, stage

**Partial route**:
A route where at least one leg failed to calculate, so its distance and ETA are incomplete. Never presented as a complete route.
_Avoid_: Incomplete route, broken route

## Time and nights

All clock times are local time at that point on the route, not the phone's time zone.

**Riding time**:
Time spent moving along the route. Excludes time stopped. Captions that say "riding" show riding time.
_Avoid_: Drive time, travel time, duration

**Stop allowance**:
Time added for each stop on the plan when predicting a clock time (arrival, Evening, meal ETAs): 15 min per fuel stop, 45 min per Meal stop (instead of 15), 15 min per other intermediate waypoint. Checked stops add nothing. Clock predictions are riding time plus stop allowances.
_Avoid_: Break time, dwell time, padding

**Hotel time**:
The clock time the rider wants to stop for the night. Set per ride; defaults to 6:00 PM.
_Avoid_: Target clock, target time, evening target

**Hotel window**:
Hotel time plus or minus one hour: when a hotel must be reached to be offered for an Evening.
_Avoid_: Lodging window, time window

**Evening**:
A planned night on the ride: the point where the predicted clock reaches hotel time. Exists whether or not a hotel has been picked; riders see "No hotel picked" until one is. There is no Evening when the destination is reached before the hotel window closes.
_Avoid_: 6 PM point, hotel evening, night

**Overnight**:
A hotel the rider applied as a waypoint. It always ends the riding day it is reached on and becomes that day's Evening, wherever it falls; riders see a note when it is reached outside the hotel window. It is a Fill only when a gas station sits within 5 miles along the route on either side of it; otherwise fuel carries over from the previous Fill and riders see "No gas near this hotel".
_Avoid_: Hotel stop, night stop

**Riding day**:
The part of a ride from the start or an Evening to the next Evening or the destination. Evenings divide days, whether or not they have an Overnight.
_Avoid_: Day (unqualified), segment, stage

**Morning start**:
When every riding day after the first begins: 8:00 AM. The first riding day begins at the ride's departure time.
_Avoid_: Morning departure, restart time

**Meal window**:
A clock range for a meal: breakfast 7:00–9:30, lunch 11:30–1:30, dinner 5:30–8:00.
_Avoid_: Mealtime, meal slot

**Meal stop**:
A fuel stop whose predicted clock falls in a meal window and that has food close by. Preferred over a fuel stop without food when both fit the tank; never pushes a fuel stop past the comfort range. No breakfast Meal stop on a riding day that starts at or after 7:00, and no dinner Meal stop on one that ends before 8:00 PM; the rider eats at the hotel. A food waypoint the rider applied inside a meal window counts as that meal: it gets the Meal stop allowance, and no Meal stop is sought for that meal on that riding day.
_Avoid_: Fuel-food stop, lunch stop, food stop (for this meaning)

## Fuel

**Gas station**:
Any place that sells fuel, whether or not the ride uses it.
_Avoid_: Pump, fuel station

**Fuel stop**:
A gas station in its role on a ride: chosen by the planner or added by the rider as a place to fill the tank.
_Avoid_: Gas stop, refuel stop

**Fill**:
A point on the ride where the tank counts as full: the ride start, an applied fuel stop, or an Overnight with a gas station close by. The ride start is always a Fill; riders are expected to leave with a full tank. Each tank is measured from the previous Fill.
_Avoid_: Refuel, tank fill, gas fill

**Tank range**:
How far the rider says the bike goes on a full tank. Set per ride, defaulting from settings.
_Avoid_: Fuel range, full range, range (unqualified)

**Hop**:
The distance ridden from one Fill to the next, or to a candidate fuel stop.
_Avoid_: Tank interval, stint, tank (as a distance)

**Reserve**:
The part of tank range the comfort range leaves unused (the last 15%). On a 200 mi tank, the last 30 mi.
_Avoid_: Buffer, margin

**Comfort range**:
The share of tank range (85%) within which the planner aims to place the next fuel stop, leaving a reserve.
_Avoid_: Safety range, safe range

**Past range**:
The status of a gas station whose hop is longer than tank range; never recommended. Riders see "Past your range".
_Avoid_: Past full tank, out of range

**Fuel gap**:
A stretch of the route longer than tank range with no gas station on it. A claim about the world: the search covered it and found nothing.
_Avoid_: Dry stretch, gas desert

**Unsearched stretch**:
Part of the route where the gas search did not finish (throttled or failed). Never reported as a fuel gap or as "no gas stations".
_Avoid_: Coverage gap, missing results

## Suggestions

**Suggested stop**:
Any place found along the route in a stop category (gas, food, coffee, scenic, sights, lodging).
_Avoid_: Search result, POI

**Detour**:
How far off the route a place sits, as riders see in "2 mi off route". Applies to gas stations, food, and hotels alike.
_Avoid_: Offset, off-route distance, distance from route

**Recommended**:
A fuel stop or hotel the planner picked for the ride: one fuel stop per tank, up to three hotels per Evening. Not yet on the ride.
_Avoid_: Suggested (for this meaning), auto-selected

**Checked**:
A recommended or suggested stop the rider has ticked but not yet applied.
_Avoid_: Buffered, selected, pending

**Applied**:
A stop the rider has put on the ride; it is now a waypoint.
_Avoid_: Added, committed
