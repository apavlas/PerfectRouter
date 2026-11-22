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

**Riding day**:
The part of a ride from the start or an Overnight to the next Overnight or the destination.
_Avoid_: Day (unqualified), segment, stage

**Partial route**:
A route where at least one leg failed to calculate, so its distance and ETA are incomplete. Never presented as a complete route.
_Avoid_: Incomplete route, broken route

**Overnight**:
A waypoint at lodging that ends a riding day; the next riding day starts there. It is a Fill only when a gas station sits within 5 miles along the route on either side of it; otherwise fuel carries over from the previous Fill and riders see "No gas near this hotel".
_Avoid_: Hotel stop, night stop

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

**Recommended**:
A fuel stop (or Overnight) the planner picked for the ride, one per tank (or per evening). Not yet on the ride.
_Avoid_: Suggested (for this meaning), auto-selected

**Checked**:
A recommended or suggested stop the rider has ticked but not yet applied.
_Avoid_: Buffered, selected, pending

**Applied**:
A stop the rider has put on the ride; it is now a waypoint.
_Avoid_: Added, committed
