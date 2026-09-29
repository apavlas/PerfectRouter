import Foundation
import CoreLocation

/// Encodes and decodes GPS Exchange Format (GPX 1.1) snapshots of a planned
/// ride. Export always writes plan stops as `<wpt>`; when a route polyline is
/// available it also writes a `<trk>`. Import maps `<wpt>` (falling back to
/// track start/end) into waypoints the planner can route.
enum GPXCodec {

    /// A decoded GPX document: named waypoints plus an optional track line.
    struct Document {
        var name: String?
        var waypoints: [Waypoint]
        /// Flattened track points when the file contained a `<trk>`, else empty.
        var trackCoordinates: [CLLocationCoordinate2D]
    }

    enum DecodeError: Error, Equatable {
        case empty
        case notGPX
        case noCoordinates
    }

    // MARK: - Filename

    /// `PerfectRouter-YYYYMMDD-HHmm.gpx` in the local calendar.
    static func suggestedFilename(date: Date = Date(),
                                  calendar: Calendar = .current,
                                  timeZone: TimeZone = .current) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let parts = cal.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: date
        )
        let y = parts.year ?? 0
        let mo = parts.month ?? 0
        let d = parts.day ?? 0
        let h = parts.hour ?? 0
        let mi = parts.minute ?? 0
        return String(format: "PerfectRouter-%04d%02d%02d-%02d%02d.gpx", y, mo, d, h, mi)
    }

    // MARK: - Encode

    /// Builds a GPX 1.1 document for the given plan stops.
    /// - Parameters:
    ///   - waypoints: Plan stops (start, vias, destination). Written as `<wpt>`.
    ///   - trackCoordinates: Optional route polyline. When non-empty, written
    ///     as a single `<trk>` / `<trkseg>`. Callers that have no polyline yet
    ///     pass `[]` for a waypoints-only file.
    ///   - name: Optional `<metadata><name>` (and track name).
    ///   - date: Timestamp written into `<metadata><time>` (UTC).
    static func encode(waypoints: [Waypoint],
                       trackCoordinates: [CLLocationCoordinate2D] = [],
                       name: String? = nil,
                       date: Date = Date()) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="PerfectRouter" xmlns="http://www.topografix.com/GPX/1/1">

        """
        xml += "  <metadata>\n"
        if let name, !name.isEmpty {
            xml += "    <name>\(escape(name))</name>\n"
        }
        xml += "    <time>\(iso8601UTC(date))</time>\n"
        xml += "  </metadata>\n"

        for waypoint in waypoints {
            let coord = waypoint.coordinate
            guard coord.isValidLocation else { continue }
            xml += """
              <wpt lat="\(coord.latitude)" lon="\(coord.longitude)">
                <name>\(escape(waypoint.name))</name>
              </wpt>

            """
        }

        let track = trackCoordinates.filter(\.isValidLocation)
        if !track.isEmpty {
            let trackName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Route"
            xml += "  <trk>\n"
            xml += "    <name>\(escape(trackName))</name>\n"
            xml += "    <trkseg>\n"
            for coord in track {
                xml += "      <trkpt lat=\"\(coord.latitude)\" lon=\"\(coord.longitude)\"></trkpt>\n"
            }
            xml += "    </trkseg>\n"
            xml += "  </trk>\n"
        }

        xml += "</gpx>\n"
        return Data(xml.utf8)
    }

    // MARK: - Decode

    /// Parses GPX XML into waypoints. Prefers `<wpt>`; if none are present but
    /// a track exists, uses the first and last track points as start/end.
    static func decode(_ data: Data) throws -> Document {
        guard !data.isEmpty else { throw DecodeError.empty }
        let parser = Parser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { throw DecodeError.notGPX }
        guard parser.sawGPX else { throw DecodeError.notGPX }

        var waypoints = parser.waypoints.filter { $0.coordinate.isValidLocation }
        let track = parser.trackCoordinates.filter(\.isValidLocation)

        if waypoints.isEmpty {
            if let first = track.first, let last = track.last, track.count >= 2 {
                waypoints = [
                    Waypoint(name: "Start", coordinate: first),
                    Waypoint(name: "End", coordinate: last),
                ]
            } else {
                throw DecodeError.noCoordinates
            }
        }

        return Document(
            name: parser.metadataName,
            waypoints: waypoints,
            trackCoordinates: track
        )
    }

    // MARK: - Helpers

    private static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func iso8601UTC(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }
}

// MARK: - XMLParser delegate

private final class Parser: NSObject, XMLParserDelegate {
    var sawGPX = false
    var metadataName: String?
    var waypoints: [Waypoint] = []
    var trackCoordinates: [CLLocationCoordinate2D] = []

    private var inMetadata = false
    private var inWPT = false
    private var currentLat: Double?
    private var currentLon: Double?
    private var currentName = ""
    private var collectingName = false
    private var textBuffer = ""

    func parser(_ parser: XMLParser,
                didStartElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        let name = elementName.lowercased()
        switch name {
        case "gpx":
            sawGPX = true
        case "metadata":
            inMetadata = true
        case "wpt":
            inWPT = true
            currentLat = Double(attributeDict["lat"] ?? "")
            currentLon = Double(attributeDict["lon"] ?? "")
            currentName = ""
        case "trkpt":
            if let lat = Double(attributeDict["lat"] ?? ""),
               let lon = Double(attributeDict["lon"] ?? "") {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if coord.isValidLocation {
                    trackCoordinates.append(coord)
                }
            }
        case "name":
            collectingName = true
            textBuffer = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collectingName {
            textBuffer += string
        }
    }

    func parser(_ parser: XMLParser,
                didEndElement elementName: String,
                namespaceURI: String?,
                qualifiedName qName: String?) {
        let name = elementName.lowercased()
        switch name {
        case "metadata":
            inMetadata = false
        case "name":
            let value = textBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if inWPT {
                currentName = value
            } else if inMetadata, metadataName == nil {
                metadataName = value
            }
            collectingName = false
            textBuffer = ""
        case "wpt":
            if let lat = currentLat, let lon = currentLon {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if coord.isValidLocation {
                    let label = currentName.isEmpty ? "Waypoint" : currentName
                    waypoints.append(Waypoint(name: label, coordinate: coord))
                }
            }
            inWPT = false
            currentLat = nil
            currentLon = nil
            currentName = ""
        default:
            break
        }
    }
}
