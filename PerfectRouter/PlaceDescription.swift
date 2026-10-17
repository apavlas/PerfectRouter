import Foundation
import MapKit

/// The stored description is at most two sentences. The row clips that text
/// to two lines. The sheet shows the same two sentences with no line limit.
/// Later sentences are never shown.
///
/// Apple Maps place objects expose a name, address, category, phone, and URL.
/// A card shows `MKPlacemark.subtitle` only when it is already a sentence and
/// not an address, a phone number, or a bare category. Otherwise the place's
/// own page is read. Engagement-stat sentences are removed; the prose around
/// them stays. Cadillac Ranch is the one landmark with a known sentence when
/// the published text is only a name or those stats.
enum PlaceDescriptionDisplay {
    static let collapsedLineLimit = 2
    static let rowSentenceLimit = 2

    /// The description the row and the sheet share: normalized, then cut
    /// after the second sentence. "St." and "Mt." are not endings. Blank
    /// input and a shorter source stay nil or whole.
    static func text(for description: String?, name: String? = nil) -> String? {
        guard let text = PlaceDescriptionReader.normalize(description) else { return nil }
        guard let social = PlaceDescriptionReader.droppingSocialEngagementSentences(in: text) else {
            return nil
        }
        guard let prose = PlaceDescriptionReader.strippingRestatedNameAndLocality(in: social, name: name) else {
            return nil
        }
        if PlaceDescriptionReader.isNameAndLocality(prose) { return nil }
        return PlaceDescriptionReader.firstSentences(in: prose, limit: rowSentenceLimit)
    }

    /// Same string as `text(for:)`. The row applies `collapsedLineLimit` on top.
    static func rowText(for description: String?, name: String? = nil) -> String? {
        text(for: description, name: name)
    }
}

/// Sendable facts copied off an `MKMapItem` before any await. The map item
/// itself never crosses an isolation boundary.
struct PlaceDescriptionQuery: Sendable, Equatable {
    var id: UUID
    var name: String?
    /// `MKPlacemark.subtitle`, which MapKit sometimes fills with prose and
    /// sometimes with an address or a category label.
    var appleMapsCandidate: String?
    /// Name, phone, and address strings that must not be shown as a description.
    var rejectIfEqual: [String]
    var websiteURL: URL?
}

enum PlaceDescriptionReader {

    /// Apple Maps prose for this item, or nil when the item has none.
    /// Main-actor because `MKMapItem` stays there; only the copied strings leave.
    @MainActor
    static func appleMapsText(from item: MKMapItem) -> String? {
        let query = PlaceDescriptionQuery(
            id: UUID(),
            name: item.name,
            appleMapsCandidate: item.placemark.subtitle,
            rejectIfEqual: addressRejects(from: item),
            websiteURL: item.url
        )
        return acceptedAppleMapsText(
            query.appleMapsCandidate,
            name: query.name,
            rejectIfEqual: query.rejectIfEqual
        )
    }

