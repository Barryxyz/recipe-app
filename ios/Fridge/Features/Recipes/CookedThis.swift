import Foundation

/// F3.4 "Cooked this": which pantry items a recipe used and what's left (no UI, no network).
enum CookedThis {
    /// Catalog data for converting between weight, volume and pieces (F2.3's densities).
    struct Conversion: Equatable {
        var gramsPerUnit: Double?
        var densityGPerMl: Double?
    }

    // MARK: Units

    private static let gramsPer: [String: Double] = ["g": 1, "kg": 1000, "oz": 28.3495, "lb": 453.592]
    private static let mlPer: [String: Double] = ["ml": 1, "l": 1000, "tsp": 5, "tbsp": 15, "cup": 240]

    /// "Tablespoons" -> "tbsp", "" -> "each".
    static func normalizeUnit(_ unit: String?) -> String {
        let u = (unit ?? "").trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if u.isEmpty || ["piece", "pieces", "whole", "ea"].contains(u) { return "each" }
        return RecipePaste.unitAliases[u] ?? u
    }

    /// Grams for an amount, or nil if the unit can't be weighed with what we know.
    static func grams(_ q: Double, _ unit: String, _ conv: Conversion?) -> Double? {
        let u = normalizeUnit(unit)
        if let g = gramsPer[u] { return q * g }
        if let ml = mlPer[u], let d = conv?.densityGPerMl { return q * ml * d }
        if u == "each", let g = conv?.gramsPerUnit { return q * g }
        return nil
    }

    /// An amount in another unit: same unit, same kind (weight / volume), or through grams.
    static func convert(_ q: Double, from: String, to: String, _ conv: Conversion?) -> Double? {
        let f = normalizeUnit(from), t = normalizeUnit(to)
        if f == t { return q }
        if let a = gramsPer[f], let b = gramsPer[t] { return q * a / b }
        if let a = mlPer[f], let b = mlPer[t] { return q * a / b }
        guard let g = grams(q, f, conv) else { return nil }
        return fromGrams(g, t, conv)
    }

    private static func fromGrams(_ g: Double, _ unit: String, _ conv: Conversion?) -> Double? {
        let u = normalizeUnit(unit)
        if let per = gramsPer[u] { return g / per }
        if let ml = mlPer[u], let d = conv?.densityGPerMl { return g / d / ml }
        if u == "each", let per = conv?.gramsPerUnit { return g / per }
        return nil
    }

    /// What's left, rounded sensibly: g / ml / oz whole, kg / l / lb to 0.01, the rest to ¼.
    /// Tiny leftovers count as nothing.
    static func roundLeft(_ q: Double, unit: String) -> Double {
        let u = normalizeUnit(unit)
        let r: Double
        switch u {
        case "g", "ml", "oz": r = q.rounded()
        case "kg", "l", "lb": r = (q * 100).rounded() / 100
        default: r = (q * 4).rounded() / 4
        }
        return r <= 0.0001 ? 0 : r
    }

    // MARK: Rows

    enum Mode: String, CaseIterable, Identifiable {
        case subtract, usedUp, skip, setLeft
        var id: String { rawValue }
    }

    /// One recipe ingredient you have, and what happens to the pantry items it matched.
    struct Row: Identifiable, Equatable {
        let id: Int                       // recipe ingredient position
        let name: String
        /// Matching active items, the ones to use first first.
        let items: [PantryItem]
        let recipeQuantity: Double?       // for the servings cooked
        let recipeUnit: String
        /// The recipe amount in the first item's unit, when it converts.
        let convertedAmount: Double?
        let isStaple: Bool
        let isOptional: Bool
        var mode: Mode
        /// Subtract: the amount, in `unit`. Set left: the new amount of the first item.
        var amount: Double?

        var unit: String { items.first?.unit ?? "each" }
        /// The first item has no amount ("some").
        var isSome: Bool { items.first?.quantity == nil }
        /// The modes offered for this row.
        var modes: [Mode] {
            if isSome { return [.skip, .usedUp] }
            return convertedAmount != nil || recipeQuantity == nil ? [.subtract, .usedUp, .skip, .setLeft] : [.setLeft, .usedUp, .skip]
        }
    }

