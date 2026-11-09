import XCTest
import CoreLocation
@testable import PerfectRouter

/// Highlights polish (H-1 to H-3). A blurb is shown only when it is real
/// prose about that exact place. A name or city restatement, review-site
/// filler, and text about another place all come back empty, and an empty
/// blurb draws no description line.
@MainActor
final class HighlightsPolishTests: XCTestCase {

    private let slug = "Slug Bug Ranch"
    private let cadillac = "Cadillac Ranch"

    private func shown(_ text: String, _ name: String) -> String? {
        PlaceDescriptionDisplay.text(for: text, name: name)
    }

    /// Every path that can put text on a card: the row, a MapKit subtitle,
    /// and the place's own page.
    private func assertEmptyEverywhere(_ text: String, name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(PlaceDescriptionDisplay.text(for: text, name: name), "display: \(text)", file: file, line: line)
        XCTAssertNil(PlaceDescriptionDisplay.rowText(for: text, name: name), "row: \(text)", file: file, line: line)
        XCTAssertNil(
            PlaceDescriptionReader.acceptedAppleMapsText(text, name: name, rejectIfEqual: [name]),
            "apple: \(text)", file: file, line: line
        )
        XCTAssertNil(PlaceDescriptionReader.acceptedPlaceText(text, name: name), "page: \(text)", file: file, line: line)
    }

    // MARK: H-1 restatement → empty

    func testNameAndCityRestatementsAreEmpty() {
        for text in [
            "Slug Bug Ranch in Conway, TX.",
            "Slug Bug Ranch is located in Conway, Texas.",
            "Slug Bug Ranch is a tourist attraction in Conway, Texas.",
            "Visit Slug Bug Ranch off I-40 at exit 96.",
            "Welcome to Slug Bug Ranch!",
            "Tourist attraction in Conway, Texas.",
        ] {
            assertEmptyEverywhere(text, name: slug)
        }
        for text in [
            "Cadillac Ranch is a landmark in Amarillo, Texas.",
            "Cadillac Ranch is located at 13651 I-40 Frontage Rd, Amarillo, TX 79124.",
            "Cadillac Ranch, Amarillo, TX.",
            "Located in Amarillo.",
        ] {
            XCTAssertNil(shown(text, cadillac), text)
            XCTAssertNil(PlaceDescriptionReader.acceptedPlaceText(text, name: cadillac), text)
        }
    }

    func testRestatementIsDroppedAndTheRealSentenceStays() {
        let text = "Slug Bug Ranch is located in Conway, Texas. A spray-painted row of Beetles stands nose-down beside an old trading post."
        XCTAssertEqual(
            shown(text, slug),
            "A spray-painted row of Beetles stands nose-down beside an old trading post."
        )
    }

    // MARK: H-1 review / listing filler → empty

    func testReviewAndListingFillerIsEmpty() {
        for text in [
            "Read reviews, see photos and get directions.",
            "Open 24 hours. Free admission.",
            "Plan your visit to Slug Bug Ranch today!",
            "Find what to do today, this weekend, or in November. We have reviews of the best places to see in Conway.",
            "Highly rated by travelers. Excellent 4.5 out of 5.",
            "Top-rated attraction. Loved by visitors.",
            "Slug Bug Ranch - Conway, TX - Yelp",
            "SLUG BUG RANCH - Updated November 2026 - 9696 I-40, Conway, Texas - Yelp",
            "Slug Bug Ranch, Conway: See 120 reviews, articles, and 98 photos of Slug Bug Ranch, ranked No.2 on Tripadvisor among 3 attractions in Conway.",
        ] {
            assertEmptyEverywhere(text, name: slug)
        }
    }

    func testFillerSentenceIsDroppedAroundRealProse() {
        let text = "Five Volkswagen Beetles stand buried nose-down beside an old Route 66 trading post. Read reviews, see photos and get directions."
        XCTAssertEqual(
            shown(text, slug),
            "Five Volkswagen Beetles stand buried nose-down beside an old Route 66 trading post."
        )
    }

    /// A long sentence that only mentions admission is prose, not chrome.
    func testLongSentenceMentioningAdmissionStays() {
        let text = "Admission is free and the cars are repainted by visitors every week."
        XCTAssertEqual(shown(text, slug), text)
    }

