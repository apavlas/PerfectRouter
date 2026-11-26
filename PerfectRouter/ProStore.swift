import Foundation
import Observation
import StoreKit

/// What Pro unlocks (LaunchPlan "Business model"). Free keeps opening and
/// riding a shared plan, basic planning with gas stops, navigation handoff,
/// the on-screen rain warning, and up to `ProAccess.freeSavedRouteLimit`
/// saved rides.
enum ProFeature: String, CaseIterable, Identifiable, Sendable {
    case saveAndShare
    case lodging
    case twisty
    case weather
    case gpx
    case rideHistory

    var id: String { rawValue }

    /// The paywall headline when this feature opened it.
    var paywallHeadline: String {
        switch self {
        case .saveAndShare: return "Save more rides and share them with Pro"
        case .lodging: return "Find hotels along the ride with Pro"
        case .twisty: return "Twisty routing is part of Pro"
        case .weather: return "Rain alerts while you ride are part of Pro"
        case .gpx: return "GPX import and export are part of Pro"
        case .rideHistory: return "Ride History is part of Pro"
        }
    }

    /// One line in the paywall's list of benefits.
    var benefit: String {
        switch self {
        case .saveAndShare: return "Unlimited saved rides, and share them with your group"
        case .lodging: return "Hotels at each evening's stopping point"
        case .twisty: return "Twisty routes with more curves"
        case .weather: return "A rain alert when your phone is put away"
        case .gpx: return "GPX import and export"
        case .rideHistory: return "Ride History with stats"
        }
    }

    var systemImage: String {
        switch self {
        case .saveAndShare: return "square.and.arrow.up"
        case .lodging: return "bed.double"
        case .twisty: return "point.topleft.down.curvedto.point.bottomright.up"
        case .weather: return "cloud.rain"
        case .gpx: return "doc.badge.arrow.up"
        case .rideHistory: return "clock.arrow.circlepath"
        }
    }
}

/// Product IDs and the pure entitlement decision, separate from StoreKit so
/// they can be unit tested.
enum ProAccess {
    static let yearlyProductID = "com.apavlas.PerfectRouter.pro.yearly"
    static let monthlyProductID = "com.apavlas.PerfectRouter.pro.monthly"
    /// Yearly first: the paywall shows it first and selects it by default.
    static let productIDs = [yearlyProductID, monthlyProductID]

    /// One verified current entitlement, as StoreKit reports it.
    struct Entitlement: Equatable, Sendable {
        var productID: String
        var expirationDate: Date?
        var revocationDate: Date?
    }

    /// Pro is on while any Pro subscription is current: not refunded or
    /// revoked, and not past its expiration date. A trial counts.
    static func isActive(_ entitlements: [Entitlement], now: Date) -> Bool {
        entitlements.contains { entitlement in
            guard productIDs.contains(entitlement.productID), entitlement.revocationDate == nil else { return false }
            guard let expiration = entitlement.expirationDate else { return true }
            return expiration > now
        }
    }

    /// The products in paywall order. Unknown IDs are dropped.
    static func ordered<T>(_ items: [T], id: (T) -> String) -> [T] {
        productIDs.compactMap { productID in items.first { id($0) == productID } }
    }

    /// Free keeps this many saved rides. Pro keeps any number. Rides saved
    /// while on Pro stay after Pro ends; only new saves past the limit stop.
    static let freeSavedRouteLimit = 3

    static func canSaveRoute(savedCount: Int, isPro: Bool) -> Bool {
        isPro || savedCount < freeSavedRouteLimit
    }

    /// Stub and smoke UI test launches run as Pro so they reach every
    /// feature; `-UITestFreeTier` runs one as Free.
    static let freeTierArgument = "-UITestFreeTier"

    static func launchOverride(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool? {
        if arguments.contains(freeTierArgument) { return false }
        if UITestStubLaunch.skipsOnboarding { return true }
        return nil
    }
}

/// The rider's Pro subscription, from StoreKit 2. One shared instance for
/// the app; it listens for renewals, refunds, and purchases made elsewhere
/// (another device, Ask to Buy, an offer code) for as long as the app runs.
@MainActor
@Observable
final class ProStore {
    static let shared = ProStore()

    private(set) var isPro: Bool
    /// The Pro products, yearly first. Empty until loaded, or when the App
    /// Store can't be reached.
    private(set) var products: [Product] = []
    private(set) var isLoadingProducts = false
    /// Whether this Apple Account can still start the free trial.
    private(set) var isEligibleForTrial = false
    /// When the current plan next charges or ends, for the billing reminders.
    private(set) var renewal: BillingReminder.Renewal?

    /// The in-app reminder line when a trial ends or a yearly plan renews
    /// soon, otherwise nil.
    var billingReminderText: String? {
        guard let renewal, BillingReminder.isDue(renewal, now: Date()) else { return nil }
        let price = products.first { $0.id == renewal.productID }?.displayPrice
        return BillingReminder.text(
            for: renewal,
            dateText: renewal.expirationDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()),
            price: price
        )
    }

