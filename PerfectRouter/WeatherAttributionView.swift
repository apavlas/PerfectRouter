import SwiftUI
import WeatherKit

/// The Apple Weather mark and legal link that WeatherKit's terms require
/// wherever its data is shown. The mark and the link both come from
/// `WeatherService.attribution`. When that can't load (for example with no
/// network), the view shows a plain-text mark and Apple's published legal
/// page, so the row is never left without attribution.
struct WeatherAttributionView: View {

    /// Apple's published legal attribution page. Used only when
    /// `WeatherService.attribution` can't be loaded.
    static let fallbackLegalURL = URL(string: "https://weatherkit.apple.com/legal-attribution.html")!

    @Environment(\.colorScheme) private var colorScheme
    @State private var attribution: WeatherAttribution?

    var body: some View {
        HStack(spacing: 6) {
            mark
            Link("Legal", destination: attribution?.legalPageURL ?? Self.fallbackLegalURL)
                .font(.caption2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Weather data from Apple Weather. Legal attribution.")
        .task {
            attribution = try? await WeatherService.shared.attribution
        }
    }

    @ViewBuilder
    private var mark: some View {
        if let attribution {
            AsyncImage(url: colorScheme == .dark
                       ? attribution.combinedMarkDarkURL
                       : attribution.combinedMarkLightURL) { image in
                image.resizable().scaledToFit()
            } placeholder: {
                textMark
            }
            .frame(height: 12)
        } else {
            textMark
        }
    }

    private var textMark: some View {
        Text("\u{F8FF} Weather")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
