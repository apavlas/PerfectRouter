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
///
/// A description is shown only when it is about that exact place. Text whose
/// source record, page title, or domain names a different place is dropped.
/// Review-site filler (review counts, photo counts, star ratings, truncated
/// quotes) is not a description either. Neither check removes the place.
enum PlaceDescriptionDisplay {
    static let collapsedLineLimit = 2
    static let rowSentenceLimit = 2

    /// The description the row and the sheet share: normalized, then cut
    /// after the second sentence. "St." and "Mt." are not endings. Blank
    /// input and a shorter source stay nil or whole. A name-and-city
    /// restatement is removed first; text about a different place is not shown.
    static func text(for description: String?, name: String? = nil) -> String? {
        guard let text = PlaceDescriptionReader.normalize(description) else { return nil }
        if PlaceDescriptionReader.isReviewSiteFiller(text) { return nil }
        guard let social = PlaceDescriptionReader.droppingSocialEngagementSentences(in: text) else {
            return nil
        }
        guard let restated = PlaceDescriptionReader.strippingRestatedNameAndLocality(in: social, name: name),
              let prose = PlaceDescriptionReader.droppingListingFillerSentences(in: restated, name: name) else {
            return nil
        }
        if PlaceDescriptionReader.namesADifferentPlace(prose, placeName: name) { return nil }
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
        if isReviewSiteFiller(text) { return nil }
        if isOnlyPhoneNumber(text) || isBareCategory(text) || isOnlyAddress(text) { return nil }
        guard let social = droppingSocialEngagementSentences(in: text) else { return nil }
        guard let restated = strippingRestatedNameAndLocality(in: social, name: name),
              let prose = droppingListingFillerSentences(in: restated, name: name) else { return nil }
        if namesADifferentPlace(prose, placeName: name) { return nil }
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
    ///
    /// When `pageURL` or a page title is present, the page has to identify
    /// this place (domain or title). A title that names a different landmark
    /// contributes nothing. Callers that only have a document and a name skip
    /// that check; JSON-LD still requires the record's name to match.
    static func placeText(from document: String, name: String?, pageURL: URL? = nil) -> String? {
        let titles = pageTitles(in: document)
        if titles.contains(where: { namesADifferentPlace($0, placeName: name) }) {
            return nil
        }
        if pageURL != nil || !titles.isEmpty {
            guard websiteIdentifiesPlace(url: pageURL, titles: titles, placeName: name) else {
                return nil
            }
        }
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

    /// The passage a `#:~:text=start[,end]` link marks on the page, when it
    /// names this place and survives the same filters as any description.
    /// Nil when the link has no text fragment, the passage is not on the
    /// page, or it does not name the place. Runs on the loader, off the
    /// main actor.
    static func textFragmentPassage(in document: String, url: URL, name: String?) -> String? {
        guard let (start, end) = textFragment(of: url), !canonicalPlaceName(name).isEmpty else { return nil }
        guard let body = normalize(document),
              let startRange = body.range(of: start, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return nil
        }
        let tail = body[startRange.lowerBound...].prefix(800)
        var passage = String(tail)
        if let end, let endRange = passage.range(of: end, options: [.caseInsensitive, .diacriticInsensitive]) {
            passage = String(passage[..<endRange.upperBound])
        } else {
            passage = firstSentences(in: passage, limit: 1)
        }
        guard containsPlaceName(passage, placeName: name) else { return nil }
        return acceptedPlaceText(passage, name: name)
    }

    /// `textStart` and optional `textEnd` from the first `text=` directive of
    /// a URL text fragment (`#:~:text=[prefix-,]start[,end][,-suffix]`).
    static func textFragment(of url: URL) -> (start: String, end: String?)? {
        guard let fragment = url.fragment(percentEncoded: true),
              let marker = fragment.range(of: ":~:") else { return nil }
        let directives = fragment[marker.upperBound...].split(separator: "&")
        guard let text = directives.first(where: { $0.hasPrefix("text=") }) else { return nil }
        var parts = text.dropFirst("text=".count)
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0) }
        if let first = parts.first, first.hasSuffix("-") { parts.removeFirst() }
        if let last = parts.last, last.hasPrefix("-") { parts.removeLast() }
        let decoded = parts.compactMap { $0.removingPercentEncoding?.trimmingCharacters(in: .whitespaces) }
        guard let start = decoded.first, start.count >= 8 else { return nil }
        let end = decoded.count > 1 ? decoded[1] : nil
        return (start, end?.isEmpty == true ? nil : end)
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
        if isReviewSiteFiller(text) { return nil }
        guard let social = droppingSocialEngagementSentences(in: text) else { return nil }
        guard let restated = strippingRestatedNameAndLocality(in: social, name: name),
              let prose = droppingListingFillerSentences(in: restated, name: name) else { return nil }
        if namesADifferentPlace(prose, placeName: name) { return nil }
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

    /// Yelp, Tripadvisor, and Google listing chrome is not a description.
    /// A review count, a photo count, a star rating, or a truncated quoted
    /// snippet blanks the whole string. The place row stays; it just has
    /// no description. Real prose that never uses those markers stays.
    static func isReviewSiteFiller(_ text: String) -> Bool {
        if text.contains("★") || text.contains("☆") || text.contains("⭐") || text.contains("✩") {
            return true
        }
        if hasTruncatedQuotation(text) { return true }
        let tokens = matchKey(text).split(separator: " ").map(String.init)
        if tokens.contains(where: { reviewSiteBrands.contains($0) }) { return true }
        if matchKey(text).contains("google reviews") { return true }
        if hasCountedWord(tokens, words: ["review", "reviews"]) { return true }
        if hasCountedWord(tokens, words: ["photo", "photos"]) { return true }
        if hasCountedWord(tokens, words: ["star", "stars", "rating", "ratings"]) { return true }
        return hasRatedScore(tokens)
    }

    /// "1 review" and "3 photos", including a number glued on as "5star".
    /// The number may sit on either side of the word. "a review in the book"
    /// has no count and is not filler.
    private static func hasCountedWord(_ tokens: [String], words: [String]) -> Bool {
        let keys = Set(words)
        for index in tokens.indices {
            let token = tokens[index]
            let numberedStar = isNumberedStar(token)
            guard keys.contains(token) || numberedStar else { continue }
            if numberedStar { return true }
            if index > 0, isCountToken(tokens[index - 1]) { return true }
            if index + 1 < tokens.count, isCountToken(tokens[index + 1]) { return true }
        }
        return false
    }

    private static func isCountToken(_ token: String) -> Bool {
        !token.isEmpty && token.allSatisfy(\.isNumber)
    }

    /// "5star" / "5stars" after a hyphen is stripped. "superstar" is not.
    private static func isNumberedStar(_ token: String) -> Bool {
        let suffix = token.hasSuffix("stars") ? "stars" : (token.hasSuffix("star") ? "star" : nil)
        guard let suffix else { return false }
        let prefix = token.dropLast(suffix.count)
        return !prefix.isEmpty && prefix.allSatisfy(\.isNumber)
    }

    /// "rated 4.5" or "rating 5" after the decimal point is stripped.
    private static func hasRatedScore(_ tokens: [String]) -> Bool {
        guard tokens.count >= 2 else { return false }
        for index in 0..<(tokens.count - 1) {
            let token = tokens[index]
            guard token == "rated" || token == "rating" else { continue }
            if isCountToken(tokens[index + 1]) { return true }
        }
        return false
    }

    /// A review snippet cut off with an ellipsis, not a finished quotation
    /// inside a real sentence.
    private static func hasTruncatedQuotation(_ text: String) -> Bool {
        let quotes: Set<Character> = ["\"", "“", "”", "«"]
        guard text.contains(where: { quotes.contains($0) }) else { return false }
        return text.contains("…") || text.contains("...")
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
    /// "The Cadillac Ranch" is the same place. No other ranch borrows this sentence.
    static func knownPlaceDescription(name: String?) -> String? {
        guard placeNamesMatch(name, "Cadillac Ranch") else { return nil }
        return cadillacRanchDescription
    }

    /// Landmarks whose names are distinctive enough to reject a mismatched card.
    /// Slug Bug Ranch and The Big Texan Steak Ranch share nothing but a region;
    /// a sentence that names one is not a description of the other.
    static let distinctivePlaceNames = [
        "Cadillac Ranch",
        "The Big Texan Steak Ranch",
        "Slug Bug Ranch",
    ]

    /// True when `text` names a known landmark that is not `placeName`.
    /// Comparison ignores case, punctuation, a leading "The", and "&" versus "and".
    /// Text that also names this place is kept.
    static func namesADifferentPlace(_ text: String, placeName: String?) -> Bool {
        let place = canonicalPlaceName(placeName)
        let haystack = " " + matchPhrase(text) + " "
        if !place.isEmpty, haystack.contains(" " + place + " ") { return false }
        for known in distinctivePlaceNames {
            let key = canonicalPlaceName(known)
            guard !key.isEmpty, key != place else { continue }
            if haystack.contains(" " + key + " ") { return true }
            // The landmark's signature detail without its name is still
            // that landmark: a 72 oz steak is not a sentence about a ranch
            // of buried Beetles. Only checked when the card's place is known.
            guard !place.isEmpty else { continue }
            for signature in landmarkSignatures[known, default: []] {
                if haystack.contains(" " + matchPhrase(signature) + " ") { return true }
            }
        }
        return false
    }

    /// Details that only one of `distinctivePlaceNames` has. Text carrying
    /// one of these on any other place is wrong-place text.
    static let landmarkSignatures: [String: [String]] = [
        "Cadillac Ranch": ["ten vintage cadillacs", "ten cadillacs", "10 cadillacs", "buried cadillacs"],
        "The Big Texan Steak Ranch": ["72oz", "72 oz", "72-ounce", "72 ounce", "steak challenge"],
        "Slug Bug Ranch": ["volkswagen beetles", "vw beetles", "buried beetles", "five beetles", "buried bugs"],
    ]

    /// A highlight's text that names another highlight on the same ride, and
    /// not itself, is about the other place. Only those descriptions are
    /// cleared; every stop stays in the list, in order.
    static func clearingCrossNamedDescriptions(_ stops: [SuggestedStop]) -> [SuggestedStop] {
        stops.map { stop in
            guard let text = stop.placeDescription else { return stop }
            if containsPlaceName(text, placeName: stop.name) { return stop }
            let namesSibling = stops.contains { other in
                other.id != stop.id
                    && !placeNamesMatch(other.name, stop.name)
                    && canonicalPlaceName(other.name).split(separator: " ").count >= 2
                    && containsPlaceName(text, placeName: other.name)
            }
            guard namesSibling else { return stop }
            var copy = stop
            copy.placeDescription = nil
            return copy
        }
    }

    // MARK: - Listing filler and location-only restatements

    /// Drops sentences that only say where the place is ("Slug Bug Ranch is
    /// located in Conway, Texas."), greet ("Welcome to Slug Bug Ranch!"),
    /// pitch ("Plan your visit today!"), or are listing chrome ("Read reviews,
    /// see photos and get directions.", "Open 24 hours."). Real prose around
    /// them stays. Nil when nothing is left.
    static func droppingListingFillerSentences(in text: String, name: String?) -> String? {
        let parts = sentences(in: text)
        guard !parts.isEmpty else { return nil }
        let kept = parts.filter { sentence in
            !isLocationOnlySentence(sentence, name: name)
                && !isListingChromeSentence(sentence)
                && !isPureCallToAction(removingPlaceName(from: sentence, name: name))
        }
        guard !kept.isEmpty else { return nil }
        if kept.count == parts.count { return text }
        return normalize(kept.joined(separator: " "))
    }

    /// A sentence whose words, once the place name is removed, are only
    /// location words: prepositions, "is located", category labels, a city
    /// (a capitalized word that is not the sentence opener), a state, a ZIP,
    /// a street, or an exit. Any ordinary lowercase word, or a capitalized
    /// opener that is not filler ("Ten vintage Cadillacs…"), keeps it.
    static func isLocationOnlySentence(_ sentence: String, name: String?) -> Bool {
        let edge = CharacterSet.punctuationCharacters
            .union(.symbols)
            .subtracting(CharacterSet(charactersIn: "-"))
        var words = sentence
            .split { $0.isWhitespace || $0 == "," || $0 == "|" || $0 == "·" }
            .map { $0.trimmingCharacters(in: edge) }
            .filter { !$0.isEmpty && $0 != "-" }
        guard !words.isEmpty else { return false }
        var removedName = false
        let nameWords = canonicalPlaceName(name).split(separator: " ").map(String.init)
        if !nameWords.isEmpty, words.count >= nameWords.count {
            let keys = words.map { matchPhrase($0) }
            for start in 0...(words.count - nameWords.count) {
                if Array(keys[start..<(start + nameWords.count)]) == nameWords {
                    var lower = start
                    if lower > 0, keys[lower - 1] == "the" { lower -= 1 }
                    words.removeSubrange(lower..<(start + nameWords.count))
                    removedName = true
                    break
                }
            }
        }
        if words.isEmpty { return removedName }
        var hasCue = false
        for (index, word) in words.enumerated() {
            let key = matchPhrase(word)
            if key.isEmpty { continue }
            if locationCueWords.contains(key) { hasCue = true; continue }
            if locationFillerWords.contains(key) || categoryWords.contains(key) { continue }
            if key.contains(where: \.isNumber) { hasCue = true; continue }
            if streetSuffixes.contains(key) || addressFillers.contains(key) { continue }
            if stateAbbreviations.contains(key) || singleWordStates.contains(key)
                || multiWordStateTokens.contains(key) {
                hasCue = true
                continue
            }
            let opensSentence = index == 0 && !removedName
            if !opensSentence, word.first?.isUppercase == true { continue }
            return false
        }
        return hasCue || removedName
    }

    /// Review-site and listing boilerplate. Phrases in the first list mark
    /// any sentence. The second list only marks a short sentence, so
    /// "Admission is free and the cars are repainted every week." stays.
    static func isListingChromeSentence(_ sentence: String) -> Bool {
        let key = " " + matchKey(sentence) + " "
        if listingChromePhrases.contains(where: { key.contains(" \($0) ") }) { return true }
        let words = key.split(separator: " ")
        guard words.count <= 5 else { return false }
        return shortListingChromePhrases.contains { key.contains(" \($0) ") }
    }

    private static func removingPlaceName(from sentence: String, name: String?) -> String {
        let place = canonicalPlaceName(name)
        guard !place.isEmpty else { return sentence }
        let phrase = " " + matchPhrase(sentence) + " "
        guard phrase.contains(" " + place + " ") else { return sentence }
        return phrase.replacingOccurrences(of: " " + place + " ", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let reviewSiteBrands: Set<String> = [
        "tripadvisor", "yelp", "foursquare", "yellowpages", "mapquest", "wanderlog",
    ]

    private static let listingChromePhrases: [String] = [
        "read reviews", "see reviews", "write a review", "see photos", "view photos",
        "get directions", "things to do", "what to do", "best places to",
        "places to see", "out of 5", "highly rated", "top rated", "toprated",
        "loved by", "rated by", "ranked no", "ranked number", "claim this business",
        "is this your business", "updated january", "updated february", "updated march",
        "updated april", "updated may", "updated june", "updated july", "updated august",
        "updated september", "updated october", "updated november", "updated december",
    ]

    private static let shortListingChromePhrases: [String] = [
        "open 24 hours", "open now", "closed now", "free admission", "free parking",
        "hours of operation", "opening hours", "open daily", "admission free",
        "free entry", "must see", "mustsee",
    ]

    private static let locationCueWords: Set<String> = [
        "in", "at", "near", "located", "situated", "outside", "off", "exit", "along",
        "downtown", "between",
    ]

    private static let locationFillerWords: Set<String> = [
        "the", "is", "are", "a", "an", "of", "on", "just", "right", "by", "and",
        "here", "there", "it", "its", "this", "you", "can", "be", "find", "found",
        "our", "from", "to", "welcome", "visit", "see", "explore", "discover",
        "minutes", "minute", "miles", "mile", "mi", "km", "interstate", "i",
        "us", "county", "city", "town", "area", "region", "panhandle", "today",
        "come", "stop", "your", "next", "trip", "plan",
    ]

    private static let categoryWords: Set<String> = [
        "tourist", "attraction", "attractions", "landmark", "landmarks", "roadside",
        "place", "places", "spot", "site", "destination", "point", "interest",
        "popular", "local", "historic", "historical", "famous", "iconic", "art",
        "installation", "museum", "park", "monument", "sight", "sights", "scenic",
        "viewpoint", "public", "sculpture", "oddity", "quirky", "unique", "classic",
        "great", "fun", "must", "see", "favorite", "well", "known", "wellknown",
    ]

    /// Same place after normalization. "The Filling Station" matches
    /// "Filling Station", and "Ben & Jerry's" matches "Ben and Jerry's".
    static func placeNamesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        let left = canonicalPlaceName(lhs)
        let right = canonicalPlaceName(rhs)
        return !left.isEmpty && left == right
    }

    /// Lowercased words with punctuation removed, a leading "The" dropped,
    /// and "&" read as "and".
    static func canonicalPlaceName(_ raw: String?) -> String {
        var words = matchPhrase(raw).split(separator: " ").map(String.init)
        if words.first == "the" { words.removeFirst() }
        return words.joined(separator: " ")
    }

    /// The page is this place's own page when its title or domain names the place.
    static func websiteIdentifiesPlace(url: URL?, titles: [String], placeName: String?) -> Bool {
        guard !canonicalPlaceName(placeName).isEmpty else { return false }
        if titles.contains(where: { containsPlaceName($0, placeName: placeName) }) {
            return true
        }
        if let url, domainMatchesPlace(url, placeName: placeName) {
            return true
        }
        return false
    }

    static func containsPlaceName(_ text: String, placeName: String?) -> Bool {
        let place = canonicalPlaceName(placeName)
        guard !place.isEmpty else { return false }
        return (" " + matchPhrase(text) + " ").contains(" " + place + " ")
    }

    /// Host labels such as `bigtexan` or `tallulahgorge` match the place when
    /// they equal the name, or a leading run of its words, with or without "the".
    static func domainMatchesPlace(_ url: URL, placeName: String?) -> Bool {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return false }
        let words = canonicalPlaceName(placeName).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let skipped: Set<String> = ["www", "com", "org", "net", "edu", "gov", "io", "co", "uk"]
        for part in host.split(separator: ".") {
            let label = String(part).replacingOccurrences(of: "-", with: "")
            guard label.count >= 4, !skipped.contains(label) else { continue }
            if domainLabel(label, matches: words) { return true }
        }
        return false
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

    /// JSON-LD description only when that object's name is this place.
    /// A different object's description is not a fallback.
    static func jsonLDDescription(in html: String, placeName: String?) -> String? {
        for block in jsonLDBlocks(in: html) {
            guard let data = block.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            if let matched = descriptions(in: json, placeName: placeName) {
                return matched
            }
        }
        return nil
    }

    /// `<title>` and `og:title`, normalized. Empty when the page names nothing.
    static func pageTitles(in html: String) -> [String] {
        var titles: [String] = []
        if let openGraph = metaContent(in: html, attribute: "property", equals: "og:title"),
           let text = normalize(openGraph) {
            titles.append(text)
        }
        if let text = titleElement(in: html) {
            titles.append(text)
        }
        return titles
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

    /// Description from a JSON-LD object whose name is this place. An object
    /// named for somewhere else is skipped, including the first one on the page.
    private static func descriptions(in value: Any, placeName: String?) -> String? {
        switch value {
        case let array as [Any]:
            for item in array {
                if let found = descriptions(in: item, placeName: placeName) {
                    return found
                }
            }
            return nil
        case let object as [String: Any]:
            if let placeName,
               let objectName = object["name"] as? String,
               placeNamesMatch(objectName, placeName),
               let raw = object["description"] as? String,
               let accepted = acceptedPlaceText(raw, name: placeName) {
                return accepted
            }
            if let graph = object["@graph"] {
                return descriptions(in: graph, placeName: placeName)
            }
            return nil
        default:
            return nil
        }
    }

    /// Letters, numbers, and whitespace. "&" becomes "and". Apostrophes are
    /// removed so "Jerry's" and "Jerrys" share a key. Other punctuation becomes space.
    private static func matchPhrase(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var expanded = ""
        expanded.reserveCapacity(raw.count)
        for character in raw.lowercased() {
            if character == "&" {
                expanded.append(" and ")
            } else if isApostrophe(character) {
                continue
            } else if character.isLetter || character.isNumber || character.isWhitespace {
                expanded.append(character)
            } else {
                expanded.append(" ")
            }
        }
        return expanded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isApostrophe(_ character: Character) -> Bool {
        character == "'" || character == "\u{2019}" || character == "\u{02BC}"
    }

    /// `bigtexan` matches "The Big Texan Steak Ranch" because "big" + "texan"
    /// is a leading run of the place's words. A label for a different place does not.
    private static func domainLabel(_ label: String, matches words: [String]) -> Bool {
        let collapsed = words.joined()
        if label == collapsed || label == "the" + collapsed { return true }
        var built = ""
        var withThe = "the"
        for word in words {
            built += word
            withThe += word
            if built == label || withThe == label { return true }
            if built.count > label.count && withThe.count > label.count { break }
        }
        return false
    }

    private static func titleElement(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: [.caseInsensitive]) else { return nil }
        guard let start = html[open.upperBound...].firstIndex(of: ">") else { return nil }
        let contentStart = html.index(after: start)
        guard contentStart < html.endIndex,
              let close = html.range(
                of: "</title",
                options: [.caseInsensitive],
                range: contentStart..<html.endIndex
              ) else { return nil }
        return normalize(String(html[contentStart..<close.lowerBound]))
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

/// Resolves one description per place. Apple Maps prose wins when it exists
/// and it is about this place. Otherwise the place's own HTTPS page is read,
/// and only when that page's domain or title names the place. Neither source
/// yields text → nil. This type does not write copy.
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
        // Apple's link can point at the passage about this place on a
        // shared page (Slug Bug Ranch lives on bigtexan.com). That passage
        // wins over the page's own meta text, which describes the host.
        if let passage = PlaceDescriptionReader.textFragmentPassage(in: document, url: url, name: query.name) {
            return passage
        }
        return PlaceDescriptionReader.placeText(from: document, name: query.name, pageURL: url)
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
