import Foundation
import Supabase

/// Pantry reads and writes (F1.5). RLS limits everything to the user's household and their
/// own custom items and defaults. No AI calls.
enum PantryAPI {
    private static var app: PostgrestClient { supabase.schema("app") }
    private static var catalogDB: PostgrestClient { supabase.schema("catalog") }

    // MARK: Pantry items

    /// Active items, soonest expiry first, no-expiry last.
    static func activeItems() async throws -> [PantryItem] {
        try await app.from("pantry_items")
            .select(PantryItem.columns)
            .eq("status", value: PantryItem.Status.active.rawValue)
            .is("deleted_at", value: nil)
            .order("expires_at", ascending: true, nullsFirst: false)
            .order("display_name")
            .execute()
            .value
    }

    /// Adds an item. The expiry date comes from the server (F1.6) unless the user set one.
    static func add(_ draft: ItemDraft) async throws -> PantryItem {
        guard let ingredient = draft.ingredient else { throw PantryError.noIngredient }
        let row = ItemWrite(
            ingredientId: ingredient.id, displayName: ingredient.name, quantity: draft.quantity,
            unit: draft.unit.rawValue, location: draft.location,
            expiryOverridden: draft.expiryOverridden,
            expiresAt: draft.expiryOverridden ? .some(draft.chosenExpiry) : nil,
            source: .manual)
        return try await app.from("pantry_items")
            .insert(row, returning: .representation)
            .select(PantryItem.columns)
            .single()
            .execute()
            .value
    }

    /// Saves edits. When the date isn't the user's own, it's left out so the server
    /// recalculates it if the location or ingredient changed (F1.6).
    static func update(_ id: UUID, with draft: ItemDraft) async throws -> PantryItem {
        guard let ingredient = draft.ingredient else { throw PantryError.noIngredient }
        let row = ItemWrite(
            ingredientId: ingredient.id, displayName: ingredient.name, quantity: draft.quantity,
            unit: draft.unit.rawValue, location: draft.location,
            expiryOverridden: draft.expiryOverridden,
            expiresAt: draft.expiryOverridden ? .some(draft.chosenExpiry) : nil,
            source: nil)
        return try await app.from("pantry_items")
            .update(row)
            .eq("id", value: id)
            .select(PantryItem.columns)
            .single()
            .execute()
            .value
    }

    static func setStatus(_ id: UUID, _ status: PantryItem.Status) async throws {
        try await setStatus([id], status)
    }

    /// One request for several items ("Discard all" expired, and its Undo).
    static func setStatus(_ ids: [UUID], _ status: PantryItem.Status) async throws {
        guard !ids.isEmpty else { return }
        try await app.from("pantry_items")
            .update(["status": status.rawValue])
            .in("id", values: ids.map(\.uuidString))
            .execute()
    }

    /// Soft delete (DESIGN §5): hidden everywhere, kept so offline sync can learn about it (F3.6).
    static func delete(_ id: UUID) async throws {
        try await app.from("pantry_items")
            .update(["deleted_at": ISO8601DateFormatter().string(from: .now)])
            .eq("id", value: id)
            .execute()
    }

    // MARK: Ingredients

    /// Catalog plus the user's custom items, best match first (app.search_ingredients).
    static func search(_ query: String, limit: Int = 8) async throws -> [IngredientChoice] {
        try await app.rpc("search_ingredients", params: ["q": AnyJSON.string(query), "lim": .integer(limit)])
            .execute()
            .value
    }

    /// The user's custom item with this name, created if it doesn't exist yet.
    static func customIngredient(named name: String) async throws -> IngredientChoice {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id: Int64 = try await app.rpc("get_or_create_custom_ingredient", params: ["p_name": clean])
            .execute()
            .value
        return IngredientChoice(id: id, name: clean, category: nil, defaultUnit: MeasureUnit.each.rawValue, isCustom: true)
    }

    /// Up to 10 ingredients the household added most recently, newest first.
    static func recentIngredients() async throws -> [IngredientChoice] {
        struct Recent: Decodable {
            let ingredient_id: Int64?
            let display_name: String
        }
        let rows: [Recent] = try await app.from("pantry_items")
            .select("ingredient_id, display_name")
            .not("ingredient_id", operator: .is, value: AnyJSON.null)
            .order("added_at", ascending: false)
            .limit(80)
            .execute()
            .value

        var seen = Set<Int64>()
        var recent: [(id: Int64, name: String)] = []
        for r in rows {
            guard let id = r.ingredient_id, seen.insert(id).inserted else { continue }
            recent.append((id, r.display_name))
            if recent.count == 10 { break }
        }

        let catalogIds = recent.map(\.id).filter { $0 < PantryItem.customIdStart }
        var catalogInfo: [Int64: IngredientChoice] = [:]
        if !catalogIds.isEmpty {
            struct Row: Decodable { let id: Int64; let name: String; let category: String?; let default_unit: String? }
            let found: [Row] = try await catalogDB.from("ingredients")
                .select("id, name, category, default_unit")
                .in("id", values: catalogIds.map { Int($0) })
                .execute()
                .value
            for r in found {
                catalogInfo[r.id] = IngredientChoice(id: r.id, name: r.name, category: r.category,
                                                     defaultUnit: r.default_unit, isCustom: false)
            }
        }
        return recent.compactMap { r in
            if r.id >= PantryItem.customIdStart {
                return IngredientChoice(id: r.id, name: r.name, category: nil, defaultUnit: "each", isCustom: true)
            }
            return catalogInfo[r.id]
        }
    }

