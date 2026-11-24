# PerfectRouter — Launch Plan

Agreed 2026-11-21. Target: **in the App Store by April 1, 2027.**

## Product

A road-trip planner for motorcyclists who ride in groups. It suggests gas stops based on tank range, food along the route, and lodging near where the rider will be at a chosen stop-riding time. It has to be easy to use. Riders share rides by link.

## Platforms

- **iOS first.** The current Swift, SwiftUI, and MapKit app is version 1.
- **CarPlay** works through handoff: the planned stops open in Apple Maps or Google Maps, which run on CarPlay. Market it as "works with CarPlay." Building our own turn-by-turn navigation is not in scope.
- **Android** starts only after iOS reaches 250 paying subscribers. Choose the technology then.

## Business model

| Free | Pro (each rider pays for their own) |
|---|---|
| Open and ride any shared plan | Create and share rides |
| Basic planning with gas stops | Lodging, Twisty routing, weather along the route |
| Navigate by handoff | GPX import and export, saved-ride history |

Pro is $4.99 a month or $29.99 a year, with a 7-day free trial. The paywall shows the annual plan as the default. Payments go through StoreKit subscriptions.

## Version 1 scope (frozen)

Version 1 is the current features plus:

- the must-fix items from `docs/Audit-2026-11-21.md`
- lodging finished (it's already mostly built on `main`)
- a StoreKit paywall
- a safety screen shown once on first launch: plan before you ride, fuel and lodging suggestions are estimates, don't handle the phone while riding

Anything else goes on a post-launch list, not into the build. That includes SwiftData and CloudKit, offline maps, live group location, and Android.

## Timeline

| When | What |
|---|---|
| Late Nov 2026 | Production-readiness audit (done, see the audit doc) |
| Dec 2026 – mid-Jan 2027 | Must-fix items, lodging polish, paywall, safety screen (order below) |
| Feb 2027 | Private TestFlight: Anton, Derek, and Chris, including one 2-day overnight ride |
| Mar 2027 | Public TestFlight on rider forums, then App Store submission |
| By Apr 1, 2027 | Live in the App Store |

Each phase ends at a gate (see below), not at a date. If a gate fails, the date moves and the gate stays.

Time budget: 15 hours a week, in three 5-hour blocks on the calendar. G0 (Perfect Process consulting) keeps first claim on your time and keeps its 2027-06-05 deadline. Hours freed by leaving Oddball go to G0, not to PerfectRouter.

## Scope freeze rule (added 2026-11-24)

- PRs already built and tested before 2026-11-24 get merged: #55, #68, #70, #71.
- #67 (time zone) and #69 (meal preference never fires) are bugs in shipped features, so they're in.
- Every other new issue is labeled `post-launch`. From 2026-11-24 on, only bugs enter version 1.

## Build order, Dec 2026 – mid-Jan 2027

1. Merge the audit must-fix PRs #72 (no silent data wipe), #73 (GPX cap), and #74 (directions backoff).
2. Fix the main-thread block on long routes (audit item 2).
3. Move the 13 unmerged commits from `cursor/twisty-routing-9470` onto a fresh branch from `main`, reconcile them with #74, and open one PR. Then retire the branch and switch the Desktop checkout to `main`.
4. Merge the built PRs and fix #67 and #69.
5. Allow saved rides in iCloud backups (audit item 7) and update the privacy policy to match.
6. First-launch safety screen.
7. StoreKit paywall and Pro gating, started no later than Jan 1. If time runs short, cut lodging polish before the paywall.

## Beta plan (added 2026-11-24)

**February, private.** Three testers, each on their own bike:

| Tester | TestFlight group | Tier |
|---|---|---|
| Anton | Internal | Pro |
| Derek | External | Pro |
| Chris | External | Free |

- Anton and Derek create and share rides. Chris opens and follows shared plans, using Chris's own tank range and fuel stops.
- Ride at least one 2-day trip of 500 km or more with an overnight, so lodging, the stop-riding time, overnight fuel, and day-2 handoff all get used.
- The real paywall runs in TestFlight, where sandbox purchases are free. Chris taps a Pro feature, sees the paywall, and backs out. Anton and Derek each start the 7-day trial. One lets it convert, and the other cancels and restores.
- The External group's public link stays on.

**March, public.** Create a separate "Public Beta" group with a public link capped at 100 testers, recruited from r/motorcycles, ADVrider, and one regional club or Facebook group. Use a short post-ride form for feedback: a route rating from 1 to 5, "what would you change?", and bugs.

**At launch,** every beta tester gets a free year of Pro through App Store offer codes.

### Gates

- **Private to public (end of Feb):** at least one end-to-end group ride (plan, share, ride, hand off), no open must-fix issues, and a 99% or better crash-free rate in TestFlight.
- **Public to App Store submission (mid-Mar):** at least 20 external testers, a sandbox purchase and a restore that both work, the App Store privacy label matching the app (audit item 8), and no must-fix issue open longer than 7 days.

## Business setup (start by mid-December)

1. Ask the accountant whether one LLC should cover both the consulting work and PerfectRouter.
2. Form Perfect Process LLC in South Carolina. It holds both the consulting work and PerfectRouter.
3. Get the EIN, then the D-U-N-S number from Dun & Bradstreet (free, takes 1–2 weeks).
4. Move the Apple developer membership to the organization. Ask Apple Developer Support to convert the existing account instead of opening a new one, so the bundle ID `com.apavlas.PerfectRouter` stays with the app.
5. Set up tax and banking. **The Paid Apps agreement is signed now (week of 2026-11-24) on the individual account,** not after the LLC, so StoreKit sandbox testing isn't blocked. When asking Apple to convert the account (step 4), confirm that the agreement carries over.
6. Host `docs/privacy.html` at a Perfect Process URL. Use Apple's standard terms of use.

## App Store listing

**PerfectRouter**, subtitled "Motorcycle Trip & Group Rides." Before submitting, check that nobody else already has the name.

## Process

- Code changes happen on branches with pull requests and tests. Anton reviews, merges, and tests each build on real rides. Derek and Chris test too.
- Beta feedback in February comes through TestFlight's built-in feedback plus one group chat for the three testers. In March it comes through TestFlight feedback plus the post-ride form. After each ride, the notes become GitHub issues sorted as must-fix, should-fix, or post-launch.
