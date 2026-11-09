import Foundation

/// F2.4: results state, one-tap fixes and display formatting (no UI, no network).

/// The last generation, kept on the phone until the next one (never on the server until saved).
struct RecipeSession: Codable, Equatable {
    var request: RecipeRequest
    var response: RecipeAPI.Response
    var createdAt = Date()
    /// temp_id -> saved recipe id (F3.1), so Save shows "Saved ✓" when the results are reopened.
    var savedIds: [String: UUID]?

    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-recipes.json")
    }

    static func load() -> RecipeSession? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(RecipeSession.self, from: data)
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: Self.url, options: .atomic) }
    }

    static func clear() { try? FileManager.default.removeItem(at: url) }
}

/// One-tap changes offered when there are no recipes (F2.4 "Fewer or no recipes").
enum RecipeFix: String, Identifiable, CaseIterable {
    case allowMissing, anyTime, anyCuisine, anyMeal, addItems
    var id: String { rawValue }

    var title: String {
        switch self {
        case .allowMissing: "Allow a few missing items"
        case .anyTime: "Any time"
        case .anyCuisine: "Any cuisine"
        case .anyMeal: "Any meal"
        case .addItems: "Add items"
        }
    }

    /// The `limited_by` value this fix relaxes.
    private var limit: String {
        switch self {
        case .allowMissing: "only_on_hand"
        case .anyTime: "max_minutes"
        case .anyCuisine: "cuisine"
        case .anyMeal: "meal"
        case .addItems: "pantry"
        }
    }

    /// The request with this option relaxed; nil for Add items (not a rerun).
    func apply(to r: RecipeRequest) -> RecipeRequest? {
        var r = r
        switch self {
        case .allowMissing: r.only_on_hand = false
        case .anyTime: r.max_minutes = nil
        case .anyCuisine: r.cuisine = nil
        case .anyMeal: r.meal = Meal.any.rawValue
        case .addItems: return nil
        }
        return r
    }

    private func isSet(in r: RecipeRequest) -> Bool {
        switch self {
        case .allowMissing: r.only_on_hand
        case .anyTime: r.max_minutes != nil
        case .anyCuisine: r.cuisine != nil
        case .anyMeal: r.meal != Meal.any.rawValue
        case .addItems: false
        }
    }

    /// Fixes for options the user set. When the model said which ones limited it, only those;
    /// otherwise (or when none of them is named) every option that was set. Diets and allergens
    /// are never offered. Add items when the pantry itself was the limit.
    static func fixes(for r: RecipeRequest, limitedBy: [String]) -> [RecipeFix] {
        let set = allCases.filter { $0.isSet(in: r) }
        let named = set.filter { limitedBy.contains($0.limit) }
        var out = named.isEmpty ? set : named
        if limitedBy.contains("pantry") { out.append(.addItems) }
        return out
    }
}

enum MacroFormat {
    /// kcal to the nearest 10 (F2.3).
    static func kcal(_ v: Double) -> Int { Int((v / 10).rounded()) * 10 }
    static func grams(_ v: Double) -> Int { Int(v.rounded()) }

    static func prefix(_ m: RecipeAPI.Macros) -> String { m.estimated ? "≈" : "" }

    /// "≈ 520 kcal · P 38 g · C 41 g · F 22 g"
    static func summary(_ m: RecipeAPI.Macros) -> String {
        "\(prefix(m))\(kcal(m.kcal)) kcal · P \(grams(m.protein_g)) g · C \(grams(m.carbs_g)) g · F \(grams(m.fat_g)) g"
    }

    /// "½ tsp", "1¼ cup", "200 g", "2" (each). Fractions for kitchen measures, decimals otherwise.
    static func amount(_ quantity: Double?, unit: String?) -> String {
        guard let q = quantity else { return "" }
        let u = unit ?? ""
        var number = q.formatted(.number.precision(.fractionLength(0...1)))
        if ["tsp", "tbsp", "cup", "each", "", "bunch", "pack"].contains(u) {
            let whole = Int(q), frac = q - Double(whole)
            let glyphs: [(Double, String)] = [(0, ""), (0.25, "¼"), (1.0 / 3, "⅓"), (0.5, "½"), (2.0 / 3, "⅔"), (0.75, "¾"), (1, "")]
            if let (value, glyph) = glyphs.min(by: { abs($0.0 - frac) < abs($1.0 - frac) }), abs(value - frac) < 0.05 {
                let w = whole + (value == 1 ? 1 : 0)
                number = w == 0 ? (glyph.isEmpty ? "0" : glyph) : "\(w)\(glyph)"
            }
        }
        return u.isEmpty || u == "each" ? number : "\(number) \(u)"
    }

    static func minutes(_ n: Int) -> String {
        n < 60 ? "\(n) min" : (n % 60 == 0 ? "\(n / 60) h" : "\(n / 60) h \(n % 60) min")
    }
}

enum RecipeText {
    /// "1. Heat the oil" / "Step 2: Add" / "3) Stir" -> the instruction alone (the app numbers steps).
    static func stepWithoutNumber(_ step: String) -> String {
        let trimmed = step.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:step\s*)?\d+\s*[.):\-–]\s*"#
        guard let range = trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else { return trimmed }
        let rest = trimmed[range.upperBound...]
        return rest.isEmpty ? trimmed : String(rest)
    }
}
