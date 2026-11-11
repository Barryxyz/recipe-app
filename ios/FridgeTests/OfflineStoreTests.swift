import XCTest
@testable import Fridge

/// F3.6: what the device shows from its own copy: active items, offline search, expiry preview,
/// and the outbox keeping one entry per row.
@MainActor
final class OfflineStoreTests: XCTestCase {
    let store = OfflineStore.shared

    private func item(_ name: String, days: Double?, status: PantryItem.Status = .active, deleted: Bool = false) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: 1, displayName: name, quantity: 1, unit: "each", location: .fridge,
                   addedAt: .now, expiresAt: days.map { Date.now.addingTimeInterval($0 * 86400) }, expiryOverridden: false,
                   status: status, source: .manual, isStaple: false, deletedAt: deleted ? .now : nil)
    }

    private func catalog(_ id: Int64, _ name: String, aliases: [String] = [], fridge: Int? = nil) -> OfflineStore.CatalogItem {
        .init(id: id, name: name, aliases: aliases, category: "produce", default_unit: "each", shelf_life_fridge_days: fridge,
              shelf_life_freezer_days: nil, shelf_life_pantry_days: nil, is_common_staple: false)
    }

    override func tearDown() async throws { store.setStateForTests(.init()) }

    func testActivePantryHidesUsedAndDeletedAndSortsByExpiry() {
        var s = OfflineStore.State()
        s.pantry = [item("rice", days: nil), item("milk", days: 1), item("old", days: 0, status: .used),
                    item("gone", days: 0, deleted: true), item("eggs", days: 3)]
        store.setStateForTests(s)
        XCTAssertEqual(store.activePantry.map(\.displayName), ["milk", "eggs", "rice"])
    }

    func testOfflineSearchUsesNamesAliasesAndCustomItems() {
        var s = OfflineStore.State()
        s.catalog = [catalog(1, "green onion", aliases: ["scallion"]), catalog(2, "onion"), catalog(3, "red onion powder")]
        s.customs = [IngredientChoice(id: 1_000_000_000_001, name: "Onion jam", category: nil, defaultUnit: "each", isCustom: true)]
        store.setStateForTests(s)
        XCTAssertEqual(store.search("onion", limit: 5).map(\.name).first, "onion", "exact name first")
        XCTAssertEqual(store.search("scall", limit: 5).map(\.name), ["green onion"], "aliases count")
        XCTAssertTrue(store.search("jam", limit: 5).first?.isCustom == true)
        XCTAssertTrue(store.search("zzz", limit: 5).isEmpty)
    }

    func testExpiryPreviewUsesCachedCatalogAndDefaults() {
        var s = OfflineStore.State()
        s.catalog = [catalog(7, "spinach", fridge: 5)]
        s.expiryDefaults = ["8|fridge": 2]
        store.setStateForTests(s)
        let added = Date.now
        let cal = Calendar.current
        let days = { (d: Date) in cal.dateComponents([.day], from: cal.startOfDay(for: added), to: cal.startOfDay(for: d)).day! }
        XCTAssertEqual(days(store.previewExpiry(ingredientId: 7, location: .fridge, addedAt: added)), 5)
        XCTAssertEqual(days(store.previewExpiry(ingredientId: 8, location: .fridge, addedAt: added)), 2, "the user's default wins")
        XCTAssertEqual(days(store.previewExpiry(ingredientId: nil, location: .freezer, addedAt: added)), 90, "fallback")
    }
}
