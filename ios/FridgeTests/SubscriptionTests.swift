import StoreKit
import StoreKitTest
import XCTest
@testable import Fridge

/// F0.6: products from a local StoreKit configuration (no App Store needed), a simulated
/// purchase tagged with the account id, and the "Save N%" figure.
@MainActor
final class SubscriptionTests: XCTestCase {
    func testSavingsPercent() {
        XCTAssertEqual(SubscriptionStore.savingsPercent(monthly: 2.99, yearly: 19.99), 44)
        XCTAssertNil(SubscriptionStore.savingsPercent(monthly: 1, yearly: 12), "no saving: no badge")
        XCTAssertNil(SubscriptionStore.savingsPercent(monthly: 0, yearly: 10))
    }

    func testProductsAndAPurchaseCarryingTheAccountId() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Subscriptions", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.disableDialogs = true
        session.clearTransactions()

        let products = try await Product.products(for: SubscriptionStore.productIds)
        XCTAssertEqual(Set(products.map(\.id)), Set(SubscriptionStore.productIds))
        let yearly = try XCTUnwrap(products.first { $0.id == SubscriptionStore.productIds[1] })
        XCTAssertEqual(yearly.subscription?.subscriptionPeriod.unit, .year)
        XCTAssertEqual(yearly.subscription?.introductoryOffer?.paymentMode, .freeTrial)

        let account = UUID()
        let result = try await yearly.purchase(options: [.appAccountToken(account)])
        guard case .success(let verification) = result, case .verified(let t) = verification else {
            return XCTFail("purchase didn't succeed: \(result)")
        }
        XCTAssertEqual(t.appAccountToken, account, "the server checks this against the signed-in user")
        XCTAssertEqual(t.productType, .autoRenewable)
        XCTAssertFalse(verification.jwsRepresentation.isEmpty, "the signed value sent to verify-subscription")
        await t.finish()
    }
}
