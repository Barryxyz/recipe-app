import Foundation
import Supabase

/// Food preferences (F1.7) and the user's expiry defaults (F1.6 Settings screen).
/// RLS limits everything to the signed-in user.
@MainActor
enum PrefsAPI {
    private static var app: PostgrestClient { supabase.schema("app") }
    private static var catalogDB: PostgrestClient { supabase.schema("catalog") }

    /// The device's copy when offline (F3.6).
    static func load(userId: UUID) async throws -> UserPrefs {
        let store = OfflineStore.shared
        if !Connectivity.shared.isOnline, let cached = store.prefs { return cached }
        do {
            let prefs: UserPrefs = try await app.from("user_prefs")
                .select(UserPrefs.columns)
                .eq("user_id", value: userId)
                .single()
                .execute()
                .value
            store.cache(prefs: prefs)
            return prefs
        } catch where !(error is PostgrestError) {
            if let cached = store.prefs { return cached }
            throw error
        }
    }

    static func save(_ prefs: UserPrefs, userId: UUID) async throws {
        try await app.from("user_prefs")
            .update(prefs)
            .eq("user_id", value: userId)
            .execute()
    }

    /// Catalog items marked as common staples (salt, oil, flour…), A–Z.
    static func catalogStaples() async throws -> [IngredientChoice] {
        struct Row: Decodable { let id: Int64; let name: String; let category: String?; let default_unit: String? }
        let rows: [Row] = try await catalogDB.from("ingredients")
            .select("id, name, category, default_unit")
            .eq("is_common_staple", value: true)
            .order("name")
            .execute()
            .value
        return rows.map { IngredientChoice(id: $0.id, name: $0.name, category: $0.category,
                                           defaultUnit: $0.default_unit, isCustom: false) }
    }

    /// Names for stored staple ids (catalog and custom), in the stored order.
    static func ingredients(_ ids: [Int64]) async throws -> [IngredientChoice] {
        guard !ids.isEmpty else { return [] }
        var found: [Int64: IngredientChoice] = [:]
        let catalogIds = ids.filter { $0 < PantryItem.customIdStart }.map { Int($0) }
        let customIds = ids.filter { $0 >= PantryItem.customIdStart }.map { Int($0) }
        if !catalogIds.isEmpty {
            struct Row: Decodable { let id: Int64; let name: String; let category: String?; let default_unit: String? }
            let rows: [Row] = try await catalogDB.from("ingredients")
                .select("id, name, category, default_unit").in("id", values: catalogIds).execute().value
            for r in rows {
                found[r.id] = IngredientChoice(id: r.id, name: r.name, category: r.category,
                                               defaultUnit: r.default_unit, isCustom: false)
            }
        }
        if !customIds.isEmpty {
            struct Row: Decodable { let id: Int64; let name: String }
            let rows: [Row] = try await app.from("ingredients_private")
                .select("id, name").in("id", values: customIds).execute().value
            for r in rows {
                found[r.id] = IngredientChoice(id: r.id, name: r.name, category: nil, defaultUnit: "each", isCustom: true)
            }
        }
        return ids.compactMap { found[$0] }
    }

    // MARK: Expiry defaults (F1.6)

    struct ExpiryDefault: Identifiable, Equatable {
        let ingredientId: Int64
        let name: String
        let location: StorageLocation
        var days: Int
        var id: String { "\(ingredientId)|\(location.rawValue)" }
    }

    static func expiryDefaults() async throws -> [ExpiryDefault] {
        struct Row: Decodable { let ingredient_id: Int64; let location: StorageLocation; let days: Int }
        let rows: [Row] = try await app.from("user_shelf_life_overrides")
            .select("ingredient_id, location, days")
            .is("deleted_at", value: nil)
            .execute()
            .value
        let names = Dictionary(uniqueKeysWithValues: try await ingredients(Array(Set(rows.map(\.ingredient_id))))
            .map { ($0.id, $0.name) })
        return rows.map { ExpiryDefault(ingredientId: $0.ingredient_id, name: names[$0.ingredient_id] ?? "Unknown item",
                                        location: $0.location, days: $0.days) }
            .sorted { ($0.name.lowercased(), $0.location.rawValue) < ($1.name.lowercased(), $1.location.rawValue) }
    }

    static func updateExpiryDefault(_ d: ExpiryDefault) async throws {
        try await PantryAPI.saveDefault(ingredientId: d.ingredientId, location: d.location, days: d.days)
    }

    /// Soft delete; items added later use the catalog or fallback again (F1.6).
    static func deleteExpiryDefault(_ d: ExpiryDefault) async throws {
        try await app.from("user_shelf_life_overrides")
            .update(["deleted_at": ISO8601DateFormatter().string(from: .now)])
            .eq("ingredient_id", value: Int(d.ingredientId))
            .eq("location", value: d.location.rawValue)
            .execute()
    }
}
