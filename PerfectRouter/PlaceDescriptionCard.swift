import SwiftUI

/// Snapshot of a published description. The sheet keeps this text; it does
/// not ask MapKit again, and it does not compose a new sentence.
struct OpenPlaceDescription: Identifiable {
    let id: UUID
    let name: String
    let text: String
    /// Stamped on the sheet's full text. Empty for cards the UI tests do not open.
    var textIdentifier: String = ""
}

/// Place name, then the published description, then the existing distance
/// line. The Add button stays the trailing control.
///
/// The text stack always contains the name and the distance line, so a place
/// with no description does not leave an empty focus container. No `frame`
/// or `fixedSize` — those wrappers were focus containers UIKit visited with
/// no children on iPad.
struct PlaceDescriptionCard: View {
    let name: String
    let placeDescription: String?
    /// Miles-from-start and miles-off-route, already formatted by the caller.
    let detail: String
    /// Orange caption when this place sits past the tank that is left.
    var showsPastRange: Bool = false
    let systemImage: String
    var iconColor: Color?
    var titleIdentifier: String = ""
    var descriptionIdentifier: String = ""
    /// Stamped on the button that wraps the text, and only when non-empty.
    /// The identifier is the outermost modifier so XCTest sees
    /// `highlight.<name>.row`. Child name and description identifiers stay
    /// exposed because the button uses `accessibilityElement(children: .contain)`.
    var rowIdentifier: String = ""
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat = 8
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            icon
            rowBody
            Spacer(minLength: 0)
            Button(action: onAdd) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.blue)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add \(name)")
        }
    }

    /// Highlight rows need `highlight.<name>.row` on a tappable element.
    /// Suggestion cards pass an empty id and stay a plain text column, so
    /// their fuel-row identifier is not covered by a second button.
    @ViewBuilder
    private var rowBody: some View {
        if rowIdentifier.isEmpty {
            textColumn
        } else {
            Button {
                if placeDescription != nil {
                    onOpen()
                }
            } label: {
                textColumn
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(rowIdentifier)
        }
    }

    /// Name, clipped description, and the distance line. The row id is not
    /// on this stack: an identifier here hides the name and the description.
    private var textColumn: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .lineLimit(8)
                .modifier(IdentifierIfPresent(identifier: titleIdentifier))
                .modifier(OpenDescriptionTap(isActive: placeDescription != nil, action: onOpen))
            descriptionText
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(6)
                .modifier(OpenDescriptionTap(isActive: placeDescription != nil, action: onOpen))
            if showsPastRange {
                PastYourRangeLabel()
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        let image = Image(systemName: systemImage).accessibilityHidden(true)
        if let iconColor {
            image.foregroundStyle(iconColor)
        } else {
            image
        }
    }

    /// Inserted under the name. Absent when the place published nothing, so
    /// the distance line stays directly under the name.
    ///
    /// The identifier sits on this text. XCUITest taps the center of that
    /// frame, which is the middle of the two clipped lines — not the Add
    /// button and not a parent row button.
    @ViewBuilder
    private var descriptionText: some View {
        if let placeDescription {
            Text(placeDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(PlaceDescriptionDisplay.collapsedLineLimit)
                .modifier(IdentifierIfPresent(identifier: descriptionIdentifier))
                .modifier(OpenDescriptionTap(isActive: true, action: onOpen))
        }
    }
}

/// The same two stored sentences, with no line limit. The list card clips them.
struct PlaceDescriptionSheet: View {
    let name: String
    let text: String
    var textIdentifier: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(text)
                        .multilineTextAlignment(.leading)
                        .focusable()
                        .modifier(IdentifierIfPresent(identifier: textIdentifier))
                    Button("Done") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .padding()
            }
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

/// Tap target for a published description. `contentShape` fills the two-line
/// layout rect, including the gap between glyphs, so the center point
/// XCUITest uses is inside the gesture. `highPriorityGesture` wins over the
/// list row, which otherwise swallows a tap that starts on a nested button.
private struct OpenDescriptionTap: ViewModifier {
    var isActive: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if isActive {
            content
                .contentShape(Rectangle())
                .highPriorityGesture(TapGesture().onEnded { action() })
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Shows the full description")
                .accessibilityAction(.default) { action() }
        } else {
            content
        }
    }
}

/// Stamps an identifier only when the caller has one. An empty string would
/// clear the fuel-row identifier UI tests look up.
private struct IdentifierIfPresent: ViewModifier {
    var identifier: String

    func body(content: Content) -> some View {
        if identifier.isEmpty {
            content
        } else {
            content.accessibilityIdentifier(identifier)
        }
    }
}