    /// Rows for the recipe ingredients that match the pantry, for `servings` servings.
    static func rows(for recipe: RecipeAPI.Recipe, servings: Int, pantry: [PantryItem],
                     conversions: [Int64: Conversion], now: Date = .now) -> [Row] {
        let factor = recipe.servings > 0 ? Double(servings) / Double(recipe.servings) : 1
        var claimed = Set<UUID>()
        return recipe.ingredients.compactMap { ing in
            let items = matches(ing, in: pantry, now: now).filter { !claimed.contains($0.id) }
            guard let first = items.first else { return nil }
            items.forEach { claimed.insert($0.id) }

            let q = ing.quantity.map { $0 * factor }
            let conv = ing.ingredient_id.flatMap { conversions[$0] } ?? first.ingredientId.flatMap { conversions[$0] }
            var converted = q.flatMap { convert($0, from: ing.unit ?? "", to: first.unit ?? "", conv) }
            // The model's gram estimate when the recipe unit doesn't convert ("2 cloves").
            if converted == nil, let g = ing.grams, normalizeUnit(ing.unit) != normalizeUnit(first.unit) {
                converted = fromGrams(g * factor, first.unit ?? "", conv)
            }
            let isStaple = items.contains { $0.isStaple }

            var row = Row(id: ing.position, name: ing.name, items: items, recipeQuantity: q,
                          recipeUnit: ing.unit ?? "", convertedAmount: converted, isStaple: isStaple,
                          isOptional: ing.is_optional, mode: .skip, amount: nil)
            if row.isSome || isStaple || ing.is_optional || (q == nil && converted == nil) {
                row.mode = .skip
            } else if let converted {
                row.mode = .subtract
                row.amount = converted
            } else {
                row.mode = .setLeft            // units don't convert: ask what's left
            }
            return row
        }
    }

    /// Matching active items: the item the recipe was made from, then by catalog id, then by
    /// name. Unexpired first (soonest expiry first), expired ones only after those.
    static func matches(_ ing: RecipeAPI.Ingredient, in pantry: [PantryItem], now: Date = .now) -> [PantryItem] {
        let active = pantry.filter { $0.status == .active }
        var found: [PantryItem]
        if let id = ing.ingredient_id, case let byId = active.filter({ $0.ingredientId == id }), !byId.isEmpty {
            found = byId
        } else {
            let n = PantryMatcher.normalize(ing.name)
            found = active.filter { PantryMatcher.normalize($0.displayName) == n }
        }
        if let pid = ing.pantry_item_id, let exact = active.first(where: { $0.id == pid }), !found.contains(exact) {
            found.append(exact)
        }
        func rank(_ i: PantryItem) -> (Int, Int, Date) {
            let expired = i.expiresAt.map { $0 < now } ?? false
            return (i.id == ing.pantry_item_id ? 0 : 1, expired ? 1 : 0, i.expiresAt ?? .distantFuture)
        }
        return found.sorted { a, b in
            let (x, y) = (rank(a), rank(b))
            return x.1 != y.1 ? x.1 < y.1 : x.0 != y.0 ? x.0 < y.0 : x.2 < y.2
        }
    }

    // MARK: Changes

    struct Change: Encodable, Equatable {
        let id: UUID
        var quantity: Double?
        var used: Bool?
    }

    /// Item -> (before, after) amounts, for "Eggs: 6 → 4". After nil = used up.
    struct Effect: Equatable {
        let item: PantryItem
        let after: Double?
        let usedUp: Bool
    }

    static func effects(_ row: Row, conversions: [Int64: Conversion] = [:]) -> [Effect] {
        switch row.mode {
        case .skip:
            return []
        case .usedUp:
            return row.items.map { Effect(item: $0, after: nil, usedUp: true) }
        case .setLeft:
            guard let first = row.items.first, let left = row.amount else { return [] }
            let r = roundLeft(max(0, left), unit: row.unit)
            return [Effect(item: first, after: r, usedUp: r == 0)]
        case .subtract:
            guard var remaining = row.amount, remaining > 0 else { return [] }
            var out: [Effect] = []
            for item in row.items {
                guard remaining > 0.0001 else { break }
                guard let have = item.quantity else { continue }
                let conv = item.ingredientId.flatMap { conversions[$0] }
                // Work in the row's unit (the first item's); other batches convert into it.
                guard let haveInRow = convert(have, from: item.unit ?? "", to: row.unit, conv) else { continue }
                let take = min(remaining, haveInRow)
                remaining -= take
                let leftInRow = haveInRow - take
                let left = convert(leftInRow, from: row.unit, to: item.unit ?? "", conv) ?? 0
                let r = roundLeft(left, unit: item.unit ?? "")
                out.append(Effect(item: item, after: r, usedUp: r == 0))
            }
            return out
        }
    }

    static func changes(_ rows: [Row], conversions: [Int64: Conversion] = [:]) -> [Change] {
        rows.flatMap { effects($0, conversions: conversions) }.map {
            $0.usedUp ? Change(id: $0.item.id, quantity: $0.after == 0 ? 0 : nil, used: true)
                      : Change(id: $0.item.id, quantity: $0.after, used: nil)
        }
    }
}
