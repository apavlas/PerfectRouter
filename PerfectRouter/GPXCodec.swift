import Foundation
import CoreLocation

/// Encodes and decodes GPS Exchange Format (GPX 1.1) snapshots of a planned
/// ride. Export writes plan stops as `<wpt>`, the same stops in ride order as
/// one `<rte>` (what Garmin and TomTom units import as a route or trip), and,
/// when a route polyline is available, the line as a thinned `<trk>`. Import
/// maps `<wpt>` (falling back to `<rte>` points, then track start/end) into
/// waypoints the planner can route.
enum GPXCodec {

    /// A decoded GPX document: named waypoints plus an optional track line.
    struct Document {
        var name: String?
        var waypoints: [Waypoint]
        /// Flattened track points when the file contained a `<trk>`, else empty.
        var trackCoordinates: [CLLocationCoordinate2D]
        /// Usable waypoints in the file before the `maxWaypoints` cap.
        var originalWaypointCount: Int = 0

        /// True when the file had more stops than the planner keeps.
        var wasTrimmed: Bool { originalWaypointCount > waypoints.count }
    }

    enum DecodeError: Error, Equatable {
        case empty
        case notGPX
        case noCoordinates
        case tooLarge
    }

    /// Most stops an import keeps, matching shared links. Every stop is a
    /// MapKit directions request, and a few hundred get throttled.
    static let maxWaypoints = SharedRoute.maxElementCount

    /// Largest file accepted. A multi-day GPX with a full track is a few
    /// megabytes, and anything far larger isn't a ride plan.
    static let maxFileBytes = 20 * 1024 * 1024

    /// Keeps `limit` stops in ride order: always the start and the
    /// destination, plus evenly spaced stops between them.
    static func trimmed(_ waypoints: [Waypoint], to limit: Int = maxWaypoints) -> [Waypoint] {
        guard limit >= 2, waypoints.count > limit else { return waypoints }
        let step = Double(waypoints.count - 1) / Double(limit - 1)
        return (0..<limit).map { slot -> Waypoint in
            let index = (Double(slot) * step).rounded()
            return waypoints[Int(index)]
        }
    }

    /// Most points written to the exported `<trk>`. Older Garmin units keep
    /// 10,000 points per track and drop or refuse the rest; a raw MapKit line
    /// for a long ride can be several times that.
    static let maxTrackPoints = 10_000

    /// Starting tolerance for thinning the exported line. Points closer than
    /// this to the simplified line are dropped; 10 m is under a lane's width
    /// of drift at road scale, so curves keep their shape.
    static let trackToleranceMeters: CLLocationDistance = 10