    /// Choice for an existing pantry item (edit sheet).
    static func choice(for item: PantryItem) async throws -> IngredientChoice {
        guard let id = item.ingredientId, !item.isCustom else {
            return IngredientChoice(id: item.ingredientId ?? 0, name: item.displayName, category: nil,
                                    defaultUnit: item.unit, isCustom: true)
        }
        struct Row: Decodable { let category: String?; let default_unit: String? }
        let row: Row? = try await catalogDB.from("ingredients")
            .select("category, default_unit").eq("id", value: Int(id)).maybeSingle().execute().value
        return IngredientChoice(id: id, name: item.displayName, category: row?.category,
                                defaultUnit: row?.default_unit, isCustom: false)
    }

    // MARK: Expiry (F1.6)

    static func shelfLife(for ingredientId: Int64) async throws -> CatalogShelfLife? {
        guard ingredientId < PantryItem.customIdStart else { return nil }
        struct Row: Decodable {
            let shelf_life_fridge_days: Int?
            let shelf_life_freezer_days: Int?
            let shelf_life_pantry_days: Int?
        }
        let row: Row? = try await catalogDB.from("ingredients")
            .select("shelf_life_fridge_days, shelf_life_freezer_days, shelf_life_pantry_days")
            .eq("id", value: Int(ingredientId))
            .maybeSingle()
            .execute()
            .value
        return row.map { CatalogShelfLife(fridge: $0.shelf_life_fridge_days, freezer: $0.shelf_life_freezer_days,
                                          pantry: $0.shelf_life_pantry_days) }
    }

    static func userDefaults() async throws -> [ExpiryCalculator.DefaultKey: Int] {
        struct Row: Decodable { let ingredient_id: Int64; let location: StorageLocation; let days: Int }
        let rows: [Row] = try await app.from("user_shelf_life_overrides")
            .select("ingredient_id, location, days")
            .is("deleted_at", value: nil)
            .execute()
            .value
        return Dictionary(rows.map { (.init(ingredientId: $0.ingredient_id, location: $0.location), $0.days) },
                          uniquingKeysWith: { a, _ in a })
    }

    /// "Always use N days for <ingredient>" at this location.
    static func saveDefault(ingredientId: Int64, location: StorageLocation, days: Int) async throws {
        struct Row: Encodable {
            let ingredient_id: Int64
            let location: StorageLocation
            let days: Int
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(ingredient_id, forKey: .ingredient_id)
                try c.encode(location, forKey: .location)
                try c.encode(days, forKey: .days)
                try c.encodeNil(forKey: .deleted_at)   // revive a previously deleted default
            }
            enum CodingKeys: String, CodingKey { case ingredient_id, location, days, deleted_at }
        }
        try await app.from("user_shelf_life_overrides")
            .upsert(Row(ingredient_id: ingredientId, location: location, days: days),
                    onConflict: "user_id,ingredient_id,location")
            .execute()
    }

    /// Other active items whose date comes from the rule for this ingredient and location.
    static func itemsUsingDefault(ingredientId: Int64, location: StorageLocation, excluding: UUID?) async throws -> [UUID] {
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await app.from("pantry_items")
            .select("id")
            .eq("ingredient_id", value: Int(ingredientId))
            .eq("location", value: location.rawValue)
            .eq("status", value: PantryItem.Status.active.rawValue)
            .eq("expiry_overridden", value: false)
            .is("deleted_at", value: nil)
            .execute()
            .value
        return rows.map(\.id).filter { $0 != excluding }
    }

    /// Clearing expires_at makes the server recalculate it (F1.6).
    static func recalculateExpiry(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        try await app.from("pantry_items")
            .update(NullExpiry())
            .in("id", values: ids.map(\.uuidString))
            .execute()
    }
}

enum PantryError: LocalizedError {
    case noIngredient
    var errorDescription: String? { "Pick an ingredient first." }
}

/// Insert/update payload. Encodes explicit nulls where they matter: quantity nil means
/// "some", and an overridden nil date means "no expiry".
private struct ItemWrite: Encodable {
    let ingredientId: Int64
    let displayName: String
    let quantity: Double?
    let unit: String
    let location: StorageLocation
    let expiryOverridden: Bool
    /// nil = leave to the server; .some(nil) = no expiry; .some(date) = user's date.
    let expiresAt: Date??
    let source: PantryItem.Source?

    enum CodingKeys: String, CodingKey {
        case ingredientId = "ingredient_id", displayName = "display_name", quantity, unit, location
        case expiryOverridden = "expiry_overridden", expiresAt = "expires_at", source
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(ingredientId, forKey: .ingredientId)
        try c.encode(displayName, forKey: .displayName)
        if let quantity { try c.encode(quantity, forKey: .quantity) } else { try c.encodeNil(forKey: .quantity) }
        try c.encode(unit, forKey: .unit)
        try c.encode(location, forKey: .location)
        try c.encode(expiryOverridden, forKey: .expiryOverridden)
        if case .some(let date) = expiresAt {
            if let date { try c.encode(date, forKey: .expiresAt) } else { try c.encodeNil(forKey: .expiresAt) }
        }
        if let source { try c.encode(source, forKey: .source) }
    }
}

private struct NullExpiry: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNil(forKey: .expires_at)
    }
    enum CodingKeys: String, CodingKey { case expires_at }
}
