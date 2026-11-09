import Foundation

/// F3.1: a saved recipe (app.recipes + its recipe_ingredients).
struct SavedRecipe: Decodable, Identifiable, Equatable {
    struct Ingredient: Decodable, Equatable {
        let position: Int
        let ingredient_id: Int64?
        let name: String
        let quantity: Double?
        let unit: String?
        let grams: Double?
        let note: String?
        let is_optional: Bool
    }

    let id: UUID
    let title: String
    let description: String?
    let servings: Int?
    let prep_min: Int?
    let cook_min: Int?
    let steps: [String]
    let macros_per_serving: RecipeAPI.Macros?
    let macros_total: RecipeAPI.Macros?
    let source: String
    let model_version: String?
    let updated_at: Date
    let ingredients: [Ingredient]

    enum CodingKeys: String, CodingKey {
        case id, title, description, servings, prep_min, cook_min, steps, macros_per_serving, macros_total
        case source, model_version, updated_at
        case ingredients = "recipe_ingredients"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings)
        prep_min = try c.decodeIfPresent(Int.self, forKey: .prep_min)
        cook_min = try c.decodeIfPresent(Int.self, forKey: .cook_min)
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        macros_per_serving = try? c.decodeIfPresent(RecipeAPI.Macros.self, forKey: .macros_per_serving)
        macros_total = try? c.decodeIfPresent(RecipeAPI.Macros.self, forKey: .macros_total)
        source = try c.decode(String.self, forKey: .source)
        model_version = try c.decodeIfPresent(String.self, forKey: .model_version)
        updated_at = try c.decode(Date.self, forKey: .updated_at)
        ingredients = (try c.decodeIfPresent([Ingredient].self, forKey: .ingredients) ?? []).sorted { $0.position < $1.position }
    }

    init(id: UUID, title: String, prepMin: Int?, cookMin: Int?, ingredients: [Ingredient], kcal: Double? = nil,
         source: String = "ai", updatedAt: Date = .now) {
        self.id = id; self.title = title; description = nil; servings = 2; prep_min = prepMin; cook_min = cookMin
        steps = ["Cook."]; self.source = source; model_version = nil; updated_at = updatedAt; self.ingredients = ingredients
        macros_per_serving = kcal.map { RecipeAPI.Macros(kcal: $0, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0,
                                                         sugar_g: 0, sodium_mg: 0, estimated: false, coverage: 1) }
        macros_total = nil
    }

    var totalMinutes: Int? {
        guard prep_min != nil || cook_min != nil else { return nil }
        return (prep_min ?? 0) + (cook_min ?? 0)
    }

    var tag: String? {
        switch source {
        case "edited": "Edited"
        case "manual": "Mine"
        default: nil
        }
    }

    /// For the shared detail view. Ingredient kinds come from the pantry as it is now.
    func asRecipe(pantry: PantryMatcher) -> RecipeAPI.Recipe {
        let zero = RecipeAPI.Macros(kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0,
                                    estimated: true, coverage: 0)
        let ings = ingredients.map { i in
            RecipeAPI.Ingredient(position: i.position, name: i.name, ingredient_id: i.ingredient_id,
                                 pantry_item_id: nil, kind: pantry.kind(id: i.ingredient_id, name: i.name),
                                 quantity: i.quantity, unit: i.unit, grams: i.grams, note: i.note,
                                 is_optional: i.is_optional)
        }
        return RecipeAPI.Recipe(
            temp_id: id.uuidString, title: title, description: description ?? "", servings: servings ?? 1,
            prep_min: prep_min ?? 0, cook_min: cook_min ?? 0, ingredients: ings, steps: steps,
            macros_per_serving: macros_per_serving ?? zero, macros_total: macros_total ?? macros_per_serving ?? zero,
            uses_expiring: ingredients.compactMap { pantry.expiringName(id: $0.ingredient_id, name: $0.name) },
            model_version: model_version ?? "")
    }
}

/// "Do I have this?" against the active, unexpired pantry (staples included). Matches by
/// catalog id first, then by name ("limes" = "lime"); amounts aren't compared (F3.1).
struct PantryMatcher {
    private var ids: Set<Int64> = []
    private var stapleIds: Set<Int64> = []
    private var names: [String: Bool] = [:]       // normalized name -> is staple
    private var expiringIds: [Int64: String] = [:]
    private var expiringNames: [String: String] = [:]

    init(_ items: [PantryItem] = [], now: Date = .now) {
        for item in items {
            let badge = ExpiryBadge(expiresAt: item.expiresAt, now: now)
            if badge.isExpired { continue }
            let n = Self.normalize(item.displayName)
            if let id = item.ingredientId {
                ids.insert(id)
                if item.isStaple { stapleIds.insert(id) }
            }
            names[n] = (names[n] ?? false) || item.isStaple
            if badge.isUseSoon && !item.isStaple {
                if let id = item.ingredientId { expiringIds[id] = item.displayName }
                expiringNames[n] = item.displayName
            }
        }
    }

    static func normalize(_ name: String) -> String {
        var n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        for suffix in ["oes", "es", "s"] where n.count > 3 && n.hasSuffix(suffix) {
            // tomatoes -> tomato, limes -> lime, eggs -> egg (keep "es" words like "cheese")
            if suffix == "es" && !(n.hasSuffix("shes") || n.hasSuffix("ches") || n.hasSuffix("xes") || n.hasSuffix("sses")) {
                continue
            }
            n = String(n.dropLast(suffix == "oes" ? 2 : suffix.count))
            break
        }
        return n
    }

    func has(id: Int64?, name: String) -> Bool {
        if let id, ids.contains(id) { return true }
        return names[Self.normalize(name)] != nil
    }

    func kind(id: Int64?, name: String) -> RecipeAPI.Ingredient.Kind {
        if let id, ids.contains(id) { return stapleIds.contains(id) ? .staple : .pantry }
        if let staple = names[Self.normalize(name)] { return staple ? .staple : .pantry }
        return .missing
    }

    func expiringName(id: Int64?, name: String) -> String? {
        if let id, let n = expiringIds[id] { return n }
        return expiringNames[Self.normalize(name)]
    }

    /// Every required (non-optional) ingredient is on hand.
    func canMakeNow(_ r: SavedRecipe) -> Bool {
        r.ingredients.filter { !$0.is_optional }.allSatisfy { has(id: $0.ingredient_id, name: $0.name) }
    }
}

enum SavedRecipeFilter: String, CaseIterable, Identifiable {
    case canMakeNow, under30
    var id: String { rawValue }
    var title: String { self == .canMakeNow ? "Can make now" : "Under 30 min" }
}

enum SavedRecipeSearch {
    /// Search over title and ingredient names, then the chips.
    static func filter(_ recipes: [SavedRecipe], search: String, filters: Set<SavedRecipeFilter>,
                       pantry: PantryMatcher) -> [SavedRecipe] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return recipes.filter { r in
            if !q.isEmpty && !r.title.lowercased().contains(q)
                && !r.ingredients.contains(where: { $0.name.lowercased().contains(q) }) { return false }
            if filters.contains(.canMakeNow) && !pantry.canMakeNow(r) { return false }
            if filters.contains(.under30) && (r.totalMinutes ?? .max) > 30 { return false }
            return true
        }
    }
}
