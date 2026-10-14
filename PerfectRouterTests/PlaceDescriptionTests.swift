import CoreLocation
import MapKit
import XCTest
@testable import PerfectRouter

/// Place cards show published prose only. A place with no Apple Maps sentence
/// and no description of its own contributes nothing — the card stays blank.
@MainActor
final class PlaceDescriptionTests: XCTestCase {

    private let gorge = "A granite gorge on the Tallulah River."

    func testCollapsedCardsUseTwoLines() {
        XCTAssertEqual(PlaceDescriptionDisplay.collapsedLineLimit, 2)
        XCTAssertEqual(PlaceDescriptionDisplay.rowSentenceLimit, 2)
    }

    func testRowAndSheetShareTheTwoSentenceCap() {
        let source = "First published sentence. Second published sentence. Third sentence stays out."
        let capped = "First published sentence. Second published sentence."
        XCTAssertEqual(PlaceDescriptionDisplay.text(for: source), capped)
        XCTAssertEqual(PlaceDescriptionDisplay.rowText(for: source), capped)
        XCTAssertNil(PlaceDescriptionDisplay.rowText(for: nil))
        XCTAssertNil(PlaceDescriptionDisplay.rowText(for: "   "))
        XCTAssertEqual(
            PlaceDescriptionDisplay.rowText(for: "Only one sentence."),
            "Only one sentence."
        )
        let stored = SuggestedStop(
            name: "Overlook",
            coordinate: CLLocationCoordinate2D(latitude: 34.6, longitude: -83.4),
            category: .attraction,
            distanceAlongRoute: 1_000,
            detourMeters: 40
        ).withPlaceDescription(source)
        XCTAssertEqual(stored.placeDescription, capped)
    }

    func testStreetAndMountainAbbreviationsAreNotSentenceEnds() {
        let source = "The trail starts on Main St. near the river. It climbs Mt. Mitchell after the bridge. Bring water."
        XCTAssertEqual(
            PlaceDescriptionDisplay.rowText(for: source),
            "The trail starts on Main St. near the river. It climbs Mt. Mitchell after the bridge."
        )
        XCTAssertEqual(
            PlaceDescriptionDisplay.rowText(for: "Visit St. Louis today. The arch is downtown. Go early."),
            "Visit St. Louis today. The arch is downtown."
        )
        XCTAssertEqual(
            PlaceDescriptionDisplay.rowText(for: "Watch the edge! Is the path open? Bring a light."),
            "Watch the edge! Is the path open?"
        )
    }

    func testBlankTextIsNoDescription() {
        XCTAssertNil(PlaceDescriptionDisplay.text(for: nil))
        XCTAssertNil(PlaceDescriptionDisplay.text(for: " \n\t "))
        XCTAssertNil(PlaceDescriptionDisplay.text(for: "..."))
    }

    func testComparisonSignInProseIsKept() {
        let source = "3 < 4 miles of trail remain."
        XCTAssertEqual(PlaceDescriptionReader.normalize(source), source)
    }

    func testPublishedSentenceIsNotRewritten() {
        let source = "Built in 1891 for the railroad. Now a footbridge."
        XCTAssertEqual(PlaceDescriptionReader.normalize(source), source)
        XCTAssertEqual(
            PlaceDescriptionDisplay.text(for: "  \(source)  "),
            source
        )
    }

    func testNoAppleMapsOrPlaceTextYieldsNil() async {
        let query = PlaceDescriptionQuery(
            id: UUID(),
            name: "Tallulah Gorge",
            appleMapsCandidate: "Scenic",
            rejectIfEqual: [],
            websiteURL: nil
        )
        let text = await PlaceDescriptionLoader.text(for: query) { _ in
            "This closure must not be turned into a description."
        }
        XCTAssertNil(text)
    }

