import Foundation
import MapKit

/// Collapsed cards show two lines. The sheet shows this same string in full.
///
/// Apple Maps place objects expose a name, address, category, phone, and URL.
/// A card shows text only when MapKit already stored a sentence, or when the
/// place's own page published a description. Nothing is written to fill a gap.
enum PlaceDescriptionDisplay {
    static let collapsedLineLimit = 2

    /// Blank input is "no description". Non-blank input is returned unchanged
    /// aside from trimming and collapsing whitespace.
    static func text(for description: String?) -> String? {
        PlaceDescriptionReader.normalize(description)
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
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !cityLine.isEmpty { rejects.append(cityLine) }
        return rejects
    }

    /// Accepts a MapKit string only when it is already a sentence and it is
    /// not the place name or an address. Never builds a sentence from a
    /// category, a name, or a city.
    static func acceptedAppleMapsText(
        _ raw: String?,
        name: String?,
        rejectIfEqual rejects: [String]
    ) -> String? {
        guard let text = normalize(raw) else { return nil }
        if let name, same(text, name) { return nil }
        if rejects.contains(where: { candidate in
            guard let normalized = normalize(candidate) else { return false }
            return same(text, normalized)
        }) {
            return nil
        }
        guard isAppleMapsProse(text) else { return nil }
        return text
    }

    /// The place's own description fields, in the order the page publishes
    /// them: meta description, then Open Graph, then JSON-LD. Nil when the
    /// document has none.
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

    /// A place-published description. At least three words, and not just the name.
    static func acceptedPlaceText(_ raw: String?, name: String?) -> String? {
        guard let text = normalize(raw) else { return nil }
        if let name, same(text, name) { return nil }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return nil }
        return text
    }

    /// MapKit subtitles need a sentence ending as well as three words, so a
    /// street address or a category label is not treated as prose.
    static func isAppleMapsProse(_ text: String) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace)
        guard words.count >= 3 else { return false }
        return hasSentenceEnding(text)
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

    static func hasSentenceEnding(_ text: String) -> Bool {
        let scalars = Array(text)
        for index in scalars.indices {
            let character = scalars[index]
            guard character == "." || character == "!" || character == "?" else { continue }
            if character == "." {
                let word = wordImmediatelyBefore(scalars, index: index).lowercased()
                if word.isEmpty || word.count <= 1 || abbreviations.contains(word) { continue }
            }
            let next = index + 1
            if next == scalars.count { return true }
            if scalars[next].isWhitespace || scalars[next] == "\"" || scalars[next] == "”" { return true }
        }
        return false
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
        copy.placeDescription = PlaceDescriptionReader.normalize(text)
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
