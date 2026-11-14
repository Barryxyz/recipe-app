import Foundation
import Supabase

/// F3.1 / F3.3: saved recipes. RLS limits everything to the user's own recipes.
@MainActor
enum SavedRecipesAPI {
    private static var app: PostgrestClient { supabase.schema("app") }

    static let columns = "id, title, description, servings, prep_min, cook_min, steps, macros_per_serving, " +
        "macros_total, source, model_version, updated_at, share_token, " +
        "recipe_ingredients(position, ingredient_id, name, quantity, unit, grams, note, is_optional)"

    /// Newest first (updated_at), deleted ones left out.
    /// Offline (F3.6): the last list the device saw, read-only.
    static func list() async throws -> [SavedRecipe] {
        let store = OfflineStore.shared
        if !Connectivity.shared.isOnline, let cached = try? cachedList() { return cached }
        do {
            let response = try await app.from("recipes")
                .select(columns)
                .is("deleted_at", value: nil)
                .order("updated_at", ascending: false)
                .execute()
            store.cache(recipesJSON: response.data)
            return try PostgrestClient.Configuration.jsonDecoder.decode([SavedRecipe].self, from: response.data)
        } catch where !(error is PostgrestError) {
            if let cached = try? cachedList() { return cached }
            throw error
        }
    }

    /// The device's copy of the saved recipes (nil if there's none yet).
    static func cachedList() throws -> [SavedRecipe]? {
        guard let data = OfflineStore.shared.recipesJSON else { return nil }
        return try PostgrestClient.Configuration.jsonDecoder.decode([SavedRecipe].self, from: data)
    }

    /// Ids of recipes that are still saved (not deleted).
    static func activeIds(among ids: [UUID]) async throws -> Set<UUID> {
        guard !ids.isEmpty else { return [] }
        struct Row: Decodable { let id: UUID }
        let rows: [Row] = try await app.from("recipes").select("id")
            .in("id", values: ids.map(\.uuidString)).is("deleted_at", value: nil)
            .execute().value
        return Set(rows.map(\.id))
    }

    /// Saves a generated recipe with its ingredients in one transaction; returns the new id.
    static func save(_ recipe: RecipeAPI.Recipe) async throws -> UUID {
        struct Params: Encodable { let recipe: RecipeAPI.Recipe }
        return try await app.rpc("save_recipe", params: Params(recipe: recipe)).execute().value
    }

    static func get(_ id: UUID) async throws -> SavedRecipe {
        do {
            return try await app.from("recipes").select(columns).eq("id", value: id).single().execute().value
        } catch where !(error is PostgrestError) {
            if let r = (try? cachedList())??.first(where: { $0.id == id }) { return r }
            throw error
        }
    }

    /// Replaces the recipe's fields and ingredients in one transaction (F3.2).
    static func update(_ id: UUID, _ draft: RecipeEditDraft) async throws {
        struct Params: Encodable { let p_id: UUID; let recipe: RecipeEditDraft.Payload }
        try await app.rpc("update_recipe", params: Params(p_id: id, recipe: draft.payload())).execute()
    }

    /// The recipe's share token: the existing one, or a new one (F4.1).
    static func createShareLink(_ id: UUID) async throws -> String {
        try await app.rpc("create_share_link", params: ["p_recipe_id": id.uuidString]).execute().value
    }

    /// The old link stops working; sharing again makes a new one.
    static func stopSharing(_ id: UUID) async throws {
        try await app.rpc("stop_sharing", params: ["p_recipe_id": id.uuidString]).execute()
    }

    /// Server-side macros from catalog data (F2.3).
    static func recomputeMacros(_ id: UUID) async throws {
        // F5.3: unknown ingredients are only estimated by the AI with the user's consent.
        struct Body: Encodable { let recipe_id: UUID; let estimate: Bool }
        struct Out: Decodable { let recipe_id: String }
        let _: Out = try await supabase.functions.invoke(
            "recompute-macros",
            options: FunctionInvokeOptions(body: Body(recipe_id: id, estimate: AIConsent.shared.granted), timeoutInterval: 60))
    }

    /// Soft delete (F3.3): undo just clears deleted_at.
    static func setDeleted(_ id: UUID, _ deleted: Bool) async throws {
        struct Row: Encodable {
            let deleted_at: Date?
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let deleted_at { try c.encode(ISO8601DateFormatter().string(from: deleted_at), forKey: .deleted_at) }
                else { try c.encodeNil(forKey: .deleted_at) }
            }
            enum CodingKeys: String, CodingKey { case deleted_at }
        }
        try await app.from("recipes").update(Row(deleted_at: deleted ? Date() : nil)).eq("id", value: id).execute()
    }
}
