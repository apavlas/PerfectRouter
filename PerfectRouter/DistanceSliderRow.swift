import SwiftUI

/// A labeled slider for a distance preference that is *stored* in miles (the
/// app's storage unit) but *displayed* in the rider's locale unit, so metric
/// riders see kilometers. The range and step are given in display units; the
/// range bounds are snapped to the step so metric ranges land on round values.
struct DistanceSliderRow: View {
    let label: String
    let systemImage: String
    @Binding var miles: Double
    /// Range of the slider, expressed in miles (converted for display).
    let milesRange: ClosedRange<Double>
    /// Step of the slider, in display units.
    let step: Double
    var onEditingChanged: (Bool) -> Void = { _ in }

    private var displayValue: Binding<Double> {
        Binding(
            get: { AppSettings.displayDistance(fromMiles: miles) },
            set: { miles = AppSettings.miles(fromDisplayDistance: $0) }
        )
    }

    private var displayRange: ClosedRange<Double> {
        let lower = (AppSettings.displayDistance(fromMiles: milesRange.lowerBound) / step).rounded() * step
        let upper = (AppSettings.displayDistance(fromMiles: milesRange.upperBound) / step).rounded() * step
        return lower...upper
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(label, systemImage: systemImage)
                Spacer()
                Text("\(Int(displayValue.wrappedValue.rounded())) \(AppSettings.distanceUnitAbbreviation)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: displayValue,
                in: displayRange,
                step: step,
                onEditingChanged: onEditingChanged
            )
        }
    }
}
