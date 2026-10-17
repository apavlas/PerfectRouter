import SwiftUI

/// Evening lodging. Check a hotel, then Apply — the same gesture as fuel.
/// Call and Website appear only when Apple Maps published them.
struct HotelsAlongRouteSection: View {
    let viewModel: RoutePlannerViewModel

    var body: some View {
        Section("Hotels") {
            DatePicker(
                "Arrive around",
                selection: hotelTargetBinding,
                displayedComponents: .hourAndMinute
            )
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

    private var hotelTargetBinding: Binding<Date> {
        Binding(
            get: {
                HotelAlongRoute.date(minutes: viewModel.hotelTargetMinutes, on: Date())
            },
            set: { date in
                viewModel.setHotelTarget(minutes: HotelAlongRoute.minutes(from: date))
            }
        )
    }

    private func hotelRow(_ stop: SuggestedStop, in evening: HotelEveningPlan) -> some View {
        let onRoute = viewModel.isStopOnRoute(stop)
        let checked = viewModel.isHotelBuffered(stop)
        let caption = viewModel.hotelCaption(for: stop, in: evening)
        let description = PlaceDescriptionDisplay.rowText(for: stop.placeDescription)
        let phone = HotelAlongRoute.telephoneURL(from: stop.mapItem.phoneNumber)
        let website = HotelAlongRoute.websiteURL(from: stop.mapItem.url)
        return HStack(alignment: .top, spacing: 8) {
            Button {
                guard !onRoute else { return }
                viewModel.toggleBufferedHotelStop(stop, onEvening: evening.dayNumber)
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "bed.double.fill")
                        .foregroundStyle(Color.indigo)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stop.name)
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
                        if let description {
                            Text(description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(PlaceDescriptionDisplay.collapsedLineLimit)
                        }
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                            .lineLimit(4)
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
            .accessibilityIdentifier(AccessibilityID.hotelStop(stop.name, checked: checked))
            .accessibilityLabel("\(stop.name), \(caption)")

            if phone != nil || website != nil {
                VStack(alignment: .leading, spacing: 4) {
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
            }
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
