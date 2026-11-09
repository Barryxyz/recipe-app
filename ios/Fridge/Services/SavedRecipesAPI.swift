import Foundation
import Supabase

/// F3.1 / F3.3: saved recipes. RLS limits everything to the user's own recipes.
enum SavedRecipesAPI {
    private static var app: PostgrestClient { supabase.schema("app") }

    static let columns = "id, title, description, servings, prep_min, cook_min, steps, macros_per_serving, " +
        "macros_total, source, model_version, updated_at, " +
        "recipe_ingredients(position, ingredient_id, name, quantity, unit, grams, note, is_optional)"

    /// Newest first (updated_at), deleted ones left out.
    static func list() async throws -> [SavedRecipe] {
        try await app.from("recipes")
            .select(columns)
            .is("deleted_at", value: nil)
            .order("updated_at", ascending: false)
            .execute()
            .value
    }

    /// Saves a generated recipe with its ingredients in one transaction; returns the new id.
    static func save(_ recipe: RecipeAPI.Recipe) async throws -> UUID {
        struct Params: Encodable { let recipe: RecipeAPI.Recipe }
        return try await app.rpc("save_recipe", params: Params(recipe: recipe)).execute().value
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
