import Foundation

/// The rider glyph used on the splash, first-run and Navigate button.
/// `motorcycle` is SF Symbols 6 (iOS 18+). iOS 17 has no motorcycle
/// symbol, so it keeps the cyclist rather than showing a blank image.
enum RiderSymbol {
    static var name: String {
        if #available(iOS 18.0, *) {
            return "motorcycle"
        }
        return "figure.outdoor.cycle"
    }
}