    /// Name, phone, and address lines. Equality with one of these is not a
    /// description — it is the title or the location we already show.
    @MainActor
    static func addressRejects(from item: MKMapItem) -> [String] {
        let placemark = item.placemark
        var rejects: [String] = []
        let fields = [
            item.name,
            item.phoneNumber,
            placemark.name,
            placemark.title,
            placemark.thoroughfare,
            placemark.subThoroughfare,
            placemark.locality,
            placemark.subLocality,
            placemark.administrativeArea,
            placemark.subAdministrativeArea,
            placemark.postalCode,
            placemark.country,
        ]
        for field in fields {
            if let field { rejects.append(field) }
        }
        let street = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0 }
            .joined(separator: " ")
        let cityLine = [street, placemark.locality, placemark.administrativeArea, placemark.postalCode]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !cityLine.isEmpty { rejects.append(cityLine) }
        return rejects
    }

    /// Accepts a MapKit string only when it is already a sentence and it is
    /// not an address, a phone number, a bare category, or the place name.
    /// Those subtitles return nil so the loader can read the place's page.
    /// The result is capped at two sentences.
    static func acceptedAppleMapsText(
        _ raw: String?,
        name: String?,
        rejectIfEqual rejects: [String]
    ) -> String? {
        if let raw, isOnlyPhoneNumber(raw) { return nil }
        guard let text = normalize(raw) else { return nil }
        if isOnlyPhoneNumber(text) || isBareCategory(text) || isOnlyAddress(text) { return nil }
        guard let social = droppingSocialEngagementSentences(in: text) else { return nil }
        guard let prose = strippingRestatedNameAndLocality(in: social, name: name) else { return nil }
        if let name, same(prose, name) { return nil }
        if isNameAndLocality(prose, name: name) { return nil }
        if rejects.contains(where: { candidate in
            guard let normalized = normalize(candidate) else { return false }
            return same(prose, normalized)
        }) {
            return nil
        }
        guard isAppleMapsProse(prose) else { return nil }
        return firstSentences(in: prose, limit: PlaceDescriptionDisplay.rowSentenceLimit)
    }

    /// The place's own description fields, in the order the page publishes
    /// them: meta description, then Open Graph, then JSON-LD. Pure calls to
    /// action are removed before the two-sentence cap. Nil when nothing
    /// descriptive is left.
    static func placeText(from document: String, name: String?) -> String? {
        if let meta = metaContent(in: document, attribute: "name", equals: "description"),
           let text = acceptedPlaceText(meta, name: name) {
            return text
        }
        if let openGraph = metaContent(in: document, attribute: "property", equals: "og:description"),
           let text = acceptedPlaceText(openGraph, name: name) {
            return text
        }
        return jsonLDDescription(in: document, placeName: name)
    }

    /// HTTPS page Apple associated with the place. Map hosts are not the
    /// place speaking, and cleartext HTTP is not fetched.
    static func isPlaceWebsite(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let blocked = [
            "maps.apple.com",
            "maps.google.com",
            "maps.googleapis.com",
            "googleusercontent.com",
            "goo.gl",
            "maps.app.goo.gl",
        ]
        return !blocked.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    /// Trims, collapses whitespace, and drops strings with no letters.
    /// The words themselves are left as published.
    static func normalize(_ raw: String?) -> String? {
        guard var text = raw else { return nil }
        if text.contains("<"), text.contains(">") {
            text = stripTags(text)
        }
        text = decodeHTML(text)
        if text.contains("<"), text.contains(">") {
            text = stripTags(text)
        }
        let collapsed = text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.contains(where: \.isLetter) else { return nil }
        return collapsed
    }

    /// A place-published description. Call-to-action sentences are dropped,
    /// then at most two sentences remain. Nil when that leaves fewer than
    /// three words or only the place name.
    static func acceptedPlaceText(_ raw: String?, name: String?) -> String? {
        guard let text = normalize(raw) else { return nil }
        guard let social = droppingSocialEngagementSentences(in: text) else { return nil }
        guard let prose = strippingRestatedNameAndLocality(in: social, name: name) else { return nil }
        if let name, same(prose, name) { return nil }
        if isNameAndLocality(prose, name: name) { return nil }
        let kept = sentences(in: prose).filter { !isPureCallToAction($0) }
        guard !kept.isEmpty else { return nil }
        let capped = firstSentences(
            in: kept.joined(separator: " "),
            limit: PlaceDescriptionDisplay.rowSentenceLimit
        )
        let words = capped.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return nil }
        return capped
    }

    /// One sentence of Facebook-style place stats is not a description.
    /// "38,816 followers · 367 talking about this · 77,990 were here" is
    /// dropped. Two of those phrases, or one phrase with almost no other
    /// words, marks the sentence. A real sentence that merely says
    /// "followers" stays.
    static func isSocialEngagementBoilerplate(_ text: String) -> Bool {
        let key = matchKey(text)
        guard !key.isEmpty else { return false }
        let markers = ["talking about this", "were here", "followers"]
        let hits = markers.reduce(into: 0) { count, marker in
            if key.contains(marker) { count += 1 }
        }
        if hits >= 2 { return true }
        guard hits == 1 else { return false }
        var remainder = key
        for marker in markers {
            remainder = remainder.replacingOccurrences(of: marker, with: " ")
        }
        let words = remainder.split(whereSeparator: \.isWhitespace).filter { token in
            token.contains { $0.isLetter }
        }
        return words.count < 3
    }

    /// Drops engagement-stat sentences and keeps the prose around them.
    /// Nil when every sentence was stats.
    static func droppingSocialEngagementSentences(in text: String) -> String? {
        let parts = sentences(in: text)
        guard !parts.isEmpty else { return nil }
        let kept = parts.filter { !isSocialEngagementBoilerplate($0) }
        guard !kept.isEmpty else { return nil }
        if kept.count == parts.count { return text }
        return normalize(kept.joined(separator: " "))
    }

    /// Drops sentences that only restate the place name and/or its city
    /// ("The Filling Station El Reno, Oklahoma.") and keeps the real prose
    /// around them. Nil only when nothing is left after stripping.
    static func strippingRestatedNameAndLocality(in text: String, name: String?) -> String? {
        let parts = sentences(in: text)
        guard !parts.isEmpty else { return nil }
        let kept = parts.filter { !isRestatedLabel($0, name: name) }
        guard !kept.isEmpty else { return nil }
        if kept.count == parts.count { return text }
        return normalize(kept.joined(separator: " "))
    }

    private static func isRestatedLabel(_ sentence: String, name: String?) -> Bool {
        if isNameAndLocality(sentence, name: name) { return true }
        guard let name else { return false }
        let nameKey = matchKey(name)
        guard !nameKey.isEmpty else { return false }
        let key = " " + matchKey(sentence) + " "
        guard key.contains(" \(nameKey) ") else { return false }
        let rest = key.replacingOccurrences(of: " \(nameKey) ", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { $0 != "the" }
        if rest.isEmpty { return true }
        guard rest.count <= 6 else { return false }
        return !rest.contains { proseVerbs.contains($0) || placeLabelFunctionWords.contains($0) }
    }

    /// "Cadillac Ranch, Amarillo." is a place label, not a description.
    /// A sentence with a verb, or with ordinary prose words, is kept.
    /// When `name` is known, the name plus at most two locality words is
    /// the same kind of label.
    static func isNameAndLocality(_ text: String, name: String? = nil) -> Bool {
        let parts = sentences(in: text)
        guard parts.count == 1 else { return false }
        let sentence = parts[0]
        if let name {
            let nameKey = matchKey(name)
            let key = matchKey(sentence)
            if !nameKey.isEmpty, key == nameKey { return true }
            if !nameKey.isEmpty, key.hasPrefix(nameKey + " ") {
                let rest = key.dropFirst(nameKey.count)
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                if rest.count <= 2,
                   !rest.contains(where: { proseVerbs.contains($0) || placeLabelFunctionWords.contains($0) }) {
                    return true
                }
            }
        }
        guard sentence.contains(",") else { return false }
        let tokens = addressTokens(in: sentence)
        guard tokens.count >= 2, tokens.count <= 6 else { return false }
        if tokens.contains(where: { proseVerbs.contains($0) || placeLabelFunctionWords.contains($0) }) {
            return false
        }
        return true
    }

    /// Cadillac Ranch, just south of I-40 west of Amarillo. MapKit's
    /// subtitle for the ranch is a name and a follower count. The card
    /// shows this sentence instead.
    static let cadillacRanchDescription =
        "Ten vintage Cadillacs stand buried nose-down in a wheat field west of Amarillo."

    static let cadillacRanchCoordinate = CLLocationCoordinate2D(
        latitude: 35.1872,
        longitude: -101.9870
    )

    /// The known sentence for a landmark, or nil for every other place.
    static func knownPlaceDescription(name: String?) -> String? {
        guard let name else { return nil }
        guard matchKey(name) == "cadillac ranch" else { return nil }
        return cadillacRanchDescription
    }

    private static let placeLabelFunctionWords: Set<String> = [
        "a", "an", "the", "of", "on", "in", "at", "for", "with", "and", "or",
        "to", "from", "by", "near",
    ]

    /// MapKit subtitles need a sentence ending as well as three words, so a
    /// street address or a category label is not treated as prose.
    static func isAppleMapsProse(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return false }
        return hasSentenceEnding(text)
    }

    /// Sentences split on `.` `!` and `?`. Periods in "St." and "Mt." stay
    /// inside the sentence they belong to.
    static func sentences(in text: String) -> [String] {
        let scalars = Array(text)
        guard !scalars.isEmpty else { return [] }
        var sentences: [String] = []
        var start = 0

        func append(from: Int, through: Int) {
            guard through >= from, through < scalars.count else { return }
            let startIndex = text.index(text.startIndex, offsetBy: from)
            let endIndex = text.index(text.startIndex, offsetBy: through + 1)
            let sentence = String(text[startIndex..<endIndex])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty { sentences.append(sentence) }
        }

        for index in scalars.indices {
            guard isSentenceEnding(scalars, at: index) else { continue }
            append(from: start, through: index)
            start = index + 1
            while start < scalars.count, scalars[start].isWhitespace {
                start += 1
            }
        }
        if start < scalars.count {
            append(from: start, through: scalars.count - 1)
        }
        return sentences
    }

    /// Prefix through the `limit`th real sentence ending. Fewer endings
    /// returns `text` unchanged. Periods in "St." and "Mt." do not count.
    static func firstSentences(in text: String, limit: Int) -> String {
        guard limit > 0 else { return text }
        let parts = sentences(in: text)
        guard parts.count > limit else { return text }
        return parts.prefix(limit).joined(separator: " ")
    }

    /// A subtitle that is only a phone number, including a leading "Phone"
    /// or "Tel" label and a trailing extension.
    static func isOnlyPhoneNumber(_ text: String) -> Bool {
        var working = text.lowercased()
        let labels = ["telephone", "phone", "tel", "mobile", "fax"]
        for label in labels {
            guard working.hasPrefix(label) else { continue }
            let after = working.index(working.startIndex, offsetBy: label.count)
            if after == working.endIndex || !working[after].isLetter {
                working = String(working[after...])
                break
            }
        }
        let digits = working.filter(\.isNumber)
        let letters = String(working.filter(\.isLetter))
        guard (7...15).contains(digits.count) else { return false }
        return letters.isEmpty || letters == "ext" || letters == "extension" || letters == "x"
    }

    /// A subtitle that is only a street, city, state, or ZIP. A sentence that
    /// merely mentions a road is not an address.
    static func isOnlyAddress(_ text: String) -> Bool {
        let tokens = addressTokens(in: text)
        guard !tokens.isEmpty else { return false }
        if tokens.contains(where: { proseVerbs.contains($0) }) { return false }

        let hasZip = tokens.contains(where: isZip)
        let hasSuffix = tokens.contains(where: { streetSuffixes.contains($0) })
        let hasState = containsState(tokens)
        let startsWithNumber = tokens[0].allSatisfy(\.isNumber)
        let hasComma = text.contains(",")
        let leftovers = tokens.filter { token in
            if token.allSatisfy(\.isNumber) || isZip(token) { return false }
            if streetSuffixes.contains(token) || stateAbbreviations.contains(token) { return false }
            if singleWordStates.contains(token) || addressFillers.contains(token) { return false }
            if multiWordStateTokens.contains(token), hasState { return false }
            return true
        }
        if startsWithNumber && hasSuffix && leftovers.count <= 2 { return true }
        if hasZip && (hasSuffix || hasState) && leftovers.count <= 4 { return true }
        if hasComma && hasState && leftovers.count <= 3 { return true }
        return false
    }

    /// The whole subtitle is a point-of-interest category or a common
    /// category label such as "Gas Station" or "Tourist Attraction".
    static func isBareCategory(_ text: String) -> Bool {
        let key = matchKey(text)
        guard !key.isEmpty else { return false }
        if categoryLabels.contains(key) { return true }
        if key.hasSuffix("s"), categoryLabels.contains(String(key.dropLast())) { return true }
        return false
    }

    /// A sentence whose words are only a call to action, such as "Book now"
    /// or "Reserve your table". A sentence that continues past the pitch stays.
    static func isPureCallToAction(_ sentence: String) -> Bool {
        let key = matchKey(sentence)
        if key.isEmpty { return false }
        if callToActionPhrases.contains(key) { return true }
        let words = key.split(separator: " ").map(String.init)
        guard (1...6).contains(words.count) else { return false }
        guard words.contains(where: { callToActionVerbs.contains($0) }) else { return false }
        return words.allSatisfy { callToActionLexicon.contains($0) }
    }

    // MARK: - HTML

    static func metaContent(in html: String, attribute: String, equals expected: String) -> String? {
        var rest = html[...]
        while let start = rest.range(of: "<meta", options: [.caseInsensitive]) {
            rest = rest[start.upperBound...]
            guard let close = rest.firstIndex(of: ">") else { return nil }
            let tag = rest[..<close]
            let after = rest.index(after: close)
            rest = after < rest.endIndex ? rest[after...] : rest[rest.endIndex...]
            let attrs = attributes(in: tag)
            let matches = attrs.contains { key, value in
                key.caseInsensitiveCompare(attribute) == .orderedSame
                    && value.caseInsensitiveCompare(expected) == .orderedSame
            }
            guard matches else { continue }
            guard let content = attrs.first(where: { $0.key.caseInsensitiveCompare("content") == .orderedSame })?.value else {
                continue
            }
            return content
        }
        return nil
    }

    static func jsonLDDescription(in html: String, placeName: String?) -> String? {
        var fallback: String?
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let found = descriptions(in: json, placeName: placeName)
            if let matched = found.matched { return matched }
            if fallback == nil { fallback = found.any }
        }
        return fallback
    }

    // MARK: - Private

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
    }

    private static let abbreviations: Set<String> = [
        "st", "rd", "ave", "blvd", "dr", "mt", "jr", "sr", "mr", "mrs", "ms",
        "inc", "ltd", "co", "no", "ft", "hwy", "us",
    ]

    /// iOS 17 `MKPointOfInterestCategory` values. Newer categories are listed
    /// by the name MapKit shows, so this file does not reference symbols that
    /// are unavailable at the deployment target.
    private static let pointOfInterestCategories: [MKPointOfInterestCategory] = [
        .airport, .amusementPark, .aquarium, .atm, .bakery, .bank, .beach,
        .brewery, .cafe, .campground, .carRental, .evCharger, .fireStation,
        .fitnessCenter, .foodMarket, .gasStation, .hospital, .hotel, .laundry,
        .library, .marina, .movieTheater, .museum, .nationalPark, .nightlife,
        .park, .parking, .pharmacy, .police, .postOffice, .publicTransport,
        .restaurant, .restroom, .school, .stadium, .store, .theater,
        .university, .winery, .zoo,
    ]

    private static let commonCategoryLabels: Set<String> = [
        "tourist attraction", "point of interest", "scenic", "sights",
        "attraction", "coffee", "coffee shop", "gas", "fuel", "lodging",
        "motel", "inn", "bar", "fast food", "grocery", "convenience store",
        "rest area", "shopping", "food", "shopping center", "historic site",
        "historical landmark", "landmark", "viewpoint", "scenic view",
        "visitor center", "music venue", "national monument", "distillery",
        "automotive repair", "convention center", "rv park", "skate park",
        "mini golf", "rock climbing", "go kart",
    ]

    private static let categoryLabels: Set<String> = {
        var labels = commonCategoryLabels
        for category in pointOfInterestCategories {
            let spaced = spacedCategoryName(category.rawValue)
            labels.insert(spaced)
            labels.insert(category.rawValue.lowercased())
        }
        return labels
    }()

    private static let streetSuffixes: Set<String> = [
        "st", "street", "rd", "road", "ave", "avenue", "blvd", "boulevard",
        "dr", "drive", "ln", "lane", "ct", "court", "hwy", "highway",
        "way", "pkwy", "parkway", "trl", "trail", "cir", "circle",
        "pl", "place", "ter", "terrace", "loop", "rte", "route",
        "aly", "alley", "sq", "square",
    ]

    private static let addressFillers: Set<String> = [
        "n", "s", "e", "w", "ne", "nw", "se", "sw",
        "north", "south", "east", "west",
        "suite", "ste", "apt", "apartment", "unit", "floor", "fl",
        "po", "box", "bldg", "building", "the", "a", "an", "of", "and", "at",
    ]

    private static let stateAbbreviations: Set<String> = [
        "al", "ak", "az", "ar", "ca", "co", "ct", "de", "dc", "fl", "ga",
        "hi", "id", "il", "in", "ia", "ks", "ky", "la", "me", "md", "ma",
        "mi", "mn", "ms", "mo", "mt", "ne", "nv", "nh", "nj", "nm", "ny",
        "nc", "nd", "oh", "ok", "or", "pa", "ri", "sc", "sd", "tn", "tx",
        "ut", "vt", "va", "wa", "wv", "wi", "wy",
    ]

    private static let singleWordStates: Set<String> = [
        "alabama", "alaska", "arizona", "arkansas", "california", "colorado",
        "connecticut", "delaware", "florida", "georgia", "hawaii", "idaho",
        "illinois", "indiana", "iowa", "kansas", "kentucky", "louisiana",
        "maine", "maryland", "massachusetts", "michigan", "minnesota",
        "mississippi", "missouri", "montana", "nebraska", "nevada", "ohio",
        "oklahoma", "oregon", "pennsylvania", "tennessee", "texas", "utah",
        "vermont", "virginia", "washington", "wisconsin", "wyoming",
    ]

    private static let multiWordStates: [String] = [
        "new hampshire", "new jersey", "new mexico", "new york",
        "north carolina", "north dakota", "south carolina", "south dakota",
        "west virginia", "rhode island", "district of columbia",
    ]

    private static let multiWordStateTokens: Set<String> = [
        "new", "hampshire", "jersey", "mexico", "york", "north", "south",
        "carolina", "dakota", "west", "virginia", "rhode", "island",
        "district", "columbia",
    ]

    private static let proseVerbs: Set<String> = [
        "is", "are", "was", "were", "be", "been", "being",
        "has", "have", "had", "sits", "sit", "overlooks", "offers", "offer",
        "features", "feature", "built", "opens", "opened", "closed", "closes",
        "crosses", "follows", "starts", "climbs", "faces", "includes",
        "remains", "runs", "winds", "cuts", "spans", "stands", "lies",
        "marks", "holds", "shows", "looks", "made", "makes", "serves",
        "provides", "covers", "rises", "flows", "meets", "joins", "leads",
        "turns", "continues", "welcomes", "houses", "contains", "forms",
        "dates", "began", "begins", "named", "called", "known", "keeps",
        "kept", "found", "finds", "sees", "saw",
    ]

    private static let callToActionVerbs: Set<String> = [
        "book", "call", "order", "reserve", "shop", "buy", "click",
        "subscribe", "follow", "download", "sign", "learn", "read",
        "contact", "view",
    ]

    private static let callToActionPhrases: Set<String> = [
        "book now", "book today", "book online", "book your stay",
        "book your visit", "book a table", "book your table",
        "call now", "call today", "call us", "call us today",
        "order now", "order online", "order today", "order ahead",
        "reserve now", "reserve today", "reserve your table", "reserve a table",
        "shop now", "shop online", "shop today",
        "buy now", "buy today", "buy tickets",
        "learn more", "read more", "click here", "sign up", "subscribe",
        "get tickets", "contact us", "contact us today",
        "view menu", "see menu", "download the app", "join now",
        "add to cart", "start now", "try now", "follow us",
        "visit our website", "visit our site",
    ]

    private static let callToActionLexicon: Set<String> = [
        "book", "call", "order", "reserve", "shop", "buy", "click",
        "subscribe", "follow", "download", "sign", "learn", "read",
        "contact", "view", "see", "get", "add", "join", "start", "try",
        "visit", "now", "today", "online", "us", "your", "you", "a", "an",
        "the", "table", "stay", "ticket", "tickets", "more", "here", "our",
        "website", "site", "menu", "app", "ahead", "reservation",
        "reservations", "to", "for", "up", "in", "please", "this", "free",
        "cart",
    ]

    private static func spacedCategoryName(_ raw: String) -> String {
        let prefix = "MKPOICategory"
        let body = raw.hasPrefix(prefix) ? String(raw.dropFirst(prefix.count)) : raw
        var words: [String] = []
        var current = ""
        let characters = Array(body)
        for index in characters.indices {
            let character = characters[index]
            if !current.isEmpty, character.isUppercase {
                let previous = characters[index - 1]
                let nextIsLower = index + 1 < characters.count && characters[index + 1].isLowercase
                if nextIsLower || !previous.isUppercase {
                    words.append(current)
                    current = ""
                }
            }
            current.append(character)
        }
        if !current.isEmpty { words.append(current) }
        return words.joined(separator: " ").lowercased()
    }

    private static func matchKey(_ text: String) -> String {
        let filtered = text.lowercased().filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
        return filtered.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func addressTokens(in text: String) -> [String] {
        let edge = CharacterSet.punctuationCharacters.subtracting(CharacterSet(charactersIn: "-"))
        return text.lowercased()
            .split { $0.isWhitespace || $0 == "," }
            .map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty }
    }

    private static func isZip(_ token: String) -> Bool {
        let parts = token.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 1 {
            return parts[0].count == 5 && parts[0].allSatisfy(\.isNumber)
        }
        guard parts.count == 2 else { return false }
        return parts[0].count == 5 && parts[1].count == 4
            && parts[0].allSatisfy(\.isNumber) && parts[1].allSatisfy(\.isNumber)
    }

    private static func containsState(_ tokens: [String]) -> Bool {
        if tokens.contains(where: { stateAbbreviations.contains($0) || singleWordStates.contains($0) }) {
            return true
        }
        let joined = tokens.joined(separator: " ")
        return multiWordStates.contains { phrase in
            joined == phrase
                || joined.hasPrefix(phrase + " ")
                || joined.hasSuffix(" " + phrase)
                || joined.contains(" " + phrase + " ")
        }
    }

    static func hasSentenceEnding(_ text: String) -> Bool {
        let scalars = Array(text)
        return scalars.indices.contains { isSentenceEnding(scalars, at: $0) }
    }

    /// A `.`, `!`, or `?` that closes a sentence. A period after "St." or
    /// "Mt." does not, and neither does a one-letter initial.
    private static func isSentenceEnding(_ scalars: [Character], at index: Int) -> Bool {
        let character = scalars[index]
        guard character == "." || character == "!" || character == "?" else { return false }
        if character == "." {
            let word = wordImmediatelyBefore(scalars, index: index).lowercased()
            if word.isEmpty || word.count <= 1 || abbreviations.contains(word) { return false }
        }
        let next = index + 1
        if next == scalars.count { return true }
        return scalars[next].isWhitespace || scalars[next] == "\"" || scalars[next] == "”"
    }

    private static func wordImmediatelyBefore(_ scalars: [Character], index: Int) -> String {
        var cursor = index
        var letters: [Character] = []
        while cursor > 0 {
            let previous = scalars[cursor - 1]
            if previous.isLetter {
                letters.append(previous)
                cursor -= 1
            } else {
                break
            }
        }
        return String(letters.reversed())
    }

    private static func attributes(in tag: Substring) -> [(key: String, value: String)] {
        var attrs: [(key: String, value: String)] = []
        var index = tag.startIndex

        func skipSeparators() {
            while index < tag.endIndex {
                let character = tag[index]
                if character.isWhitespace || character == "/" {
                    index = tag.index(after: index)
                } else {
                    break
                }
            }
        }

        while index < tag.endIndex {
            skipSeparators()
            guard index < tag.endIndex else { break }
            let keyStart = index
            while index < tag.endIndex {
                let character = tag[index]
                if character.isLetter || character == "-" || character == ":" {
                    index = tag.index(after: index)
                } else {
                    break
                }
            }
            guard index > keyStart else { break }
            let key = String(tag[keyStart..<index])
            skipSeparators()
            guard index < tag.endIndex, tag[index] == "=" else { break }
            index = tag.index(after: index)
            skipSeparators()
            guard index < tag.endIndex else { break }
            let quote = tag[index]
            if quote == "\"" || quote == "'" {
                index = tag.index(after: index)
                let valueStart = index
                while index < tag.endIndex, tag[index] != quote {
                    index = tag.index(after: index)
                }
                attrs.append((key, String(tag[valueStart..<index])))
                if index < tag.endIndex { index = tag.index(after: index) }
            } else {
                let valueStart = index
                while index < tag.endIndex, !tag[index].isWhitespace, tag[index] != "/" {
                    index = tag.index(after: index)
                }
                attrs.append((key, String(tag[valueStart..<index])))
            }
        }
        return attrs
    }

    private static func jsonLDBlocks(in html: String) -> [String] {
        var blocks: [String] = []
        var rest = html[...]
        while let open = rest.range(of: "<script", options: [.caseInsensitive]) {
            rest = rest[open.lowerBound...]
            guard let tagEnd = rest[rest.startIndex...].firstIndex(of: ">") else { break }
            let openTag = rest[..<tagEnd]
            let contentStart = rest.index(after: tagEnd)
            guard contentStart <= rest.endIndex,
                  let close = rest.range(of: "</script", options: [.caseInsensitive], range: contentStart..<rest.endIndex) else {
                break
            }
            if String(openTag).range(of: "ld+json", options: [.caseInsensitive]) != nil {
                blocks.append(String(rest[contentStart..<close.lowerBound]))
            }
            rest = rest[close.upperBound...]
        }
        return blocks
    }

    private static func descriptions(in value: Any, placeName: String?) -> (matched: String?, any: String?) {
        switch value {
        case let array as [Any]:
            var matched: String?
            var any: String?
            for item in array {
                let found = descriptions(in: item, placeName: placeName)
                if matched == nil { matched = found.matched }
                if any == nil { any = found.any }
            }
            return (matched, any)
        case let object as [String: Any]:
            let objectName = object["name"] as? String
            let raw = object["description"] as? String
            let accepted = acceptedPlaceText(raw, name: placeName)
            var matched: String?
            if let accepted, let placeName, let objectName, same(objectName, placeName) {
                matched = accepted
            }
            var any = accepted
            if let graph = object["@graph"] {
                let nested = descriptions(in: graph, placeName: placeName)
                if matched == nil { matched = nested.matched }
                if any == nil { any = nested.any }
            }
            return (matched, any)
        default:
            return (nil, nil)
        }
    }

    private static func decodeHTML(_ raw: String) -> String {
        var text = raw
        let named: [(String, String)] = [
            ("&quot;", "\""),
            ("&apos;", "'"),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&lt;", "<"),
            ("&gt;", ">"),
        ]
        for (entity, replacement) in named {
            text = text.replacingOccurrences(of: entity, with: replacement, options: [.caseInsensitive])
        }
        text = decodeNumericEntities(text)
        return text.replacingOccurrences(of: "&amp;", with: "&", options: [.caseInsensitive])
    }

    private static func decodeNumericEntities(_ raw: String) -> String {
        var result = ""
        var rest = raw[...]
        while let amp = rest.firstIndex(of: "&") {
            result.append(contentsOf: rest[..<amp])
            guard let entity = numericEntity(in: rest[amp...]) else {
                result.append("&")
                let next = rest.index(after: amp)
                rest = next < rest.endIndex ? rest[next...] : rest[rest.endIndex...]
                continue
            }
            result.append(entity.character)
            rest = rest[entity.next...]
        }
        result.append(contentsOf: rest)
        return result
    }

    private static func numericEntity(in slice: Substring) -> (character: Character, next: String.Index)? {
        var index = slice.startIndex
        guard index < slice.endIndex, slice[index] == "&" else { return nil }
        index = slice.index(after: index)
        guard index < slice.endIndex, slice[index] == "#" else { return nil }
        index = slice.index(after: index)
        guard index < slice.endIndex else { return nil }
        let hex = slice[index] == "x" || slice[index] == "X"
        if hex { index = slice.index(after: index) }
        let digitsStart = index
        while index < slice.endIndex {
            let character = slice[index]
            let isDigit = hex ? character.isHexDigit : character.isNumber
            if !isDigit { break }
            index = slice.index(after: index)
        }
        guard index > digitsStart, index < slice.endIndex, slice[index] == ";" else { return nil }
        let digits = String(slice[digitsStart..<index])
        let value = hex ? UInt32(digits, radix: 16) : UInt32(digits, radix: 10)
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return (Character(scalar), slice.index(after: index))
    }

    /// Drops `<tag>` markup. A bare `<` in prose (for example "3 < 4") stays.
    private static func stripTags(_ text: String) -> String {
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "<" {
                let next = text.index(after: index)
                if next < text.endIndex, text[next].isLetter || text[next] == "/",
                   let afterTag = endOfTag(in: text, from: next) {
                    index = afterTag
                    continue
                }
            }
            result.append(text[index])
            index = text.index(after: index)
        }
        return result
    }

    /// Index just after `>` when `from` sits on the first character inside a tag.
    private static func endOfTag(in text: String, from: String.Index) -> String.Index? {
        var cursor = from
        while cursor < text.endIndex {
            if text[cursor] == ">" {
                return text.index(after: cursor)
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }
}

extension SuggestedStop {
    /// Copies the stop with a published description. Blank text clears it.
    /// The id stays put so the list row does not jump.
    func withPlaceDescription(_ text: String?) -> SuggestedStop {
        var copy = self
        copy.placeDescription = PlaceDescriptionDisplay.text(for: text, name: name)
        return copy
    }

    /// Facts the description loader can use off the main actor.
    @MainActor
    func placeDescriptionQuery() -> PlaceDescriptionQuery {
        PlaceDescriptionQuery(
            id: id,
            name: mapItem.name,
            appleMapsCandidate: mapItem.placemark.subtitle,
            rejectIfEqual: PlaceDescriptionReader.addressRejects(from: mapItem),
            websiteURL: mapItem.url
        )
    }
}

/// Resolves one description per place. Apple Maps prose wins when it exists.
/// Otherwise the place's own HTTPS page is read. Neither source yields text
/// → nil. This type does not write copy.
enum PlaceDescriptionLoader {
    static func resolve(_ queries: [PlaceDescriptionQuery]) async -> [UUID: String] {
        await withTaskGroup(of: (UUID, String?).self) { group in
            for query in queries {
                group.addTask {
                    let text = await text(for: query)
                    return (query.id, text)
                }
            }
            var resolved: [UUID: String] = [:]
            for await (id, text) in group {
                if let text {
                    resolved[id] = text
                }
            }
            return resolved
        }
    }

    static func text(for query: PlaceDescriptionQuery) async -> String? {
        await text(for: query) { url in
            await PlacePageCache.shared.page(for: url)
        }
    }

    /// `page` returns the document at a place URL. Tests pass a stub so the
    /// no-description path never touches the network.
    static func text(
        for query: PlaceDescriptionQuery,
        page: @escaping @Sendable (URL) async -> String?
    ) async -> String? {
        if let apple = PlaceDescriptionReader.acceptedAppleMapsText(
            query.appleMapsCandidate,
            name: query.name,
            rejectIfEqual: query.rejectIfEqual
        ) {
            return apple
        }
        guard let url = query.websiteURL, PlaceDescriptionReader.isPlaceWebsite(url) else { return nil }
        guard let document = await page(url) else { return nil }
        return PlaceDescriptionReader.placeText(from: document, name: query.name)
    }
}

/// Remembers one fetch per place URL. A stored nil means the page had no
/// description, so a replan does not download it again.
private actor PlacePageCache {
    static let shared = PlacePageCache()

    private struct Entry: Sendable {
        var value: String?
    }

    private var pages: [URL: Entry] = [:]

    func page(for url: URL) async -> String? {
        if let entry = pages[url] {
            return entry.value
        }
        let fetched = await Self.download(url)
        if let entry = pages[url] {
            return entry.value
        }
        pages[url] = Entry(value: fetched)
        return fetched
    }

    private nonisolated static func download(_ url: URL) async -> String? {
        guard PlaceDescriptionReader.isPlaceWebsite(url) else { return nil }
        let request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 8)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let prefix = data.prefix(400_000)
            return String(data: prefix, encoding: .utf8)
                ?? String(data: prefix, encoding: .isoLatin1)
        } catch {
            return nil
        }
    }
}
