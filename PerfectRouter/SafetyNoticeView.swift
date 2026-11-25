import SwiftUI

/// Shown once, after the splash and before anything else (LaunchPlan v1
/// scope): plan before you ride, suggestions are estimates, don't handle the
/// phone while riding. Riders who finished first-run on an earlier build
/// see it once too. Raising `AppSettings.safetyNoticeVersion` shows it again
/// after the wording changes.
struct SafetyNoticeView: View {
    @AppStorage(AppSettings.Keys.acknowledgedSafetyNoticeVersion)
    private var acknowledgedVersion = 0

    struct Point: Identifiable, Equatable {
        var id: String { title }
        var systemImage: String
        var title: String
        var detail: String
    }

    static let points: [Point] = [
        Point(
            systemImage: "map",
            title: "Plan before you ride",
            detail: "Set up your route while you're stopped. Hand off to Apple Maps or Google Maps for turn-by-turn directions."
        ),
        Point(
            systemImage: "hand.raised",
            title: "Don't handle your phone while riding",
            detail: "Keep your eyes on the road. Pull over safely before you change the plan."
        ),
        Point(
            systemImage: "fuelpump",
            title: "Fuel and lodging are estimates",
            detail: "Stations and hotels can be closed, out of fuel, or full, and arrival times and weather are predictions. Watch your gauge and confirm before you count on a stop."
        ),
    ]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "exclamationmark.shield")
                        .font(.system(size: 56))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.tint)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 24)
                        .accessibilityHidden(true)

                    Text("Ride safe")
                        .font(.title.bold())
                        .frame(maxWidth: .infinity)
                        .accessibilityAddTraits(.isHeader)

                    ForEach(Self.points) { point in
                        HStack(alignment: .top, spacing: 16) {
                            Image(systemName: point.systemImage)
                                .font(.title2)
                                .foregroundStyle(.tint)
                                .frame(width: 32)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(point.title).font(.headline)
                                Text(point.detail)
                                    .font(.body)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }

            Button(action: acknowledge) {
                Text("I understand")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("safetyNotice.acknowledge")
            .padding(.horizontal, 24)
            .padding(.bottom, 16)
        }
        .background(Color(.systemBackground).ignoresSafeArea())
    }

    private func acknowledge() {
        withAnimation(.easeInOut(duration: 0.35)) {
            acknowledgedVersion = AppSettings.safetyNoticeVersion
        }
    }
}

#Preview {
    SafetyNoticeView()
}