    func testCoordinateOnlyMapItemHasNoDescription() {
        let item = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: 34.6, longitude: -83.4)
        ))
        item.name = "Tallulah Gorge"
        XCTAssertNil(PlaceDescriptionReader.appleMapsText(from: item))
        XCTAssertNil(item.url)

        let stop = SuggestedStop(
            mapItem: item,
            category: .scenic,
            distanceAlongRoute: 1_000,
            detourMeters: 40
        )
        XCTAssertNil(stop.placeDescription)
        XCTAssertNil(stop.withPlaceDescription("   ").placeDescription)
    }

    func testAppleMapsSentenceIsKeptVerbatim() async {
        let sentence = "Stone arch bridge built in 1891. Open to walkers."
        let query = PlaceDescriptionQuery(
            id: UUID(),
            name: "Stone Bridge",
            appleMapsCandidate: sentence,
            rejectIfEqual: ["Stone Bridge"],
            websiteURL: URL(string: "https://example.com/bridge")
        )
        let text = await PlaceDescriptionLoader.text(for: query) { _ in
            "<meta name=\"description\" content=\"Different words from the website.\">"
        }
        XCTAssertEqual(text, sentence)
    }

    func testAddressPhoneAndCategorySubtitlesFallThroughToTheWebsite() async {
        let page = gorge
        let html = "<meta name=\"description\" content=\"\(page)\">"
        let subtitles = [
            "120 Ridge Road, Clayton, GA 30525",
            "Main Street, Springfield, Illinois.",
            "Manchester, New Hampshire.",
            "(706) 555-0148",
            "Phone: (706) 555-0148",
            "706-555-0148 ext 2",
            "Gas Station",
            "Restaurant",
            "Hotel",
            "National Park",
            "Tourist Attraction",
            "Point of Interest.",
        ]
        for subtitle in subtitles {
            let query = PlaceDescriptionQuery(
                id: UUID(),
                name: "Tallulah Gorge",
                appleMapsCandidate: subtitle,
                rejectIfEqual: [],
                websiteURL: URL(string: "https://tallulahgorge.example/visit")
            )
            let text = await PlaceDescriptionLoader.text(for: query) { _ in html }
            XCTAssertEqual(text, page, subtitle)
        }

        let addressOnly = PlaceDescriptionQuery(
            id: UUID(),
            name: "Tallulah Gorge",
            appleMapsCandidate: "120 Ridge Road, Clayton, GA 30525",
            rejectIfEqual: [],
            websiteURL: nil
        )
        let missing = await PlaceDescriptionLoader.text(for: addressOnly) { _ in
            "This page must not be fetched without a place URL."
        }
        XCTAssertNil(missing)
    }

    func testRealSubtitleIsKeptAndLaterSentencesAreDropped() async {
        let sentence = "A family restaurant on the square since opening day. The kitchen still bakes its bread. The third sentence is not stored."
        let query = PlaceDescriptionQuery(
            id: UUID(),
            name: "Square Cafe",
            appleMapsCandidate: sentence,
            rejectIfEqual: ["Square Cafe"],
            websiteURL: URL(string: "https://example.com/cafe")
        )
        let text = await PlaceDescriptionLoader.text(for: query) { _ in
            "<meta name=\"description\" content=\"Different words from the website.\">"
        }
        XCTAssertEqual(
            text,
            "A family restaurant on the square since opening day. The kitchen still bakes its bread."
        )
    }

    func testWebsiteDropsCallToActionSentencesBeforeTheCap() {
        let html = """
        <meta name="description" content="Book now. A granite gorge on the Tallulah River. Call today. Trails stay open all year. Order online. A third trail sentence stays out.">
        """
        XCTAssertEqual(
            PlaceDescriptionReader.placeText(from: html, name: "Tallulah Gorge"),
            "A granite gorge on the Tallulah River. Trails stay open all year."
        )
        XCTAssertEqual(
            PlaceDescriptionReader.placeText(
                from: "<meta name=\"description\" content=\"Book now. Reserve a dawn tour of the gorge if you want the quiet.\">",
                name: "Tallulah Gorge"
            ),
            "Reserve a dawn tour of the gorge if you want the quiet."
        )
    }

    func testWebsiteThatIsOnlyCallsToActionIsNil() {
        let phrases = "Book now. Call today. Order online. Reserve your table. Shop now."
        let html = "<meta name=\"description\" content=\"\(phrases)\">"
        XCTAssertNil(PlaceDescriptionReader.placeText(from: html, name: "Cafe"))
        XCTAssertNil(PlaceDescriptionReader.placeText(
            from: "<meta property=\"og:description\" content=\"Shop now! Buy tickets.\">",
            name: "Cafe"
        ))
    }

    func testAddressAndCategoryAreNotDescriptions() {
        XCTAssertNil(PlaceDescriptionReader.acceptedAppleMapsText(
            "120 Ridge Road, Clayton, GA",
            name: "Overlook",
            rejectIfEqual: ["120 Ridge Road, Clayton, GA"]
        ))
        XCTAssertNil(PlaceDescriptionReader.acceptedAppleMapsText(
            "100 St. Mary Road",
            name: "Chapel",
            rejectIfEqual: []
        ))
        XCTAssertNil(PlaceDescriptionReader.acceptedAppleMapsText(
            "Tourist Attraction",
            name: "Overlook",
            rejectIfEqual: []
        ))
        XCTAssertNil(PlaceDescriptionReader.acceptedAppleMapsText(
            "Overlook",
            name: "Overlook",
            rejectIfEqual: []
        ))
        XCTAssertEqual(
            PlaceDescriptionReader.acceptedAppleMapsText(
                "A granite gorge on the river.",
                name: "Overlook",
                rejectIfEqual: ["Overlook"]
            ),
            "A granite gorge on the river."
        )
    }

    func testSocialEngagementCountsAreNotADescription() {
        let boilerplate = "Cadillac Ranch, Amarillo. 38,816 followers · 367 talking about this · 77,990 were here."
        XCTAssertNil(PlaceDescriptionReader.acceptedAppleMapsText(
            boilerplate,
            name: "Cadillac Ranch",
            rejectIfEqual: []
        ))
        XCTAssertNil(PlaceDescriptionReader.acceptedPlaceText(boilerplate, name: "Cadillac Ranch"))
        XCTAssertNil(PlaceDescriptionDisplay.text(for: boilerplate))
        XCTAssertEqual(
            PlaceDescriptionReader.acceptedAppleMapsText(
                "Ten vintage Cadillacs stand buried nose-down in a wheat field.",
                name: "Cadillac Ranch",
                rejectIfEqual: []
            ),
            "Ten vintage Cadillacs stand buried nose-down in a wheat field."
        )
    }

    /// A follower count used to reject the whole string, so every place
    /// whose subtitle mentioned one lost its description. The stats
    /// sentence goes; the prose stays. Cadillac Ranch, whose MapKit text
    /// is only the name and those stats, still shows its known sentence.
    func testRealDescriptionSurvivesSocialEngagementStats() {
        let prose = "Ten vintage Cadillacs stand buried nose-down in a wheat field."
        let mixed = "\(prose) 38,816 followers · 367 talking about this · 77,990 were here."
        XCTAssertEqual(
            PlaceDescriptionReader.acceptedAppleMapsText(
                mixed,
                name: "Cadillac Ranch",
                rejectIfEqual: []
            ),
            prose
        )
        XCTAssertEqual(PlaceDescriptionReader.acceptedPlaceText(mixed, name: "Cadillac Ranch"), prose)
        XCTAssertEqual(PlaceDescriptionDisplay.text(for: mixed), prose)

        let mentionsFollowers = "The buried cars draw followers of roadside art from across the country."
        XCTAssertEqual(PlaceDescriptionDisplay.text(for: mentionsFollowers), mentionsFollowers)
        XCTAssertEqual(
            PlaceDescriptionReader.acceptedPlaceText(mentionsFollowers, name: "Cadillac Ranch"),
            mentionsFollowers
        )
    }

    func testCadillacRanchShowsACleanDescription() {
        let known = PlaceDescriptionReader.knownPlaceDescription(name: "Cadillac Ranch")
        XCTAssertEqual(known, PlaceDescriptionReader.cadillacRanchDescription)
        XCTAssertEqual(
            known,
            "Ten vintage Cadillacs stand buried nose-down in a wheat field west of Amarillo."
        )
        XCTAssertFalse(known?.localizedCaseInsensitiveContains("followers") ?? true)
        XCTAssertNil(PlaceDescriptionReader.knownPlaceDescription(name: "Casey's"))

        let boilerplate = "Cadillac Ranch, Amarillo. 38,816 followers · 367 talking about this · 77,990 were here."
        let stop = SuggestedStop(
            name: "Cadillac Ranch",
            coordinate: PlaceDescriptionReader.cadillacRanchCoordinate,
            category: .attraction,
            distanceAlongRoute: 100_000,
            detourMeters: 400
        )
        XCTAssertNil(stop.withPlaceDescription(boilerplate).placeDescription)
        XCTAssertEqual(
            stop.withPlaceDescription(PlaceDescriptionReader.cadillacRanchDescription).placeDescription,
            PlaceDescriptionReader.cadillacRanchDescription
        )
    }

    func testPlacePageDescriptionIsUsedWhenAppleMapsHasNone() async {
        let query = placeQuery(url: "https://tallulahgorge.example/visit")
        let html = """
        <html><head>
        <meta content="\(gorge)" name="description">
        </head></html>
        """
        let text = await PlaceDescriptionLoader.text(for: query) { url in
            XCTAssertEqual(url.host, "tallulahgorge.example")
            return html
        }
        XCTAssertEqual(text, gorge)
    }

    func testPlacePageWithNoDescriptionYieldsNil() async {
        let query = placeQuery(url: "https://example.com/overlook")
        let text = await PlaceDescriptionLoader.text(for: query) { _ in
            "<html><title>Tallulah Gorge</title><body><p>Nav</p></body></html>"
        }
        XCTAssertNil(text)

        let missing = await PlaceDescriptionLoader.text(for: query) { _ in nil }
        XCTAssertNil(missing)

        let nameOnly = await PlaceDescriptionLoader.text(for: query) { _ in
            "<meta name=\"description\" content=\"Tallulah Gorge\">"
        }
        XCTAssertNil(nameOnly)
    }

    func testMapHostIsNotThePlacesOwnDescription() async {
        let query = PlaceDescriptionQuery(
            id: UUID(),
            name: "Overlook",
            appleMapsCandidate: "120 Ridge Road",
            rejectIfEqual: ["120 Ridge Road"],
            websiteURL: URL(string: "https://maps.apple.com/place?id=1")
        )
        let text = await PlaceDescriptionLoader.text(for: query) { _ in
            "<meta name=\"description\" content=\"\(self.gorge)\">"
        }
        XCTAssertNil(text)
        XCTAssertFalse(PlaceDescriptionReader.isPlaceWebsite(URL(string: "http://example.com/place")!))
        XCTAssertTrue(PlaceDescriptionReader.isPlaceWebsite(URL(string: "https://example.com/place")!))
    }

    func testMetaDescriptionBeatsOpenGraphAndDecodesEntities() {
        let html = """
        <html><head>
        <meta property="og:description" content="Open graph sentence about the gorge.">
        <meta name="description" content="Fish &amp; chips on the river.">
        </head></html>
        """
        XCTAssertEqual(
            PlaceDescriptionReader.placeText(from: html, name: "Diner"),
            "Fish & chips on the river."
        )
    }

    func testOpenGraphUsedWhenMetaDescriptionIsMissing() {
        let html = """
        <meta property='og:description' content='Open ridge above the valley.'>
        """
        XCTAssertEqual(
            PlaceDescriptionReader.placeText(from: html, name: "Overlook"),
            "Open ridge above the valley."
        )
    }

    func testJSONLDPrefersThePlacesOwnObject() {
        let html = """
        <script type="application/ld+json">
        {"@graph":[
          {"@type":"Organization","name":"State Parks","description":"We manage public lands in the state."},
          {"@type":"TouristAttraction","name":"Tallulah Gorge","description":"A gorge cut by the Tallulah River."}
        ]}
        </script>
        """
        XCTAssertEqual(
            PlaceDescriptionReader.placeText(from: html, name: "Tallulah Gorge"),
            "A gorge cut by the Tallulah River."
        )
    }

    func testMarkupAroundPlaceWordsIsNotKept() {
        let html = """
        <meta name="description" content="A &lt;b&gt;granite gorge&lt;/b&gt; on the river.">
        """
        XCTAssertEqual(
            PlaceDescriptionReader.placeText(from: html, name: "Overlook"),
            "A granite gorge on the river."
        )
    }

    func testOnlyScenicAndSightsShowDescriptions() {
        XCTAssertTrue(StopCategory.scenic.showsPlaceDescription)
        XCTAssertTrue(StopCategory.attraction.showsPlaceDescription)
        XCTAssertFalse(StopCategory.gas.showsPlaceDescription)
        XCTAssertFalse(StopCategory.food.showsPlaceDescription)
        XCTAssertFalse(StopCategory.coffee.showsPlaceDescription)
    }

    func testHighlightSelectionKeepsPublishedDescription() {
        let stop = SuggestedStop(
            name: "Tallulah Gorge",
            coordinate: CLLocationCoordinate2D(latitude: 34.6, longitude: -83.4),
            category: .attraction,
            distanceAlongRoute: 100_000,
            detourMeters: 100
        ).withPlaceDescription("  \(gorge)  ")
        let plain = SuggestedStop(
            name: "Bare Overlook",
            coordinate: CLLocationCoordinate2D(latitude: 34.7, longitude: -83.5),
            category: .attraction,
            distanceAlongRoute: 150_000,
            detourMeters: 80
        )

        let picked = RoutePlannerViewModel.selectHighlights(
            from: [stop, plain],
            totalDistance: 200_000
        )
        XCTAssertEqual(picked.map(\.name), ["Tallulah Gorge", "Bare Overlook"])
        XCTAssertEqual(picked.map(\.placeDescription), [gorge, nil])
        XCTAssertEqual(picked[0].id, stop.id)
    }

    private func placeQuery(url: String) -> PlaceDescriptionQuery {
        PlaceDescriptionQuery(
            id: UUID(),
            name: "Tallulah Gorge",
            appleMapsCandidate: nil,
            rejectIfEqual: ["Tallulah Gorge"],
            websiteURL: URL(string: url)
        )
    }
}
