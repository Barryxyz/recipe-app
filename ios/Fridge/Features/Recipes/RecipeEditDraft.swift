import Foundation
import Supabase

/// F3.2: the recipe editor's state and rules (no UI, no network). Also the start of F3.7.
struct RecipeEditDraft: Equatable, Codable {
    struct Ingredient: Equatable, Identifiable, Codable {
        var id = UUID()
        var ingredientId: Int64?
        var name: String
        var quantity: Double?
        var unit: String
        /// The AI's weight estimate (F2.3 fallback); kept in step with edits, see `update`.
        var grams: Double?
        var note: String
        var isOptional: Bool
    }

    struct Step: Equatable, Identifiable, Codable {
        var id = UUID()
        var text: String
    }

    static let servingsRange = 1...12
    static let maxTitle = 80
    static let maxDescription = 300
    static let maxMinutes = 600

    var title: String
    var description: String
    var servings: Int
    var prepMin: Int?
    var cookMin: Int?
    var ingredients: [Ingredient]
    var steps: [Step]

    init(title: String = "", description: String = "", servings: Int = 2, prepMin: Int? = nil, cookMin: Int? = nil,
         ingredients: [Ingredient] = [], steps: [Step] = []) {
        self.title = title; self.description = description; self.servings = servings
        self.prepMin = prepMin; self.cookMin = cookMin; self.ingredients = ingredients; self.steps = steps
    }

    init(_ r: SavedRecipe) {
        self.init(
            title: r.title, description: r.description ?? "",
            servings: min(max(r.servings ?? 2, Self.servingsRange.lowerBound), Self.servingsRange.upperBound),
            prepMin: r.prep_min, cookMin: r.cook_min,
            ingredients: r.ingredients.map {
                Ingredient(ingredientId: $0.ingredient_id, name: $0.name, quantity: $0.quantity, unit: $0.unit ?? "",
                           grams: $0.grams, note: $0.note ?? "", isOptional: $0.is_optional)
            },
            steps: r.steps.map { Step(text: RecipeText.stepWithoutNumber($0)) })
    }

    // MARK: Creating (F3.7)

    /// Pasted with Paste list / Paste steps (for the recipe_created event, F5.2).
    /// Optional so drafts kept before this was added still decode.
    var pastedList: Bool?
    var pastedSteps: Bool?

    /// recipe_created props: counts only.
    func eventProps(duplicate: Bool) -> [String: AnyJSON] {
        ["ingredients": .integer(ingredients.count), "steps": .integer(steps.count),
         "pasted_list": .bool(pastedList ?? false), "pasted_steps": .bool(pastedSteps ?? false), "duplicate": .bool(duplicate),
         "custom_ingredients": .integer(ingredients.filter { ($0.ingredientId ?? 0) >= PantryItem.customIdStart || $0.ingredientId == nil }.count)]
    }

    /// Anything typed? (An untouched new recipe can be left without asking.)
    var hasContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !ingredients.isEmpty || steps.contains { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            || prepMin != nil || cookMin != nil
    }

    /// Duplicate: a filled-in copy with fresh row ids, named "… (copy)".
    func duplicated() -> RecipeEditDraft {
        var d = self
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        d.title = String((t.count + 7 > Self.maxTitle ? String(t.prefix(Self.maxTitle - 7)) : t) + " (copy)")
        d.ingredients = ingredients.map { var i = $0; i.id = UUID(); return i }
        d.steps = steps.map { Step(text: $0.text) }
        return d
    }

    /// A copy of the user's own recipe stays theirs; a copy of an AI or shared recipe is "edited".
    static func duplicateSource(of source: String) -> String {
        source == "manual" ? "manual" : "edited"
    }

    /// Pasted lines as ingredient rows (linking to the catalog happens later, see RecipeCreator).
    mutating func appendPasted(_ lines: [RecipePaste.ParsedIngredient]) {
        pastedList = true
        ingredients += lines.map {
            Ingredient(ingredientId: nil, name: $0.name, quantity: $0.quantity, unit: $0.unit, grams: nil,
                       note: $0.note, isOptional: false)
        }
    }

    mutating func appendPasted(steps pasted: [String]) {
        pastedSteps = true
        steps.removeAll { $0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        steps += pasted.map { Step(text: $0) }
    }

    // MARK: Validation (shown inline)

    enum Field: Hashable { case title, description, prep, cook, ingredients, steps }

    var errors: [Field: String] {
        var e: [Field: String] = [:]
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { e[.title] = "Give the recipe a name." }
        else if t.count > Self.maxTitle { e[.title] = "At most \(Self.maxTitle) characters." }
        if description.count > Self.maxDescription { e[.description] = "At most \(Self.maxDescription) characters." }
        if let p = prepMin, !(0...Self.maxMinutes).contains(p) { e[.prep] = "0–\(Self.maxMinutes) minutes." }
        if let c = cookMin, !(0...Self.maxMinutes).contains(c) { e[.cook] = "0–\(Self.maxMinutes) minutes." }
        if ingredients.isEmpty { e[.ingredients] = "Add at least one ingredient." }
        if steps.isEmpty { e[.steps] = "Add at least one step." }
        else if steps.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            e[.steps] = "Steps can't be empty: fill them in or swipe to delete."
        }
        return e
    }