    /// Douglas–Peucker simplification. Keeps the first and last point and
    /// every point more than `toleranceMeters` off the simplified line. If
    /// the result is still over `maxPoints`, the tolerance doubles until it
    /// fits.
    static func thinned(
        _ coordinates: [CLLocationCoordinate2D],
        toleranceMeters: CLLocationDistance = trackToleranceMeters,
        maxPoints: Int = maxTrackPoints
    ) -> [CLLocationCoordinate2D] {
        guard coordinates.count > 2 else { return coordinates }
        // Local flat projection around the first point, in meters. Good to
        // well under a meter per kilometer at ride scale.
        let origin = coordinates[0]
        let metersPerDegreeLat = 111_132.0
        let metersPerDegreeLon = 111_320.0 * cos(origin.latitude * .pi / 180)
        let points = coordinates.map {
            (x: ($0.longitude - origin.longitude) * metersPerDegreeLon,
             y: ($0.latitude - origin.latitude) * metersPerDegreeLat)
        }

        let chunkSize = 2_000
        func simplify(tolerance: Double) -> [CLLocationCoordinate2D] {
            var keep = [Bool](repeating: false, count: points.count)
            // Simplify in chunks of `chunkSize` points, keeping each chunk's
            // ends. Plain Douglas–Peucker can go quadratic on a long, evenly
            // wiggly line; chunks cap the cost on a multi-day ride.
            var stack: [(Int, Int)] = []
            var chunkStart = 0
            while chunkStart < points.count - 1 {
                let chunkEnd = min(chunkStart + chunkSize, points.count - 1)
                keep[chunkStart] = true
                keep[chunkEnd] = true
                stack.append((chunkStart, chunkEnd))
                chunkStart = chunkEnd
            }
            while let (first, last) = stack.popLast() {
                guard last - first > 1 else { continue }
                let a = points[first]
                let b = points[last]
                let dx = b.x - a.x
                let dy = b.y - a.y
                let lengthSquared = dx * dx + dy * dy
                var farthest = first
                var farthestDistance = 0.0
                for index in (first + 1)..<last {
                    let p = points[index]
                    let distance: Double
                    if lengthSquared == 0 {
                        distance = ((p.x - a.x) * (p.x - a.x) + (p.y - a.y) * (p.y - a.y)).squareRoot()
                    } else {
                        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
                        let cx = a.x + t * dx - p.x
                        let cy = a.y + t * dy - p.y
                        distance = (cx * cx + cy * cy).squareRoot()
                    }
                    if distance > farthestDistance {
                        farthestDistance = distance
                        farthest = index
                    }
                }
                if farthestDistance > tolerance {
                    keep[farthest] = true
                    stack.append((first, farthest))
                    stack.append((farthest, last))
                }
            }
            return coordinates.indices.compactMap { keep[$0] ? coordinates[$0] : nil }
        }

        var tolerance = max(toleranceMeters, 0.1)
        var result = simplify(tolerance: tolerance)
        while result.count > max(maxPoints, 2) {
            tolerance *= 2
            result = simplify(tolerance: tolerance)
        }
        return result
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

        let routeName = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Route"

        // The stops again, in ride order, as a route. GPX 1.1 requires
        // `<rte>` after every `<wpt>` and before any `<trk>`.
        let stops = waypoints.filter { $0.coordinate.isValidLocation }
        if stops.count >= 2 {
            xml += "  <rte>\n"
            xml += "    <name>\(escape(routeName))</name>\n"
            for stop in stops {
                let coord = stop.coordinate
                xml += "    <rtept lat=\"\(coord.latitude)\" lon=\"\(coord.longitude)\">\n"
                xml += "      <name>\(escape(stop.name))</name>\n"
                xml += "    </rtept>\n"
            }
            xml += "  </rte>\n"
        }

        let track = thinned(trackCoordinates.filter(\.isValidLocation))
        if !track.isEmpty {
            let trackName = routeName
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
        guard data.count <= maxFileBytes else { throw DecodeError.tooLarge }
        let parser = Parser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        guard xmlParser.parse() else { throw DecodeError.notGPX }
        guard parser.sawGPX else { throw DecodeError.notGPX }

        var waypoints = parser.waypoints.filter { $0.coordinate.isValidLocation }
        let track = parser.trackCoordinates.filter(\.isValidLocation)

        // A file from a GPS unit or another planner may carry its stops only
        // as a route.
        if waypoints.isEmpty {
            waypoints = parser.routePoints.filter { $0.coordinate.isValidLocation }
        }

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
            waypoints: trimmed(waypoints),
            trackCoordinates: track,
            originalWaypointCount: waypoints.count
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
    /// `<rtept>` points from the first `<rte>` only, in order.
    var routePoints: [Waypoint] = []

    private var inMetadata = false
    private var inWPT = false
    private var inRoutePoint = false
    private var routeCount = 0
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
        case "rte":
            routeCount += 1
        case "rtept":
            inRoutePoint = routeCount == 1
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
            if inWPT || inRoutePoint {
                currentName = value
            } else if inMetadata, metadataName == nil {
                metadataName = value
            }
            collectingName = false
            textBuffer = ""
        case "rtept":
            if inRoutePoint, let lat = currentLat, let lon = currentLon {
                let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                if coord.isValidLocation {
                    let label = currentName.isEmpty ? "Stop \(routePoints.count + 1)" : currentName
                    routePoints.append(Waypoint(name: label, coordinate: coord))
                }
            }
            inRoutePoint = false
            currentLat = nil
            currentLon = nil
            currentName = ""
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
