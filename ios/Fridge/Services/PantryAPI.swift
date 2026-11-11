import Foundation
import Supabase

/// Pantry reads and writes (F1.5). RLS limits everything to the user's household and their
/// own custom items and defaults. No AI calls.
@MainActor
enum PantryAPI {
    private static var app: PostgrestClient { supabase.schema("app") }
    private static var catalogDB: PostgrestClient { supabase.schema("catalog") }

    // MARK: Pantry items

    /// Active items, soonest expiry first, no-expiry last.
    /// Active items from the device's copy (F3.6), after a quick sync when online. Every read
    /// also reschedules the expiry reminders (F5.1).
    static func activeItems() async throws -> [PantryItem] {
        let store = OfflineStore.shared
        await store.refresh()
        let items = store.activePantry
        await ExpiryReminders.shared.update(with: items)
        return items
    }

    /// Adds an item on the device and queues it (F3.6). The date is the user's, or the F1.6
    /// rule's preview until the server's value arrives. An item picked offline as a new custom
    /// ingredient (id 0) is created on the server when it syncs.
    static func add(_ draft: ItemDraft) async throws -> PantryItem {
        guard let ingredient = draft.ingredient else { throw PantryError.noIngredient }
        let store = OfflineStore.shared
        let now = Date.now
        let ingredientId: Int64? = ingredient.id == 0 ? nil : ingredient.id
        let item = PantryItem(
            id: UUID(), ingredientId: ingredientId, displayName: ingredient.name, quantity: draft.quantity,
            unit: draft.unit.rawValue, location: draft.location, addedAt: now,
            expiresAt: draft.expiryOverridden ? draft.chosenExpiry
                : store.previewExpiry(ingredientId: ingredientId, location: draft.location, addedAt: now),
            expiryOverridden: draft.expiryOverridden, status: .active, source: .manual, isStaple: draft.isStaple)
        store.save(pantry: item, customName: ingredientId == nil ? ingredient.name : nil)
        await ExpiryReminders.shared.pantrySaved()
        return item
    }

    /// Saves edits on the device and queues them. A rule-based date follows a new location or
    /// ingredient (the server recalculates it too).
    static func update(_ id: UUID, with draft: ItemDraft) async throws -> PantryItem {
        guard let ingredient = draft.ingredient else { throw PantryError.noIngredient }
        let store = OfflineStore.shared
        guard var item = store.pantryItem(id) else { throw PantryError.notFound }
        let newId: Int64? = ingredient.id == 0 ? nil : ingredient.id
        let moved = item.location != draft.location || item.ingredientId != newId || item.expiryOverridden
        item.ingredientId = newId
        item.displayName = ingredient.name
        item.quantity = draft.quantity
        item.unit = draft.unit.rawValue
        item.location = draft.location
        item.isStaple = draft.isStaple
        if draft.expiryOverridden {
            item.expiresAt = draft.chosenExpiry
        } else if moved {
            item.expiresAt = store.previewExpiry(ingredientId: newId, location: draft.location, addedAt: item.addedAt)
        }
        item.expiryOverridden = draft.expiryOverridden
        store.save(pantry: item, customName: newId == nil ? ingredient.name : nil)
        await ExpiryReminders.shared.pantryChanged()
        return item
    }

    static func setStatus(_ id: UUID, _ status: PantryItem.Status) async throws {
        try await setStatus([id], status)
    }

    /// Several items at once ("Discard all" expired, and its Undo), on the device and queued.
    static func setStatus(_ ids: [UUID], _ status: PantryItem.Status) async throws {
        let store = OfflineStore.shared
        for id in ids {
            guard var item = store.pantryItem(id) else { continue }
            item.status = status
            item.statusChangedAt = status == .active ? nil : .now
            store.save(pantry: item)
        }
        await ExpiryReminders.shared.pantryChanged()
    }

    /// Soft delete (DESIGN §5), so other devices learn about it (F3.6).
    static func delete(_ id: UUID) async throws {
        let store = OfflineStore.shared
        guard var item = store.pantryItem(id) else { return }
        item.deletedAt = .now
        store.save(pantry: item)
        await ExpiryReminders.shared.pantryChanged()
    }

    /// Adds staples (onboarding), skipping ingredients the household already has as a staple.
    /// "some", no expiry.
    static func addStaples(_ choices: [IngredientChoice]) async throws {
        guard !choices.isEmpty else { return }
        struct Row: Decodable { let ingredient_id: Int64? }
        let existing: [Row] = try await app.from("pantry_items")
            .select("ingredient_id")
            .eq("is_staple", value: true)
            .eq("status", value: PantryItem.Status.active.rawValue)
            .is("deleted_at", value: nil)
            .execute()
            .value
        let have = Set(existing.compactMap(\.ingredient_id))
        let rows: [ItemWrite] = choices.filter { !have.contains($0.id) }.map { c in
            var d = ItemDraft()
            d.pick(c, sessionPlacement: .staples)
            return ItemWrite(ingredientId: c.id, displayName: c.name, quantity: nil, unit: d.unit.rawValue,
                             location: d.location, expiryOverridden: true, expiresAt: .some(nil),
                             source: .manual, isStaple: true)
        }
        guard !rows.isEmpty else { return }
        try await app.from("pantry_items").insert(rows).execute()
        OfflineStore.shared.markStale()
    }

    /// Catalog ids of the common staples, so the add sheet can switch "Staple" on for them.
    static func catalogStapleIds() async throws -> Set<Int64> {
        let store = OfflineStore.shared
        if store.hasCatalog { return Set(store.catalogStaples.map(\.id)) }
        return Set(try await PrefsAPI.catalogStaples().map(\.id))
    }