    var isValid: Bool { errors.isEmpty }

    // MARK: Editing

    /// Replaces an ingredient. The stored weight follows the change: same ingredient and unit
    /// with a new amount -> scaled; a different unit or ingredient -> dropped (it would be wrong).
    mutating func update(_ new: Ingredient) {
        guard let i = ingredients.firstIndex(where: { $0.id == new.id }) else { return }
        let old = ingredients[i]
        var n = new
        if old.ingredientId != n.ingredientId || old.name != n.name || old.unit != n.unit {
            n.grams = nil
        } else if old.quantity != n.quantity {
            if let g = old.grams, let q0 = old.quantity, q0 > 0, let q1 = n.quantity { n.grams = g * q1 / q0 }
            else { n.grams = nil }
        }
        ingredients[i] = n
    }

    /// "Scale ingredients?" -> every amount (and weight) times new/old servings, rounded to
    /// kitchen-friendly amounts.
    mutating func scale(to newServings: Int) {
        guard newServings != servings, servings > 0 else { servings = newServings; return }
        let factor = Double(newServings) / Double(servings)
        for i in ingredients.indices {
            if let q = ingredients[i].quantity { ingredients[i].quantity = Self.round(q * factor, unit: ingredients[i].unit) }
            if let g = ingredients[i].grams { ingredients[i].grams = g * factor }
        }
        servings = newServings
    }

    /// The amounts servings changes are scaled from, so stepping 2 -> 1 -> 2 gets back exactly
    /// the original amounts instead of compounding rounding.
    struct ScaleBase: Equatable {
        var servings: Int
        var ingredients: [Ingredient]
        /// The ingredients as the last scale left them; if they differ now, the user edited them.
        var lastScaled: [Ingredient]
    }

    /// Changing servings always scales the ingredients (from `base` while they're unedited).
    mutating func changeServings(to n: Int, base: inout ScaleBase?) {
        guard n != servings else { return }
        if base == nil || base!.lastScaled != ingredients {
            base = ScaleBase(servings: servings, ingredients: ingredients, lastScaled: ingredients)
        }
        ingredients = base!.ingredients
        servings = base!.servings
        scale(to: n)
        base!.lastScaled = ingredients
    }

    /// g / ml / oz to whole numbers, kg / l / lb to 0.1, cups, spoons and pieces to the nearest ¼
    /// (never down to 0).
    static func round(_ q: Double, unit: String) -> Double {
        switch unit {
        case "g", "ml", "oz": return max(1, q.rounded())
        case "kg", "l", "lb": return max(0.1, (q * 10).rounded() / 10)
        default: return max(0.25, (q * 4).rounded() / 4)
        }
    }

    /// Whether macros need recalculating after saving (F3.2 step 2).
    func needsMacros(comparedTo original: RecipeEditDraft) -> Bool {
        servings != original.servings || ingredients.map(Self.macroKey) != original.ingredients.map(Self.macroKey)
    }

    private static func macroKey(_ i: Ingredient) -> String {
        "\(i.ingredientId ?? -1)|\(i.name)|\(i.quantity ?? -1)|\(i.unit)|\(i.isOptional)"
    }

    // MARK: Save payload (app.update_recipe / app.save_recipe)

    struct Payload: Encodable {
        struct Ing: Encodable {
            let ingredient_id: Int64?
            let name: String
            let quantity: Double?
            let unit: String?
            let grams: Double?
            let note: String?
            let is_optional: Bool
        }
        let title: String
        let description: String
        let servings: Int
        let prep_min: Int?
        let cook_min: Int?
        let steps: [String]
        let ingredients: [Ing]
        let source: String?
    }

    func payload(source: String? = nil) -> Payload {
        Payload(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: description.trimmingCharacters(in: .whitespacesAndNewlines),
            servings: servings, prep_min: prepMin, cook_min: cookMin,
            steps: steps.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) },
            ingredients: ingredients.map {
                Payload.Ing(ingredient_id: $0.ingredientId, name: $0.name.trimmingCharacters(in: .whitespacesAndNewlines),
                            quantity: $0.quantity, unit: $0.unit.isEmpty ? nil : $0.unit, grams: $0.grams,
                            note: $0.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0.note,
                            is_optional: $0.isOptional)
            },
            source: source)
    }

    /// Units offered for recipe ingredients (pantry units plus pinch / to taste), with the
    /// ingredient's own unit kept if it's something else ("clove").
    static func units(including current: String) -> [String] {
        var list = MeasureUnit.allCases.map(\.rawValue) + ["pinch", "to taste"]
        if !current.isEmpty && !list.contains(current) { list.append(current) }
        return list
    }
}
