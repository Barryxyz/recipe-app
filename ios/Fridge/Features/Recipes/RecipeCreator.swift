import Foundation
import Supabase

/// F3.7: saving a recipe the user wrote (or duplicated), and the locally kept draft.
enum RecipeCreator {
    /// A pasted or typed name is linked to the catalog only when the match is this good
    /// (the same bar as recipe macros, F2.3).
    static let minScore = 0.6

    /// Links unlinked ingredients to the catalog (good matches only); the rest become the
    /// user's custom ingredients, so their nutrition can be estimated (F2.3). Then saves.
    static func save(_ draft: RecipeEditDraft, source: String) async throws -> UUID {
        var d = draft
        try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            for (i, ing) in d.ingredients.enumerated() where ing.ingredientId == nil {
                group.addTask { (i, try await link(ing.name)) }
            }
            for try await (i, id) in group { d.ingredients[i].ingredientId = id }
        }
        struct Params: Encodable { let recipe: RecipeEditDraft.Payload }
        return try await supabase.schema("app")
            .rpc("save_recipe", params: Params(recipe: d.payload(source: source)))
            .execute().value
    }

    /// The catalog id for a name, or a custom ingredient's id.
    static func link(_ name: String) async throws -> Int64 {
        if let best = try await match(name) { return best.id }
        return try await PantryAPI.customIngredient(named: name).id
    }

    /// The best catalog (or custom) match when it's good enough, else nil.
    static func match(_ name: String) async throws -> IngredientChoice? {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count >= 2 else { return nil }
        let top = try await PantryAPI.search(clean, limit: 1).first
        guard let top, (top.score ?? 0) >= minScore else { return nil }
        return top
    }

    /// Catalog allergen tags for these ids (custom ingredients have none).
    static func allergenTags(_ ids: [Int64]) async throws -> [Int64: [String]] {
        let catalogIds = Array(Set(ids.filter { $0 < PantryItem.customIdStart }))
        guard !catalogIds.isEmpty else { return [:] }
        struct Row: Decodable { let id: Int64; let allergens: [String]? }
        let rows: [Row] = try await supabase.schema("catalog").from("ingredients")
            .select("id, allergens").in("id", values: catalogIds.map { Int($0) }).execute().value
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.allergens ?? []) })
    }

    /// The signed-in user's allergies and default servings.
    static func prefs() async -> UserPrefs? {
        guard let id = try? await supabase.auth.session.user.id else { return nil }
        return try? await PrefsAPI.load(userId: id)
    }

    // MARK: Draft (kept on the device until saved or discarded)

    private static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("new-recipe-draft.json")
    }

    static func loadDraft() -> RecipeEditDraft? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecipeEditDraft.self, from: data)
    }

    static func keepDraft(_ draft: RecipeEditDraft) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(draft) { try? data.write(to: url, options: .atomic) }
    }

    static func discardDraft() { try? FileManager.default.removeItem(at: url) }
}
