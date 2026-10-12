import SwiftUI

/// Snapshot of a published description. The sheet keeps this text; it does
/// not ask MapKit again, and it does not compose a new sentence.
struct OpenPlaceDescription: Identifiable {
    let id: UUID
    let name: String
    let text: String
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
    let systemImage: String
    var iconColor: Color?
    var titleIdentifier: String = ""
    var descriptionIdentifier: String = ""
    var alignment: VerticalAlignment = .top
    var spacing: CGFloat = 8
    let onOpen: () -> Void
    let onAdd: () -> Void

    var body: some View {
        HStack(alignment: alignment, spacing: spacing) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                cardButton(identifier: titleIdentifier, action: { openIfDescribed() }) {
                    Text(name)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(8)
                }
                descriptionText
                cardButton(identifier: "", action: { openIfDescribed() }) {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(6)
                }
            }
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

    /// Borderless, with an explicit content shape. In a List, `.plain` turns
    /// every button into the cell button, and the Add button's row-sized
    /// target was the view that received the description tap.
    private func cardButton<Label: View>(
        identifier: String,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) -> some View {
        Button(action: action) {
            label()
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .modifier(IdentifierIfPresent(identifier: identifier))
        .modifier(OpenDescriptionHint(isActive: placeDescription != nil))
    }

    private func openIfDescribed() {
        guard placeDescription != nil else { return }
        onOpen()
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
    /// Its own button. The identifier the UI test taps has to be this control,
    /// not a text nested in a different button that swallows the hit.
    @ViewBuilder
    private var descriptionText: some View {
        if let placeDescription {
            cardButton(identifier: descriptionIdentifier, action: { onOpen() }) {
                Text(placeDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(PlaceDescriptionDisplay.collapsedLineLimit)
            }
        }
    }
}

/// Full published text. The list card keeps the two-line clip.
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

/// VoiceOver hint only when a tap can open the published text.
private struct OpenDescriptionHint: ViewModifier {
    var isActive: Bool

    func body(content: Content) -> some View {
        if isActive {
            content.accessibilityHint("Shows the full description")
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
