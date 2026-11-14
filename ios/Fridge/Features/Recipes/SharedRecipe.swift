import Foundation
import Observation
import Supabase

/// F4.3: a recipe someone shared, as `public.get_shared_recipe` returns it (recipe fields only:
/// no ids, owner or dates).
struct SharedRecipe: Decodable, Equatable {
    struct Ingredient: Decodable, Equatable {
        let name: String
        let quantity: Double?
        let unit: String?
        let note: String?
        let is_optional: Bool
    }

    let title: String
    let description: String?
    let servings: Int?
    let prep_min: Int?
    let cook_min: Int?
    let steps: [String]
    let macros_per_serving: RecipeAPI.Macros?
    let is_ai: Bool
    let ingredients: [Ingredient]

    init(title: String, description: String? = nil, servings: Int? = 2, prep_min: Int? = nil, cook_min: Int? = nil,
         steps: [String] = [], macros_per_serving: RecipeAPI.Macros? = nil, is_ai: Bool = true,
         ingredients: [Ingredient] = []) {
        self.title = title; self.description = description; self.servings = servings; self.prep_min = prep_min
        self.cook_min = cook_min; self.steps = steps; self.macros_per_serving = macros_per_serving
        self.is_ai = is_ai; self.ingredients = ingredients
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        servings = try c.decodeIfPresent(Int.self, forKey: .servings)
        prep_min = try c.decodeIfPresent(Int.self, forKey: .prep_min)
        cook_min = try c.decodeIfPresent(Int.self, forKey: .cook_min)
        steps = (try? c.decode([String].self, forKey: .steps)) ?? []
        macros_per_serving = try? c.decodeIfPresent(RecipeAPI.Macros.self, forKey: .macros_per_serving)
        is_ai = (try? c.decode(Bool.self, forKey: .is_ai)) ?? true
        ingredients = (try? c.decode([Ingredient].self, forKey: .ingredients)) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case title, description, servings, prep_min, cook_min, steps, macros_per_serving, is_ai, ingredients
    }

    /// For the detail view, with availability marks from the recipient's own pantry (by name:
    /// shared recipes carry no catalog ids).
    func asRecipe(pantry: PantryMatcher) -> RecipeAPI.Recipe {
        let zero = RecipeAPI.Macros(kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0,
                                    estimated: true, coverage: 0)
        let perServing = macros_per_serving ?? zero
        let n = Double(max(servings ?? 1, 1))
        let total = RecipeAPI.Macros(kcal: perServing.kcal * n, protein_g: perServing.protein_g * n,
                                     carbs_g: perServing.carbs_g * n, fat_g: perServing.fat_g * n,
                                     fiber_g: perServing.fiber_g * n, sugar_g: perServing.sugar_g * n,
                                     sodium_mg: perServing.sodium_mg * n, estimated: perServing.estimated,
                                     coverage: perServing.coverage)
        let ings = ingredients.enumerated().map { i, ing in
            RecipeAPI.Ingredient(position: i, name: ing.name, ingredient_id: nil, pantry_item_id: nil,
                                 kind: pantry.kind(id: nil, name: ing.name), quantity: ing.quantity, unit: ing.unit,
                                 grams: nil, note: ing.note, is_optional: ing.is_optional)
        }
        return RecipeAPI.Recipe(
            temp_id: "shared-\(title)", title: title, description: description ?? "", servings: servings ?? 1,
            prep_min: prep_min ?? 0, cook_min: cook_min ?? 0, ingredients: ings, steps: steps,
            macros_per_serving: perServing, macros_total: total,
            uses_expiring: ingredients.compactMap { pantry.expiringName(id: nil, name: $0.name) },
            model_version: "")
    }

    /// What "Save to my recipes" saves: an independent copy. Ingredients are linked to the
    /// recipient's catalog view when saved (RecipeCreator), then nutrition is recalculated.
    var draft: RecipeEditDraft {
        RecipeEditDraft(
            title: String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(RecipeEditDraft.maxTitle)),
            description: String((description ?? "").prefix(RecipeEditDraft.maxDescription)),
            servings: min(max(servings ?? 2, RecipeEditDraft.servingsRange.lowerBound), RecipeEditDraft.servingsRange.upperBound),
            prepMin: prep_min, cookMin: cook_min,
            ingredients: ingredients.map {
                RecipeEditDraft.Ingredient(ingredientId: nil, name: $0.name, quantity: $0.quantity, unit: $0.unit ?? "",
                                           grams: nil, note: $0.note ?? "", isOptional: $0.is_optional)
            },
            steps: steps.map { RecipeEditDraft.Step(text: RecipeText.stepWithoutNumber($0)) })
    }
}

/// Share links: `https://<share host>/r/<token>` (Universal Links once the app has the
/// Associated Domains entitlement), and `com.barryxyz.fridge://r/<token>` for testing on
/// builds without it.
enum SharedLink {
    static let scheme = "com.barryxyz.fridge"

    static func token(from url: URL, shareHost: String? = AppConfig.shareBaseURL?.host) -> String? {
        let parts: [String]
        if url.scheme == scheme {
            parts = [url.host ?? ""] + url.pathComponents.filter { $0 != "/" }
        } else if url.scheme == "https", let shareHost, url.host?.lowercased() == shareHost.lowercased() {
            parts = url.pathComponents.filter { $0 != "/" }
        } else {
            return nil
        }
        guard parts.count == 2, parts[0] == "r", isToken(parts[1]) else { return nil }
        return parts[1]
    }

    static func isToken(_ s: String) -> Bool {
        s.count == 22 && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
}

enum SharedRecipeAPI {
    /// The recipe, or nil when the link no longer works (stopped sharing, deleted, unknown).
    static func fetch(_ token: String) async throws -> SharedRecipe? {
        let data = try await supabase.rpc("get_shared_recipe", params: ["p_token": token]).execute().data
        return try PostgrestClient.Configuration.jsonDecoder.decode(SharedRecipe?.self, from: data)
    }
}

/// Holds an opened link until it can be shown: after sign-in and after onboarding on a fresh
/// install. Kept on disk so it survives the app being closed during onboarding.
@MainActor @Observable
final class SharedLinkRouter {
    static let shared = SharedLinkRouter()
    private static let key = "pendingSharedRecipeToken"

    var pending: String? {
        didSet { UserDefaults.standard.set(pending, forKey: Self.key) }
    }

    private init() { pending = UserDefaults.standard.string(forKey: Self.key) }

    /// True if the URL was a share link.
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let token = SharedLink.token(from: url) else { return false }
        pending = token
        return true
    }
}

extension Notification.Name {
    /// Saved recipes changed outside the Recipes tab (e.g. a shared recipe was saved).
    static let savedRecipesChanged = Notification.Name("savedRecipesChanged")
}