    @ObservationIgnored private let override: Bool?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    /// The last entitlement StoreKit reported, so a Pro rider's plan
    /// doesn't drop to Free for the moment it takes to check at launch.
    /// StoreKit's answer replaces it as soon as it arrives.
    static let lastKnownProKey = "pro.lastKnownIsPro"

    init(override: Bool? = ProAccess.launchOverride(), defaults: UserDefaults = .standard) {
        self.override = override
        self.defaults = defaults
        self.isPro = override ?? defaults.bool(forKey: Self.lastKnownProKey)
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let reminderNotifier = BillingReminderNotifier()

    /// Loads products and the current entitlement, and starts listening for
    /// transaction updates. Safe to call more than once.
    func start() async {
        guard override == nil else { return }
        if !started {
            started = true
            updatesTask = Task { [weak self] in
                for await result in Transaction.updates {
                    if case .verified(let transaction) = result {
                        await transaction.finish()
                    }
                    await self?.refreshEntitlements()
                }
            }
            // Cancelling or switching plans changes renewal preferences
            // without a new transaction, so the reminders listen here too.
            statusTask = Task { [weak self] in
                for await _ in Product.SubscriptionInfo.Status.updates {
                    await self?.refreshEntitlements()
                }
            }
        }
        await refreshEntitlements()
        await loadProducts()
    }

    func loadProducts() async {
        guard override == nil, !isLoadingProducts else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        guard let loaded = try? await Product.products(for: ProAccess.productIDs) else { return }
        products = ProAccess.ordered(loaded, id: \.id)
        if let first = products.first, let subscription = first.subscription {
            isEligibleForTrial = await subscription.isEligibleForIntroOffer
        }
    }

    func refreshEntitlements() async {
        guard override == nil else { return }
        var current: [ProAccess.Entitlement] = []
        var latest: Transaction?
        for await result in Transaction.currentEntitlements {
            guard case .verified(let transaction) = result else { continue }
            current.append(ProAccess.Entitlement(
                productID: transaction.productID,
                expirationDate: transaction.expirationDate,
                revocationDate: transaction.revocationDate
            ))
            if ProAccess.productIDs.contains(transaction.productID), transaction.revocationDate == nil,
               (transaction.expirationDate ?? .distantPast) > (latest?.expirationDate ?? .distantPast) {
                latest = transaction
            }
        }
        isPro = ProAccess.isActive(current, now: Date())
        defaults.set(isPro, forKey: Self.lastKnownProKey)
        renewal = isPro ? await Self.renewal(for: latest) : nil
        await reminderNotifier.update(trialEnding: renewal)
    }

    /// The renewal facts for the current Pro transaction: when it next
    /// charges or ends, whether that's a trial ending, and whether it will
    /// renew. Nil when StoreKit can't say.
    private static func renewal(for transaction: Transaction?) async -> BillingReminder.Renewal? {
        guard let transaction, let expiration = transaction.expirationDate,
              let groupID = transaction.subscriptionGroupID else { return nil }
        var willAutoRenew = true
        // The plan the next charge is for. A yearly rider who switched to
        // monthly is still on yearly until it ends, but is charged monthly.
        var nextProductID = transaction.productID
        if let statuses = try? await Product.SubscriptionInfo.status(for: groupID),
           let status = statuses.first(where: { $0.state == .subscribed || $0.state == .inGracePeriod || $0.state == .inBillingRetryPeriod }),
           case .verified(let info) = status.renewalInfo {
            willAutoRenew = info.willAutoRenew
            if let preference = info.autoRenewPreference, ProAccess.productIDs.contains(preference) {
                nextProductID = preference
            }
        }
        let isTrial: Bool
        if #available(iOS 17.2, *) {
            isTrial = transaction.offer?.type == .introductory
        } else {
            isTrial = transaction.offerType == .introductory
        }
        return BillingReminder.Renewal(
            productID: nextProductID,
            expirationDate: expiration,
            isTrial: isTrial,
            willAutoRenew: willAutoRenew
        )
    }

    enum PurchaseOutcome: Equatable {
        case purchased
        /// Waiting on Ask to Buy or a payment problem; Pro turns on through
        /// `Transaction.updates` if it goes through.
        case pending
        case cancelled
        case failed
    }

    func purchase(_ product: Product) async -> PurchaseOutcome {
        do {
            switch try await product.purchase() {
            case .success(let verification):
                guard case .verified(let transaction) = verification else { return .failed }
                await transaction.finish()
                await refreshEntitlements()
                return .purchased
            case .pending:
                return .pending
            case .userCancelled:
                return .cancelled
            @unknown default:
                return .failed
            }
        } catch {
            return .failed
        }
    }

    /// Restore Purchases: syncs with the App Store, which may ask the rider
    /// to sign in. Returns whether Pro is on afterward.
    func restore() async -> Bool {
        try? await AppStore.sync()
        await refreshEntitlements()
        return isPro
    }
}

extension RouteStyle {
    /// "Twisty (Pro)" in pickers when Pro is off.
    static func label(_ style: RouteStyle, proUnlocked: Bool) -> String {
        style == .twisty && !proUnlocked ? "\(style.rawValue) (Pro)" : style.rawValue
    }
}
