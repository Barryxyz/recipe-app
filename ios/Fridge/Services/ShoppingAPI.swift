import Foundation
import Observation
import Supabase

/// F3.5: the household shopping list. RLS limits everything to the user's household.
enum ShoppingAPI {
    private static var app: PostgrestClient { supabase.schema("app") }

    static func list() async throws -> [ShoppingItem] {
        let items: [ShoppingItem] = try await app.from("shopping_list_items")
            .select(ShoppingItem.columns)
            .is("deleted_at", value: nil)
            .order("created_at")
            .execute().value
        await ShoppingBadge.shared.set(items.filter { !$0.checked }.count)
        return items
    }

    /// Adds rows or merges into existing ones (one transaction). Returns how many.
    @discardableResult
    static func add(_ adds: [ShoppingPlan.Add]) async throws -> Int {
        struct Params: Encodable { let items: [ShoppingPlan.Add] }
        let n: Int = try await app.rpc("add_shopping_items", params: Params(items: adds)).execute().value
        _ = try? await list()
        return n
    }

    static func setChecked(_ id: UUID, _ checked: Bool) async throws {
        try await app.from("shopping_list_items").update(["checked": checked]).eq("id", value: id).execute()
    }

    static func update(_ id: UUID, quantity: Double?, unit: String?) async throws {
        struct Row: Encodable {
            let quantity: Double?
            let unit: String?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(quantity, forKey: .quantity)      // null = "some"
                try c.encode(unit, forKey: .unit)
            }
            enum CodingKeys: String, CodingKey { case quantity, unit }
        }
        try await app.from("shopping_list_items").update(Row(quantity: quantity, unit: unit)).eq("id", value: id).execute()
    }

    static func delete(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await app.from("shopping_list_items").delete().in("id", values: ids.map(\.uuidString)).execute()
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
    static func moveToPantry(_ items: [Bought]) async throws -> Int {
        struct Params: Encodable { let items: [Bought] }
        let n: Int = try await app.rpc("move_bought_to_pantry", params: Params(items: items)).execute().value
        await ExpiryReminders.shared.pantryChanged()
        return n
    }

    /// Catalog categories, for the aisles and default pantry locations.
    static func categories(_ ids: [Int64]) async throws -> [Int64: String] {
        let catalogIds = Array(Set(ids.filter { $0 < PantryItem.customIdStart }))
        guard !catalogIds.isEmpty else { return [:] }
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