    // MARK: H-1 wrong place → empty

    func testAnotherLandmarksSignatureIsWrongPlace() {
        assertEmptyEverywhere(
            "Ten vintage Cadillacs stand buried nose-down in a wheat field west of Amarillo.",
            name: slug
        )
        assertEmptyEverywhere("Home of the free 72oz steak challenge since 1960.", name: slug)
        assertEmptyEverywhere("Five Volkswagen Beetles stand buried nose-down in Conway.", name: cadillac)
    }

    func testEachLandmarkKeepsItsOwnSignature() {
        let ranch = "Ten vintage Cadillacs stand buried nose-down in a wheat field west of Amarillo."
        XCTAssertEqual(shown(ranch, cadillac), ranch)
        let bugs = "Five Volkswagen Beetles stand buried nose-down beside an old Route 66 trading post."
        XCTAssertEqual(shown(bugs, slug), bugs)
        let steak = "Home of the free 72oz steak challenge since 1960."
        XCTAssertEqual(shown(steak, "The Big Texan Steak Ranch"), steak)
    }

    /// The Cadillac Ranch sentence never lands on another place.
    func testKnownSentenceStaysOnCadillacRanch() {
        XCTAssertNil(PlaceDescriptionReader.knownPlaceDescription(name: slug))
        let stop = SuggestedStop(
            name: slug,
            coordinate: CLLocationCoordinate2D(latitude: 35.434, longitude: -101.471),
            category: .attraction,
            distanceAlongRoute: 100_000,
            detourMeters: 150
        ).withPlaceDescription(PlaceDescriptionReader.cadillacRanchDescription)
        XCTAssertNil(stop.placeDescription)
    }

    func testDescriptionNamingASiblingHighlightIsCleared() {
        var bug = SuggestedStop(
            name: slug,
            coordinate: CLLocationCoordinate2D(latitude: 35.434, longitude: -101.471),
            category: .attraction,
            distanceAlongRoute: 300_000,
            detourMeters: 150
        )
        bug.placeDescription = "A quirky stop a short drive east of Palo Duro Canyon on old Route 66."
        var canyon = SuggestedStop(
            name: "Palo Duro Canyon",
            coordinate: CLLocationCoordinate2D(latitude: 34.94, longitude: -101.66),
            category: .attraction,
            distanceAlongRoute: 200_000,
            detourMeters: 5_000
        )
        canyon.placeDescription = "The second-largest canyon in the country."
        let cleared = PlaceDescriptionReader.clearingCrossNamedDescriptions([canyon, bug])
        XCTAssertEqual(cleared.map(\.name), ["Palo Duro Canyon", slug], "Rows are never dropped")
        XCTAssertEqual(cleared[0].placeDescription, "The second-largest canyon in the country.")
        XCTAssertNil(cleared[1].placeDescription)
    }

    func testRealProseStillShows() {
        let canyon = "The second-largest canyon in the country, with a paved road down to the floor."
        XCTAssertEqual(shown(canyon, "Palo Duro Canyon State Park"), canyon)
        XCTAssertEqual(shown("Route 66 icon.", slug), "Route 66 icon.")
        let station = "The restored 1930s gas station now serves as a Route 66 visitor center."
        XCTAssertEqual(shown(station, "Filling Station"), station)
    }

    // MARK: H-4 Slug Bug Ranch on OKC → Amarillo

    /// Apple links Slug Bug Ranch to bigtexan.com with a text fragment. The
    /// page's meta text is the steakhouse; the marked passage is the ranch.
    private let slugBugURL = URL(string: "https://www.bigtexan.com/slugbugranch/#:~:text=The%20Slug%20Bug%20Ranch%2C%20originally,Texan%20RV%20Ranch%20in%20Amarillo.")!
    private let slugBugPage = """
    <html><head><title>Right</title>
    <meta property="og:description" content="The Big Texan Steak Ranch, world famous for of the free 72oz steak challenge. Historic Route 66 landmark and Texas icon. Only located in Amarillo, Texas.">
    </head><body><h3>The Next Big Thing</h3>
    <p>The Slug Bug Ranch, originally an iconic installation near Conway, Texas, has been relocated to a new, prominent position along Interstate 40, in front of the Big Texan RV Ranch in Amarillo. This move brings the whimsical display of half-buried Volkswagen Beetles closer to a larger audience.</p>
    </body></html>
    """
    private let slugBugPassage = "The Slug Bug Ranch, originally an iconic installation near Conway, Texas, has been relocated to a new, prominent position along Interstate 40, in front of the Big Texan RV Ranch in Amarillo."

