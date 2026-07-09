import Foundation
import MapKit
import UIKit

/// Renders a static image of a planned route and stores it on disk, so the
/// rider can review a ride visually without connectivity.
///
/// Note: this is NOT downloadable offline maps (MapKit has no public offline
/// tile API). It is a saved snapshot of the route for offline reference.
enum RouteSnapshotter {

    /// Directory where snapshot PNGs are stored (created on demand).
    static func snapshotsDirectory() -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Loads a previously saved snapshot image by filename.
    static func image(named filename: String) -> UIImage? {
        guard let url = snapshotURL(for: filename) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Removes a saved snapshot file, e.g. when its ride is deleted.
    static func deleteSnapshot(named filename: String) {
        guard let url = snapshotURL(for: filename) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Resolves a snapshot filename to a URL inside the snapshots directory,
    /// rejecting anything that isn't a single path component. Filenames are
    /// read back from `ride_log.json`; refusing path separators and `..` keeps
    /// a tampered or malformed entry from escaping the snapshots directory and
    /// reading or deleting arbitrary files.
    private static func snapshotURL(for filename: String) -> URL? {
        guard !filename.isEmpty,
              !filename.contains("/"),
              filename != ".",
              filename != ".." else { return nil }
        return snapshotsDirectory().appendingPathComponent(filename)
    }

    /// Captures and saves a snapshot of the route, returning its filename.
    static func captureSnapshot(legs: [MKRoute]) async -> String? {
        guard !legs.isEmpty else { return nil }

        var boundingRect = MKMapRect.null
        for leg in legs {
            boundingRect = boundingRect.union(leg.polyline.boundingMapRect)
        }
        guard !boundingRect.isNull else { return nil }

        // Pad the route bounds a little so it isn't flush against the edges.
        let padded = boundingRect.insetBy(
            dx: -boundingRect.size.width * 0.15,
            dy: -boundingRect.size.height * 0.15
        )

        let options = MKMapSnapshotter.Options()
        options.mapRect = padded
        options.size = CGSize(width: 600, height: 400)

        let snapshotter = MKMapSnapshotter(options: options)
        let snapshot: MKMapSnapshotter.Snapshot? = await withCheckedContinuation { continuation in
            snapshotter.start(with: .global()) { snapshot, _ in
                continuation.resume(returning: snapshot)
            }
        }
        guard let snapshot else { return nil }

        let image = drawRoute(on: snapshot, legs: legs)
        guard let data = image.pngData() else { return nil }

        let filename = "\(UUID().uuidString).png"
        let url = snapshotsDirectory().appendingPathComponent(filename)
        do {
            // A snapshot is a visual map of exactly where the rider has been,
            // so it gets the same protection as the ride log that references it.
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            excludeFromBackup(url)
            return filename
        } catch {
            return nil
        }
    }

    /// Draws the route polyline over the rendered map snapshot.
    private static func drawRoute(on snapshot: MKMapSnapshotter.Snapshot, legs: [MKRoute]) -> UIImage {
        let baseImage = snapshot.image
        let renderer = UIGraphicsImageRenderer(size: baseImage.size)
        return renderer.image { context in
            baseImage.draw(at: .zero)
            context.cgContext.setStrokeColor(UIColor.systemBlue.cgColor)
            context.cgContext.setLineWidth(4)
            context.cgContext.setLineJoin(.round)

            for leg in legs {
                let polyline = leg.polyline
                let count = polyline.pointCount
                guard count > 1 else { continue }
                var coordinates = [CLLocationCoordinate2D](repeating: .init(), count: count)
                polyline.getCoordinates(&coordinates, range: NSRange(location: 0, length: count))

                for (index, coordinate) in coordinates.enumerated() {
                    let point = snapshot.point(for: coordinate)
                    if index == 0 {
                        context.cgContext.move(to: point)
                    } else {
                        context.cgContext.addLine(to: point)
                    }
                }
            }
            context.cgContext.strokePath()
        }
    }
}
