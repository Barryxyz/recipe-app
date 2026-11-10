import Foundation

/// A row of `app.shopping_list_items`.
struct ShoppingItem: Codable, Identifiable, Equatable {
    let id: UUID
    var ingredientId: Int64?
    var name: String
    var quantity: Double?
    var unit: String?
    var sourceRecipeId: UUID?
    var sourceRecipeTitle: String?
    var checked: Bool
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, quantity, unit, checked
        case ingredientId = "ingredient_id"
        case sourceRecipeId = "source_recipe_id"
        case sourceRecipeTitle = "source_recipe_title"
        case createdAt = "created_at"
    }

    static let columns = "id, ingredient_id, name, quantity, unit, source_recipe_id, source_recipe_title, checked, created_at"
}

/// F3.5: what a recipe still needs, how it merges into the list, and the store-aisle order.
enum ShoppingPlan {
    /// One thing to buy for a recipe: a missing ingredient, or the shortfall of one on hand.
    struct Line: Identifiable, Equatable {
        let id: Int                 // recipe ingredient position
        let ingredientId: Int64?
        let name: String
        let quantity: Double?
        let unit: String?
        /// True when some is on hand and only the difference is added.
        let isShortfall: Bool
    }

    /// The new rows and merges sent to app.add_shopping_items.
    struct Add: Encodable, Equatable {
        var merge_id: UUID?
        let ingredient_id: Int64?
        let name: String
        var quantity: Double?
        let unit: String?
        let source_recipe_id: UUID?
        let source_recipe_title: String?
    }

    /// Required ingredients not covered by the active, unexpired pantry. Staples and items
    /// without an amount ("some") always count as on hand; amounts compare after conversion
    /// (as in Cooked this) and only the shortfall is added.
    static func lines(for recipe: RecipeAPI.Recipe, pantry: [PantryItem],
                      conversions: [Int64: CookedThis.Conversion], now: Date = .now) -> [Line] {
        recipe.ingredients.compactMap { ing in
            guard !ing.is_optional else { return nil }
            let unit = ing.unit.map(CookedThis.normalizeUnit).flatMap { $0 == "to taste" ? nil : $0 }
            let have = CookedThis.matches(ing, in: pantry, now: now).filter { !($0.expiresAt.map { $0 < now } ?? false) }
            if have.isEmpty {
                let q = ing.quantity.map { roundUp($0, unit: unit ?? "each") }
                return Line(id: ing.position, ingredientId: ing.ingredient_id, name: ing.name, quantity: q,
                            unit: q == nil ? nil : unit, isShortfall: false)
            }
            if have.contains(where: { $0.isStaple || $0.quantity == nil }) { return nil }
            guard let need = ing.quantity, let u = unit else { return nil }
            var onHand = 0.0
            for item in have {
                let conv = (item.ingredientId ?? ing.ingredient_id).flatMap { conversions[$0] }
                // An amount we can't compare: assume it's enough rather than over-buy.
                guard let q = item.quantity, let inRecipeUnit = CookedThis.convert(q, from: item.unit ?? "", to: u, conv)
                else { return nil }
                onHand += inRecipeUnit
            }
            let short = need - onHand
            guard short > need * 0.02 else { return nil }
            return Line(id: ing.position, ingredientId: ing.ingredient_id, name: ing.name,
                        quantity: roundUp(short, unit: u), unit: u, isShortfall: true)
        }
    }

    /// Amounts to buy, rounded up: g / ml / oz whole, kg / l / lb to 0.01, pieces whole, the rest to ¼.
    static func roundUp(_ q: Double, unit: String) -> Double {
        switch CookedThis.normalizeUnit(unit) {
        case "g", "ml", "oz", "each": return max(1, (q - 1e-9).rounded(.up))
        case "kg", "l", "lb": return max(0.01, ((q - 1e-9) * 100).rounded(.up) / 100)
        default: return max(0.25, ((q - 1e-9) * 4).rounded(.up) / 4)
        }
    }

    /// Lines -> adds. A line merges into an unchecked list item for the same ingredient (by id,
    /// or by name for free text) when its unit converts into that item's unit.
    static func adds(_ lines: [Line], existing: [ShoppingItem], recipeId: UUID?, recipeTitle: String?,
                     conversions: [Int64: CookedThis.Conversion]) -> [Add] {
        let open = existing.filter { !$0.checked }
        return lines.map { line in
            var add = Add(merge_id: nil, ingredient_id: line.ingredientId, name: line.name, quantity: line.quantity,
                          unit: line.unit, source_recipe_id: recipeId, source_recipe_title: recipeTitle)
            let same = open.first { item in
                if let a = line.ingredientId, let b = item.ingredientId { return a == b }
                return PantryMatcher.normalize(item.name) == PantryMatcher.normalize(line.name)
            }
            guard let target = same else { return add }
            if target.quantity == nil && target.unit != nil {
                add.merge_id = target.id            // a "some" row already covers it
                add.quantity = nil
            } else if let q = line.quantity {
                let conv = line.ingredientId.flatMap { conversions[$0] }
                guard let converted = target.unit == nil ? q
                        : CookedThis.convert(q, from: line.unit ?? "each", to: target.unit!, conv) else { return add }
                add = Add(merge_id: target.id, ingredient_id: line.ingredientId, name: line.name,
                          quantity: target.unit == nil ? q : roundUp(converted, unit: target.unit!),
                          unit: target.unit ?? line.unit, source_recipe_id: recipeId, source_recipe_title: recipeTitle)
            } else {
                add.merge_id = target.id            // no amount: the existing row already covers it
            }
            return add
        }
    }

    // MARK: Aisles

    enum Aisle: Int, CaseIterable, Identifiable {
        case produce, meatFish, dairy, bakery, pantry, frozen, other
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .produce: "Produce"
            case .meatFish: "Meat & fish"
            case .dairy: "Dairy & eggs"
            case .bakery: "Bakery"
            case .pantry: "Pantry"
            case .frozen: "Frozen"
            case .other: "Other"
            }
        }

        init(category: String?) {
            switch category {
            case "produce": self = .produce
            case "meat", "seafood", "protein": self = .meatFish
            case "dairy": self = .dairy
            case "bakery": self = .bakery
            case "grains", "baking", "spices", "oils", "condiments", "canned", "nuts", "snacks": self = .pantry
            case "frozen": self = .frozen
            default: self = .other
            }
        }
    }

    /// Unchecked items by aisle (store order), oldest first within an aisle.
    static func toBuy(_ items: [ShoppingItem], categories: [Int64: String]) -> [(Aisle, [ShoppingItem])] {
        let open = items.filter { !$0.checked }.sorted { $0.createdAt < $1.createdAt }
        let grouped = Dictionary(grouping: open) { Aisle(category: $0.ingredientId.flatMap { categories[$0] }) }
        return Aisle.allCases.compactMap { a in grouped[a].map { (a, $0) } }
    }
}
