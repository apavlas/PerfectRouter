import SwiftUI

/// Evening lodging. Check a hotel, then Apply — the same gesture as fuel.
/// Call and Website appear only when Apple Maps published them.
struct HotelsAlongRouteSection: View {
    let viewModel: RoutePlannerViewModel

    @Environment(\.planningUsesSidebar) private var planningUsesSidebar

    var body: some View {
        if FeatureFlags.hotelsAlongRoute {
            hotelSection
        }
    }

    private var hotelSection: some View {
        Section("Hotels") {
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
                    if evening.options.isEmpty, let message = evening.emptyMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityID.noLodging)
                            .accessibilityLabel(message)
                            .focusable()
                    } else if !evening.options.isEmpty {
                        ForEach(evening.options) { stop in
                            hotelRow(stop, in: evening)
                            hotelLinks(stop)
                        }
                    } else {
                        FocusPlaceholderRow()
                    }
                }
            } else {
                FocusPlaceholderRow()
            }

            if !viewModel.bufferedHotelStops.isEmpty {
                BufferedHotelApplyRow(viewModel: viewModel)
            } else {
                FocusPlaceholderRow()
            }
        }
    }

    private var hotelTargetMinutesBinding: Binding<Int> {
        Binding(
            get: { viewModel.hotelTargetMinutes },
            set: { viewModel.setHotelTarget(minutes: $0) }
        )
    }

    /// Same shape as a fuel row. The title text carries the identifier: a
    /// list cell on iPhone exposes that text and drops an identifier that
    /// lives only on the button, so the checked suffix never appeared after
    /// the tap. An accessibility label on the button hid the row entirely.
    private func hotelRow(_ stop: SuggestedStop, in evening: HotelEveningPlan) -> some View {
        let onRoute = viewModel.isStopOnRoute(stop)
        let checked = viewModel.isHotelBuffered(stop)
        let caption = viewModel.hotelCaption(for: stop, in: evening)
        let identifier = AccessibilityID.hotelStop(stop.name, checked: checked)
        let description = PlaceDescriptionDisplay.rowText(for: stop.placeDescription)
        return Button {
            guard !onRoute else { return }
            if planningUsesSidebar {
                viewModel.focusListedStop(id: stop.id, coordinate: stop.coordinate)
            }
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
        .id("\(stop.id.uuidString)-\(checked)")
    }

    /// Call and Website stay off the check button. A second control in that
    /// row is what kept iPad from exposing the hotel identifier.
    @ViewBuilder
    private func hotelLinks(_ stop: SuggestedStop) -> some View {
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
struct BufferedHotelApplyRow: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                viewModel.applyBufferedHotelStops()
            } label: {
                Label("Apply \(viewModel.bufferedHotelStops.count) stops", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier(AccessibilityID.applyHotels)

            Button("Clear selection") {
                viewModel.clearBufferedHotelStops()
            }
        }
    }
}