    // MARK: Ingredients

    /// Catalog plus the user's custom items, best match first (app.search_ingredients).
    /// Offline (F3.6): the same search over the device's copy of the catalog and custom items.
    static func search(_ query: String, limit: Int = 8) async throws -> [IngredientChoice] {
        let store = OfflineStore.shared
        if !Connectivity.shared.isOnline && store.hasCatalog { return store.search(query, limit: limit) }
        do {
            return try await app.rpc("search_ingredients", params: ["q": AnyJSON.string(query), "lim": .integer(limit)])
                .execute()
                .value
        } catch {
            if store.hasCatalog && !(error is PostgrestError) { return store.search(query, limit: limit) }
            throw error
        }
    }

    /// The user's custom item with this name, created if it doesn't exist yet.
    /// Offline (F3.6): id 0, and the item is created on the server when the pantry row syncs.
    static func customIngredient(named name: String) async throws -> IngredientChoice {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let offline = IngredientChoice(id: 0, name: clean, category: nil, defaultUnit: MeasureUnit.each.rawValue, isCustom: true)
        guard Connectivity.shared.isOnline else { return offline }
        do {
            let id: Int64 = try await app.rpc("get_or_create_custom_ingredient", params: ["p_name": clean])
                .execute()
                .value
            return IngredientChoice(id: id, name: clean, category: nil, defaultUnit: MeasureUnit.each.rawValue, isCustom: true)
        } catch where !(error is PostgrestError) {
            return offline
        }
    }

    /// Up to 10 ingredients the household added most recently, newest first.
    static func recentIngredients() async throws -> [IngredientChoice] {
        let store = OfflineStore.shared
        if store.hasCatalog {
            var seen = Set<Int64>()
            return store.allPantry.compactMap { item -> IngredientChoice? in
                guard let id = item.ingredientId, seen.insert(id).inserted else { return nil }
                if id >= PantryItem.customIdStart {
                    return IngredientChoice(id: id, name: item.displayName, category: nil, defaultUnit: "each", isCustom: true)
                }
                return store.catalogItem(id)?.choice
            }.prefix(10).map { $0 }
        }
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
        if let c = OfflineStore.shared.catalogItem(id) {
            return IngredientChoice(id: id, name: item.displayName, category: c.category, defaultUnit: c.default_unit, isCustom: false)
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
        if let c = OfflineStore.shared.catalogItem(ingredientId) { return c.shelfLife }
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

    /// Catalog shelf lives for several ingredients (scan review previews).
    static func shelfLives(for ids: [Int64]) async throws -> [Int64: CatalogShelfLife] {
        let catalogIds = Array(Set(ids.filter { $0 > 0 && $0 < PantryItem.customIdStart })).map { Int($0) }
        guard !catalogIds.isEmpty else { return [:] }
        let store = OfflineStore.shared
        if store.hasCatalog {
            return Dictionary(uniqueKeysWithValues: catalogIds.compactMap { id in
                store.catalogItem(Int64(id)).map { (Int64(id), $0.shelfLife) }
            })
        }
        struct Row: Decodable {
            let id: Int64
            let shelf_life_fridge_days: Int?
            let shelf_life_freezer_days: Int?
            let shelf_life_pantry_days: Int?
        }
        let rows: [Row] = try await catalogDB.from("ingredients")
            .select("id, shelf_life_fridge_days, shelf_life_freezer_days, shelf_life_pantry_days")
            .in("id", values: catalogIds)
            .execute()
            .value
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, CatalogShelfLife(fridge: $0.shelf_life_fridge_days, freezer: $0.shelf_life_freezer_days,
                                     pantry: $0.shelf_life_pantry_days))
        })
    }

    /// The user's expiry defaults; the device's copy when offline (F3.6).
    static func userDefaults() async throws -> [ExpiryCalculator.DefaultKey: Int] {
        struct Row: Decodable { let ingredient_id: Int64; let location: StorageLocation; let days: Int }
        let store = OfflineStore.shared
        guard Connectivity.shared.isOnline else { return store.expiryDefaults }
        do {
            let rows: [Row] = try await app.from("user_shelf_life_overrides")
                .select("ingredient_id, location, days")
                .is("deleted_at", value: nil)
                .execute()
                .value
            let d = Dictionary(rows.map { (ExpiryCalculator.DefaultKey(ingredientId: $0.ingredient_id, location: $0.location), $0.days) },
                               uniquingKeysWith: { a, _ in a })
            store.cache(expiryDefaults: d)
            return d
        } catch where !(error is PostgrestError) {
            return store.expiryDefaults
        }
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
        OfflineStore.shared.markStale()
    }
}

enum PantryError: LocalizedError {
    case noIngredient, notFound
    var errorDescription: String? {
        self == .noIngredient ? "Pick an ingredient first." : "This item isn't in your pantry any more."
    }
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
    let isStaple: Bool

    enum CodingKeys: String, CodingKey {
        case ingredientId = "ingredient_id", displayName = "display_name", quantity, unit, location
        case expiryOverridden = "expiry_overridden", expiresAt = "expires_at", source
        case isStaple = "is_staple"
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
        try c.encode(isStaple, forKey: .isStaple)
    }
}

private struct NullExpiry: Encodable {
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeNil(forKey: .expires_at)
    }
    enum CodingKeys: String, CodingKey { case expires_at }
}