    func testTextFragmentIsParsed() {
        let fragment = PlaceDescriptionReader.textFragment(of: slugBugURL)
        XCTAssertEqual(fragment?.start, "The Slug Bug Ranch, originally")
        XCTAssertEqual(fragment?.end, "Texan RV Ranch in Amarillo.")
        XCTAssertNil(PlaceDescriptionReader.textFragment(of: URL(string: "https://www.bigtexan.com/")!))
    }

    func testSlugBugRanchGetsItsOwnPassageNotTheSteakhouse() async {
        XCTAssertEqual(
            PlaceDescriptionReader.textFragmentPassage(in: slugBugPage, url: slugBugURL, name: slug),
            slugBugPassage
        )
        // The page's own meta text is the steakhouse and never shows.
        XCTAssertNil(PlaceDescriptionReader.placeText(from: slugBugPage, name: slug, pageURL: slugBugURL))
        let page = slugBugPage
        let query = PlaceDescriptionQuery(
            id: UUID(),
            name: slug,
            appleMapsCandidate: "1415 Sunrise Dr, Amarillo, TX 79104, United States",
            rejectIfEqual: [slug],
            websiteURL: slugBugURL
        )
        let text = await PlaceDescriptionLoader.text(for: query) { _ in page }
        XCTAssertEqual(text, slugBugPassage)
    }

    func testPassageThatDoesNotNameThePlaceIsNotUsed() {
        XCTAssertNil(PlaceDescriptionReader.textFragmentPassage(in: slugBugPage, url: slugBugURL, name: cadillac))
        let elsewhere = URL(string: "https://www.bigtexan.com/#:~:text=This%20move%20brings%20the")!
        XCTAssertNil(PlaceDescriptionReader.textFragmentPassage(in: slugBugPage, url: elsewhere, name: slug))
    }

    /// On OKC → Amarillo the ranch is parked just inside the end window. Its
    /// stand-in mile must not push out Slug Bug Ranch a few miles earlier.
    func testCadillacRanchAndSlugBugRanchAreBothPicked() {
        let total: CLLocationDistance = 418_000
        let bug = SuggestedStop(
            name: slug,
            coordinate: CLLocationCoordinate2D(latitude: 35.1935, longitude: -101.7713),
            category: .attraction,
            distanceAlongRoute: total - 7_000,
            detourMeters: 120
        )
        let ranch = SuggestedStop(
            name: cadillac,
            coordinate: PlaceDescriptionReader.cadillacRanchCoordinate,
            category: .attraction,
            distanceAlongRoute: total,
            detourMeters: 13_700
        )
        let picked = RoutePlannerViewModel.selectHighlights(from: [ranch, bug], totalDistance: total)
        XCTAssertEqual(Set(picked.map(\.name)), [slug, cadillac])
        XCTAssertEqual(picked.map(\.name), picked.sorted { $0.distanceAlongRoute < $1.distanceAlongRoute }.map(\.name))
    }

    /// Four closer sights do not push the ranch off the list.
    func testParkedCadillacRanchKeepsItsSlotWhenTheCapIsFull() {
        let total: CLLocationDistance = 418_000
        let mile = 1_609.344
        var candidates = [20.0, 166, 186, 255].map { miles in
            SuggestedStop(
                name: "Sight \(Int(miles))",
                coordinate: CLLocationCoordinate2D(latitude: 35, longitude: -100),
                category: .attraction,
                distanceAlongRoute: miles * mile,
                detourMeters: miles == 255 ? 50 : 100
            )
        }
        candidates.append(SuggestedStop(
            name: cadillac,
            coordinate: PlaceDescriptionReader.cadillacRanchCoordinate,
            category: .attraction,
            distanceAlongRoute: total,
            detourMeters: 13_700
        ))
        let picked = RoutePlannerViewModel.selectHighlights(from: candidates, totalDistance: total)
        XCTAssertEqual(picked.count, 4)
        XCTAssertTrue(picked.contains { $0.name == cadillac }, "\(picked.map(\.name))")
        XCTAssertTrue(picked.contains { $0.name == "Sight 255" }, "Slug Bug's slot near the end stays")
    }

