import SwiftUI

/// Evening lodging. Check a hotel, then Apply — the same gesture as fuel.
/// Call and Website appear only when Apple Maps published them.
struct HotelsAlongRouteSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        if FeatureFlags.hotelsAlongRoute {
            hotelSection
        }
    }

    private var hotelSection: some View {
        Section("Hotels") {
            // Above the rows that a check updates, so a focus abort further
            // down still leaves evening-1 state in the accessibility tree.
            Text(verbatim: viewModel.hotelLodgingProbe)
                .font(.system(size: 1))
                .foregroundStyle(.clear)
                .frame(maxWidth: .infinity, minHeight: 1, maxHeight: 1)
                .accessibilityIdentifier(AccessibilityID.hotelLodgingState)
                .accessibilityLabel(viewModel.hotelLodgingProbe)
                .accessibilityValue(viewModel.hotelLodgingProbe)
                .focusable()
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)

            // A date picker in this list is a focus container iPad aborts on,
            // which drops every hotel row after it. The stepper is one control.
            Stepper(value: hotelTargetMinutesBinding, in: 15...((24 * 60) - 15), step: 15) {
                Text("Arrive around \(HotelAlongRoute.clockText(minutes: viewModel.hotelTargetMinutes, includePeriod: true, omitZeroMinutes: false))")
            }
            .accessibilityIdentifier(AccessibilityID.hotelTarget)

            Text(HotelAlongRoute.windowLabel(targetMinutes: viewModel.hotelTargetMinutes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .focusable()

            if viewModel.isSearchingHotels, viewModel.hotelEvenings.isEmpty {
                ProgressView("Searching for lodging…")
                    .focusable()
            } else {
                FocusPlaceholderRow()
            }

            if viewModel.hotelLoadFailed, viewModel.hotelEvenings.isEmpty {
                Button {
                    viewModel.retryHotelSearch()
                } label: {
                    Text(HotelAlongRoute.loadFailedCopy)
                        .foregroundStyle(.secondary)
                }
                .focusable()
            } else {
                FocusPlaceholderRow()
            }

            if !viewModel.hotelEvenings.isEmpty {
                ForEach(viewModel.hotelEvenings) { evening in
                    Text("Day \(evening.dayNumber)")
                        .font(.subheadline.weight(.semibold))
                        .accessibilityIdentifier("hotelDay.\(evening.dayNumber)")
                        .focusable()
                    // One list row for the evening's options. Checking a hotel
                    // updates that row in place. An if/else ForEach here is a
                    // container the iPad list drops, leaving the day header
                    // and a blank gap where the hotels were.
                    HotelEveningOptions(viewModel: viewModel, evening: evening)
                }
            } else {
                FocusPlaceholderRow()
            }

            // Same row checked or not. Swapping in the Apply button on the
            // tap added a list container and the sidebar dropped the hotels.
            HotelApplySlot(viewModel: viewModel)
        }
    }

    private var hotelTargetMinutesBinding: Binding<Int> {
        Binding(
            get: { viewModel.hotelTargetMinutes },
            set: { viewModel.setHotelTarget(minutes: $0) }
        )
    }

}

/// One evening's hotels, or the empty-window line. A single list row so a
/// check does not insert or remove cells under the day header.
private struct HotelEveningOptions: View {
    let viewModel: RoutePlannerViewModel
    let evening: HotelEveningPlan

    var body: some View {
        if evening.options.isEmpty, let message = evening.emptyMessage {
            Text(message)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier(AccessibilityID.noLodging)
                .accessibilityLabel(message)
                .focusable()
        } else if !evening.options.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(evening.options) { stop in
                    HotelCheckRow(viewModel: viewModel, stop: stop, evening: evening)
                    HotelLinkRow(stop: stop)
                }
            }
        } else {
            FocusPlaceholderRow()
        }
    }
}

/// One hotel, checked or not. Its body reads the buffer, so the identifier
/// flips to `.checked` on the tap instead of staying on the first render.
/// The title text carries the identifier, same as a fuel row: a list cell
/// exposes that text and drops an identifier that lives only on the button.
private struct HotelCheckRow: View {
    let viewModel: RoutePlannerViewModel
    let stop: SuggestedStop
    let evening: HotelEveningPlan

    var body: some View {
        let onRoute = viewModel.isStopOnRoute(stop)
        let checked = viewModel.isHotelBuffered(stop)
        let caption = viewModel.hotelCaption(for: stop, in: evening)
        let identifier = AccessibilityID.hotelStop(stop.name, checked: checked)
        let description = PlaceDescriptionDisplay.rowText(for: stop.placeDescription)
        Button {
            viewModel.noteHotelRowTap(name: stop.name, day: evening.dayNumber, onRoute: onRoute)
            guard !onRoute else { return }
            viewModel.toggleBufferedHotelStop(stop, onEvening: evening.dayNumber)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bed.double.fill")
                    .foregroundStyle(Color.indigo)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    FuelStopTextColumn(
                        title: stop.name,
                        caption: caption,
                        rowIdentifier: identifier
                    )
                    if let description {
                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(PlaceDescriptionDisplay.collapsedLineLimit)
                    }
                }
                Spacer(minLength: 0)
                if onRoute {
                    Text("Added")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: checked ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(checked ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(onRoute)
        .accessibilityIdentifier(identifier)
        .sidebarStopHighlight(selected: viewModel.highlightedStopID == stop.id)
    }
}

/// Call and Website. Absent links stay a one-point placeholder so the
/// evening row's focus children do not drop to zero.
private struct HotelLinkRow: View {
    let stop: SuggestedStop

    var body: some View {
        let phone = HotelAlongRoute.telephoneURL(from: stop.mapItem.phoneNumber)
        let website = HotelAlongRoute.websiteURL(from: stop.mapItem.url)
        if phone != nil || website != nil {
            HStack(spacing: 12) {
                if let phone {
                    Link(destination: phone) {
                        Label("Call", systemImage: "phone")
                    }
                    .accessibilityLabel("Call \(stop.name)")
                }
                if let website {
                    Link(destination: website) {
                        Label("Website", systemImage: "safari")
                    }
                    .accessibilityLabel("Website \(stop.name)")
                }
            }
            .font(.caption)
            .buttonStyle(.borderless)
        } else {
            FocusPlaceholderRow()
        }
    }
}

/// Checked hotels wait here until the rider applies them in one route update.
/// The buttons stay in the row when nothing is checked. Replacing this row
/// with a placeholder on the tap is what left a blank gap under Day 1.
struct HotelApplySlot: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        let empty = viewModel.bufferedHotelStops.isEmpty
        VStack(alignment: .leading, spacing: empty ? 0 : 8) {
            FocusPlaceholderRow()
            Button {
                viewModel.applyBufferedHotelStops()
            } label: {
                Label("Apply \(viewModel.bufferedHotelStops.count) stops", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.applyHotels)
            .disabled(empty)
            .accessibilityHidden(empty)
            .opacity(empty ? 0 : 1)
            .frame(maxHeight: empty ? CGFloat(0) : nil)

            Button("Clear selection") {
                viewModel.clearBufferedHotelStops()
            }
            .disabled(empty)
            .accessibilityHidden(empty)
            .opacity(empty ? 0 : 1)
            .frame(maxHeight: empty ? CGFloat(0) : nil)
        }
    }
}
