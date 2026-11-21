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
| Dec 2026 – mid-Jan 2027 | Must-fix items, lodging polish, paywall, safety screen |
| Feb 2027 | Private TestFlight with 2–3 riding groups, including at least one real group ride |
| Mar 2027 | Public TestFlight on rider forums, then App Store submission |
| By Apr 1, 2027 | Live in the App Store |

Time budget: 15 hours a week, in three 5-hour blocks on the calendar. G0 (Perfect Process consulting) keeps first claim on your time.

## Business setup (start by mid-December)

1. Ask the accountant whether one LLC should cover both the consulting work and PerfectRouter.
2. Form Perfect Process LLC in South Carolina. It holds both the consulting work and PerfectRouter.
3. Get the EIN, then the D-U-N-S number from Dun & Bradstreet (free, takes 1–2 weeks).
4. Move the Apple developer membership to the organization. Ask Apple Developer Support to convert the existing account instead of opening a new one, so the bundle ID `com.apavlas.PerfectRouter` stays with the app.
5. Accept the Paid Apps agreement and set up tax and banking.
6. Host `docs/privacy.html` at a Perfect Process URL. Use Apple's standard terms of use.

## App Store listing

**PerfectRouter**, subtitled "Motorcycle Trip & Group Rides." Before submitting, check that nobody else already has the name.

## Process

- Code changes happen on branches with pull requests and tests. Anton reviews, merges, and tests each build on real rides. Derek tests too.
- Beta feedback comes through TestFlight's built-in feedback plus one group chat per riding group. After each ride, the notes become GitHub issues sorted as must-fix, should-fix, or post-launch.