    // MARK: H-3 add in ride order, quiet undo, no double draw

    private func waypoint(_ name: String, lat: Double) -> Waypoint {
        Waypoint(name: name, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: -82.0))
    }

    func testRideOrderIndexPutsTheSightBetweenStops() {
        XCTAssertEqual(RoutePlannerViewModel.rideOrderIndex(forStopAt: 50, middleDistances: []), 1)
        XCTAssertEqual(RoutePlannerViewModel.rideOrderIndex(forStopAt: 50, middleDistances: [100, 200]), 1)
        XCTAssertEqual(RoutePlannerViewModel.rideOrderIndex(forStopAt: 150, middleDistances: [100, 200]), 2)
        XCTAssertEqual(RoutePlannerViewModel.rideOrderIndex(forStopAt: 250, middleDistances: [100, 200]), 3)
    }

    func testAddingAHighlightShowsUndoAndUndoRemovesOnlyIt() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [
            waypoint("Start", lat: 33.0),
            Waypoint(name: "Fuel", coordinate: CLLocationCoordinate2D(latitude: 33.5, longitude: -82.0), isGasFill: true),
            waypoint("End", lat: 34.0),
        ]
        let sight = SuggestedStop(
            name: "Overlook",
            coordinate: CLLocationCoordinate2D(latitude: 33.7, longitude: -82.0),
            category: .attraction,
            distanceAlongRoute: 70_000,
            detourMeters: 50
        )
        viewModel.rideHighlights = [sight]
        viewModel.addStop(from: sight)

        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Fuel", "Overlook", "End"])
        XCTAssertEqual(viewModel.foodStopUndo?.name, "Overlook")
        XCTAssertEqual(viewModel.foodStopUndo?.isHighlight, true)

        viewModel.undoFoodStop()
        XCTAssertNil(viewModel.foodStopUndo)
        XCTAssertEqual(viewModel.waypoints.map(\.name), ["Start", "Fuel", "End"], "Fuel stays after Undo")
    }

    func testFoodAddStillUsesTheFoodBanner() {
        let viewModel = RoutePlannerViewModel()
        viewModel.waypoints = [waypoint("Start", lat: 33.0), waypoint("End", lat: 34.0)]
        let diner = SuggestedStop(
            name: "Diner",
            coordinate: CLLocationCoordinate2D(latitude: 33.4, longitude: -82.0),
            category: .food,
            distanceAlongRoute: 40_000
        )
        viewModel.addStop(from: diner)
        XCTAssertEqual(viewModel.foodStopUndo?.isHighlight, false)
    }

    /// A separate Sights search returns the same place under a new id. It is
    /// still the highlight, so the generic list and pins skip it.
    func testSameSightFromAnotherSearchIsNotListedTwice() {
        let viewModel = RoutePlannerViewModel()
        let coordinate = CLLocationCoordinate2D(latitude: 35.1872, longitude: -101.9870)
        let highlight = SuggestedStop(
            name: "Cadillac Ranch", coordinate: coordinate, category: .attraction, distanceAlongRoute: 10
        )
        let sameAgain = SuggestedStop(
            name: "Cadillac Ranch", coordinate: coordinate, category: .attraction, distanceAlongRoute: 10
        )
        let renamed = SuggestedStop(
            name: "The Cadillac Ranch",
            coordinate: CLLocationCoordinate2D(latitude: 35.20, longitude: -101.95),
            category: .attraction,
            distanceAlongRoute: 10
        )
        let pumpNextDoor = SuggestedStop(
            name: "Ranch Fuel", coordinate: coordinate, category: .gas, distanceAlongRoute: 10
        )
        viewModel.rideHighlights = [highlight]
        XCTAssertNotEqual(highlight.id, sameAgain.id)
        XCTAssertTrue(viewModel.isRideHighlight(sameAgain))
        XCTAssertTrue(viewModel.isRideHighlight(renamed))
        XCTAssertFalse(viewModel.isRideHighlight(pumpNextDoor))
    }
}
