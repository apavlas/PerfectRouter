import StoreKit
import SwiftUI

/// Links the paywall must show (App Review guideline 3.1.2).
enum AppLinks {
    /// Apple's standard EULA (LaunchPlan: use Apple's standard terms).
    static let termsOfUse = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    /// Until the Perfect Process URL is live (LaunchPlan step 6), the
    /// policy in the public repo.
    static let privacyPolicy = URL(string: "https://github.com/apavlas/PerfectRouter/blob/main/docs/privacy.html")!
}

/// The Pro paywall. Opened by tapping a Pro feature; the feature sets the
/// headline. The yearly plan is selected by default.
struct PaywallView: View {
    let feature: ProFeature?
    var store: ProStore = .shared

    @Environment(\.dismiss) private var dismiss
    @State private var selectedID = ProAccess.yearlyProductID
    @State private var isWorking = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Text(feature?.paywallHeadline ?? "PerfectRouter Pro")
                            .font(.title2.bold())
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityIdentifier("paywall.headline")

                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(ProFeature.allCases) { item in
                                Label(item.benefit, systemImage: item.systemImage)
                                    .foregroundStyle(item == feature ? .primary : .secondary)
                                    .fontWeight(item == feature ? .semibold : .regular)
                            }
                        }

                        Text("Opening a ride someone shared with you, planning with gas stops, and handing off to Apple Maps or Google Maps stay free.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)

                        plans
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 16)
                }
                footer
            }
            .navigationTitle("Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                        .accessibilityIdentifier("paywall.notNow")
                }
            }
            .alert("Pro", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(message ?? "")
            }
            .task { await store.start() }
            .onChange(of: store.isPro) { _, isPro in
                if isPro { dismiss() }
            }
        }
    }

    @ViewBuilder private var plans: some View {
        if store.products.isEmpty {
            if store.isLoadingProducts {
                ProgressView("Loading plans…")
                    .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 8) {
                    Text("Couldn't reach the App Store.")
                        .foregroundStyle(.secondary)
                    Button("Try Again") { Task { await store.loadProducts() } }
                }
                .frame(maxWidth: .infinity)
            }
        } else {
            VStack(spacing: 12) {
                ForEach(store.products, id: \.id) { product in
                    PlanRow(
                        product: product,
                        selected: product.id == selectedID,
                        showsTrial: store.isEligibleForTrial
                    ) {
                        selectedID = product.id
                    }
                }
            }
        }
    }

    private var selectedProduct: Product? {
        store.products.first { $0.id == selectedID } ?? store.products.first
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: subscribe) {
                Group {
                    if isWorking {
                        ProgressView()
                    } else {
                        Text(store.isEligibleForTrial ? "Start Free Trial" : "Subscribe")
                    }
                }
                .font(.headline)
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(selectedProduct == nil || isWorking)
            .accessibilityIdentifier("paywall.subscribe")

            if let product = selectedProduct {
                Text(PaywallCopy.disclosure(
                    price: product.displayPrice,
                    period: PaywallCopy.periodNoun(product.id),
                    trialDays: store.isEligibleForTrial ? PaywallCopy.trialDays(product) : nil
                ))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            HStack(spacing: 16) {
                Button("Restore Purchases", action: restore)
                    .disabled(isWorking)
                Link("Terms of Use", destination: AppLinks.termsOfUse)
                Link("Privacy Policy", destination: AppLinks.privacyPolicy)
            }
            .font(.caption)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
    }

    private func subscribe() {
        guard let product = selectedProduct else { return }
        isWorking = true
        Task {
            let outcome = await store.purchase(product)
            isWorking = false
            switch outcome {
            case .purchased, .cancelled:
                break
            case .pending:
                message = "Your purchase is waiting for approval. Pro turns on as soon as it goes through."
            case .failed:
                message = "The purchase didn't go through. You haven't been charged."
            }
        }
    }

    private func restore() {
        isWorking = true
        Task {
            let restored = await store.restore()
            isWorking = false
            if !restored {
                message = "No Pro subscription was found for this Apple Account."
            }
        }
    }
}

/// Paywall wording, kept out of the view so it can be tested.
enum PaywallCopy {
    static func periodNoun(_ productID: String) -> String {
        productID == ProAccess.monthlyProductID ? "month" : "year"
    }

    /// "Free for 7 days, then $29.99 a year. Renews automatically until you
    /// cancel in Settings at least 24 hours before the period ends."
    static func disclosure(price: String, period: String, trialDays: Int?) -> String {
        let lead = trialDays.map { "Free for \($0) days, then \(price) a \(period)." } ?? "\(price) a \(period)."
        return lead + " Renews automatically until you cancel in Settings at least 24 hours before the period ends."
    }

    static func trialDays(_ product: Product) -> Int? {
        guard let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial else { return nil }
        return days(value: offer.period.value, unit: offer.period.unit)
    }

    static func days(value: Int, unit: Product.SubscriptionPeriod.Unit) -> Int {
        switch unit {
        case .day: return value
        case .week: return value * 7
        case .month: return value * 30
        case .year: return value * 365
        @unknown default: return value
        }
    }

    /// "$2.50 a month" under the yearly price, rounded down to the cent.
    static func monthlyEquivalent(yearly price: Decimal, format: Decimal.FormatStyle.Currency) -> String {
        var perMonth = price / 12
        var rounded = Decimal()
        NSDecimalRound(&rounded, &perMonth, 2, .down)
        return rounded.formatted(format)
    }
}

private struct PlanRow: View {
    let product: Product
    let selected: Bool
    let showsTrial: Bool
    let select: () -> Void

    private var isYearly: Bool { product.id == ProAccess.yearlyProductID }

    var body: some View {
        Button(action: select) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isYearly ? "Yearly" : "Monthly").font(.headline)
                    if isYearly {
                        Text("\(PaywallCopy.monthlyEquivalent(yearly: product.price, format: product.priceFormatStyle)) a month, billed yearly")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if showsTrial, let days = PaywallCopy.trialDays(product) {
                        Text("\(days)-day free trial")
                            .font(.caption)
                            .foregroundStyle(.tint)
                    }
                }
                Spacer()
                Text("\(product.displayPrice)/\(PaywallCopy.periodNoun(product.id) == "month" ? "mo" : "yr")")
                    .font(.headline)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("paywall.plan.\(isYearly ? "yearly" : "monthly")")
    }
}

/// One row under the ride summary on Free, once a ride is planned: what Pro
/// adds to this ride. Opens the paywall.
struct ProUpsellRow: View {
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hotels, rain along the route, and Twisty roads")
                    Text("Try Pro free for 7 days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "sparkles")
            }
        }
        .accessibilityIdentifier("proUpsell")
    }
}
