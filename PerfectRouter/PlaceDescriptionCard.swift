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
            Button {
                openIfDescribed()
            } label: {
                HStack(alignment: alignment, spacing: spacing) {
                    icon
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(8)
                            .modifier(IdentifierIfPresent(identifier: titleIdentifier))
                        descriptionText
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(6)
                    }
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
            .modifier(OpenDescriptionHint(isActive: placeDescription != nil))

            Button {
                onAdd()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(name)")
        }
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
    @ViewBuilder
    private var descriptionText: some View {
        if let placeDescription {
            Text(placeDescription)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(PlaceDescriptionDisplay.collapsedLineLimit)
                .modifier(IdentifierIfPresent(identifier: descriptionIdentifier))
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
