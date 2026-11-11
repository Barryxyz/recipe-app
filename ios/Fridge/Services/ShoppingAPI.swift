import Foundation
import Observation
import Supabase

/// F3.5: the household shopping list. RLS limits everything to the user's household.
@MainActor
enum ShoppingAPI {
    private static var app: PostgrestClient { supabase.schema("app") }

    /// The list from the device's copy (F3.6), after a quick sync when online.
    static func list() async throws -> [ShoppingItem] {
        let store = OfflineStore.shared
        await store.refresh()
        let items = store.shoppingItems
        ShoppingBadge.shared.set(items.filter { !$0.checked }.count)
        return items
    }

    /// Adds rows or merges into existing ones, on the device; synced later (F3.6). Merges follow
    /// app.add_shopping_items: amounts add up, a row without an amount takes the new one.
    /// Returns how many.
    @discardableResult
    static func add(_ adds: [ShoppingPlan.Add]) async throws -> Int {
        let store = OfflineStore.shared
        let savedRecipeIds = Set(((try? SavedRecipesAPI.cachedList()) ?? []).map(\.id))
        for a in adds {
            if let mid = a.merge_id, var row = store.shoppingItem(mid), !row.checked, row.deletedAt == nil {
                if let q = a.quantity { row.quantity = (row.quantity ?? 0) + q }
                if row.unit == nil { row.unit = a.unit }
                store.save(shopping: row)
                continue
            }
            let name = a.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            store.save(shopping: ShoppingItem(
                id: UUID(), ingredientId: a.ingredient_id, name: String(name.prefix(100)), quantity: a.quantity,
                unit: a.unit, sourceRecipeId: a.source_recipe_id.flatMap { savedRecipeIds.contains($0) ? $0 : nil },
                sourceRecipeTitle: a.source_recipe_title.map { String($0.prefix(200)) }, checked: false, createdAt: .now))
        }
        return adds.count
    }

    static func setChecked(_ id: UUID, _ checked: Bool) async throws {
        let store = OfflineStore.shared
        guard var row = store.shoppingItem(id) else { return }
        row.checked = checked
        store.save(shopping: row)
    }

    static func update(_ id: UUID, quantity: Double?, unit: String?) async throws {
        let store = OfflineStore.shared
        guard var row = store.shoppingItem(id) else { return }
        row.quantity = quantity
        row.unit = unit
        store.save(shopping: row)
    }

    /// Soft delete, so other devices learn about it (F3.6).
    static func delete(_ ids: [UUID]) async throws {
        let store = OfflineStore.shared
        for id in ids {
            guard var row = store.shoppingItem(id) else { continue }
            row.deletedAt = .now
            store.save(shopping: row)
        }
    }

    struct Bought: Encodable {
        let id: UUID
        let location: String
        let quantity: Double?
        let unit: String?
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(location, forKey: .location)
            try c.encode(quantity, forKey: .quantity)
            try c.encodeIfPresent(unit, forKey: .unit)
        }
        enum CodingKeys: String, CodingKey { case id, location, quantity, unit }
    }

    /// Checked rows -> pantry items (one transaction); the rows are removed. Returns how many.
    /// Needs the server (it creates the pantry items); pending list changes are sent first.
    static func moveToPantry(_ items: [Bought]) async throws -> Int {
        struct Params: Encodable { let items: [Bought] }
        await OfflineStore.shared.sync()
        let n: Int = try await app.rpc("move_bought_to_pantry", params: Params(items: items)).execute().value
        await ExpiryReminders.shared.pantryChanged()
        return n
    }

    /// Catalog categories, for the aisles and default pantry locations.
    static func categories(_ ids: [Int64]) async throws -> [Int64: String] {
        let catalogIds = Array(Set(ids.filter { $0 < PantryItem.customIdStart }))
        guard !catalogIds.isEmpty else { return [:] }
        let store = OfflineStore.shared
        if store.hasCatalog {
            return Dictionary(uniqueKeysWithValues: catalogIds.compactMap { id in
                store.catalogItem(id)?.category.map { (id, $0) }
            })
        }
        struct Row: Decodable { let id: Int64; let category: String? }
        let rows: [Row] = try await supabase.schema("catalog").from("ingredients")
            .select("id, category").in("id", values: catalogIds.map { Int($0) }).execute().value
        return Dictionary(uniqueKeysWithValues: rows.compactMap { r in r.category.map { (r.id, $0) } })
    }
}

/// The number on the Shopping tab: items still to buy.
@MainActor @Observable
final class ShoppingBadge {
    static let shared = ShoppingBadge()
    private(set) var count = 0
    func set(_ n: Int) { count = n }

    func refresh() async { _ = try? await ShoppingAPI.list() }
}
