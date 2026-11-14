import Foundation
import Observation
import StoreKit
import Supabase

/// F0.6: the monthly and yearly subscriptions (StoreKit 2). The server decides access: after
/// a purchase, a restore, or at launch while its record is missing or expired, the app sends
/// Apple's signed transaction to `verify-subscription`. While `REQUIRE_PURCHASE=false` on the
/// server, nothing is blocked; the paywall is still reachable from Settings.
@MainActor @Observable
final class SubscriptionStore {
    static let shared = SubscriptionStore()

    static let productIds = ["com.barryxyz.fridge.monthly", "com.barryxyz.fridge.yearly"]

    struct ServerStatus: Decodable, Equatable {
        let active: Bool
        let product: String?
        let expires_at: Date?
    }

    private(set) var products: [Product] = []
    private(set) var loadedProducts = false
    private(set) var status: ServerStatus?
    private(set) var busy = false
    var message: String?
    /// Set when an AI feature answers 402 subscription_required (or from Settings).
    var showPaywall = false

    private var updates: Task<Void, Never>?

    private init() {}

    var monthly: Product? { products.first { $0.id == Self.productIds[0] } }
    var yearly: Product? { products.first { $0.id == Self.productIds[1] } }

    /// "Save 44%": the yearly price against 12 months of the monthly one.
    static func savingsPercent(monthly: Decimal, yearly: Decimal) -> Int? {
        let twelve = monthly * 12
        guard twelve > 0, yearly < twelve else { return nil }
        let saving = NSDecimalNumber(decimal: (twelve - yearly) / twelve).doubleValue
        return Int((saving * 100).rounded(.down))
    }

    // MARK: Launch

    /// Listens for renewals and purchases made elsewhere, and catches the server up.
    func start() async {
        if updates == nil {
            updates = Task {
                for await result in Transaction.updates { await handle(result) }
            }
        }
        await refreshStatus()
        if status?.active != true { await sendCurrentEntitlements() }
    }

    func loadProducts() async {
        guard !loadedProducts || products.isEmpty else { return }
        do {
            products = try await Product.products(for: Self.productIds)
                .sorted { ($0.subscription?.subscriptionPeriod.unit == .year ? 0 : 1) < ($1.subscription?.subscriptionPeriod.unit == .year ? 0 : 1) }
        } catch {
            products = []
        }
        loadedProducts = true
    }

    /// The account's subscription as the server has it (the user's own app.users row).
    func refreshStatus() async {
        guard let uid = supabase.auth.currentUser?.id else { return }
        struct Row: Decodable { let subscription_product: String?; let subscription_expires_at: Date? }
        if let row: Row = try? await supabase.schema("app").from("users")
            .select("subscription_product, subscription_expires_at").eq("id", value: uid).single().execute().value {
            status = ServerStatus(active: (row.subscription_expires_at ?? .distantPast) > .now,
                                  product: row.subscription_product, expires_at: row.subscription_expires_at)
        }
    }

    /// Delete account: the next account starts without the old one's status.
    func reset() { status = nil; message = nil; showPaywall = false }

    // MARK: Purchase / restore

    func purchase(_ product: Product) async {
        guard let uid = supabase.auth.currentUser?.id else { message = "Sign-in isn't ready yet. Try again."; return }
        busy = true
        defer { busy = false }
        do {
            // appAccountToken ties the transaction to this account, so it can't unlock another.
            switch try await product.purchase(options: [.appAccountToken(uid)]) {
            case .success(let result):
                await handle(result)
                if status?.active == true { showPaywall = false }
            case .pending:
                message = "Your purchase is waiting for approval. It will unlock when it's approved."
            case .userCancelled:
                break
            @unknown default:
                break
            }
        } catch {
            message = "The purchase didn't go through. \(error.localizedDescription)"
        }
    }

    /// Restore purchases: may ask the user to sign in to their Apple ID (only when tapped).
    func restore() async {
        busy = true
        defer { busy = false }
        do { try await AppStore.sync() } catch {
            message = "Couldn't reach the App Store. \(error.localizedDescription)"
            return
        }
        await sendCurrentEntitlements()
        if status?.active == true { showPaywall = false } else { message = "No active subscription was found for this Apple ID." }
    }

    private func sendCurrentEntitlements() async {
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productType == .autoRenewable, Self.productIds.contains(t.productID) {
                await send(result)
            }
        }
    }

    /// Sends the signed transaction to the server; the transaction is finished once the
    /// server has it (StoreKit delivers unfinished ones again, so nothing is lost offline).
    private func handle(_ result: VerificationResult<Transaction>) async {
        guard case .verified(let t) = result else { return }
        if await send(result) || t.revocationDate != nil { await t.finish() }
    }

    @discardableResult
    private func send(_ result: VerificationResult<Transaction>) async -> Bool {
        struct Body: Encodable { let signed_transaction: String }
        do {
            let s: ServerStatus = try await supabase.functions.invoke(
                "verify-subscription", options: FunctionInvokeOptions(body: Body(signed_transaction: result.jwsRepresentation)),
                decoder: ScanAPI.decoder)
            status = s
            return true
        } catch {
            message = "Your purchase is saved, but we couldn't confirm it with the server yet. It will retry automatically."
            return false
        }
    }
}
