import Foundation

/// F2.1: the options sheet before generating recipes. Pure state and rules (no UI, no network).

enum Meal: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack, dessert, any
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    /// Before 11:00 breakfast, 11–15 lunch, after 15:00 dinner.
    static func forTime(_ date: Date = .now, calendar: Calendar = .current) -> Meal {
        switch calendar.component(.hour, from: date) {
        case ..<11: .breakfast
        case 11..<15: .lunch
        default: .dinner
        }
    }
}

enum Cuisine: String, CaseIterable, Identifiable {
    case italian, mexican, chinese, japanese, indian, thai, mediterranean, american
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct RecipeOptions: Codable, Equatable {
    static let servingsRange = 1...12
    static let timeChoices = [15, 30, 45, 60]

    var servings: Int
    /// nil = any time.
    var maxMinutes: Int?
    var meal: Meal
    /// A chip's raw value or the user's own text; nil = any cuisine.
    var cuisine: String?
    var preferExpiring = true
    var onlyOnHand = false

    /// Defaults for a new sheet: the last options used (remembered on this device), except the
    /// meal, which always follows the time of day; servings from prefs the first time.
    static func initial(defaultServings: Int, remembered: RecipeOptions?, now: Date = .now,
                        calendar: Calendar = .current) -> RecipeOptions {
        var o = remembered ?? RecipeOptions(servings: defaultServings, meal: .any)
        o.servings = clampServings(o.servings)
        o.meal = Meal.forTime(now, calendar: calendar)
        return o
    }

    static func clampServings(_ n: Int) -> Int {
        min(max(n, servingsRange.lowerBound), servingsRange.upperBound)
    }

    /// Trimmed, lowercased; empty means none.
    var cleanCuisine: String? {
        let c = (cuisine ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return c.isEmpty ? nil : String(c.prefix(40))
    }

    // MARK: Remembered options

    private static let key = "recipes.lastOptions"

    static func loadRemembered() -> RecipeOptions? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(RecipeOptions.self, from: data)
    }

    func remember() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// What a request would cook with: active items not past their date, minus the ones the user
/// left out for this request. Expired items are never used (they're counted for the note).
struct RecipePantry: Equatable {
    /// Regular items (not staples), soonest expiry first.
    let items: [PantryItem]
    let staples: [PantryItem]
    let expiredCount: Int

    init(_ active: [PantryItem], now: Date = .now, calendar: Calendar = .current) {
        let s = PantryGrouping.sections(active, now: now, calendar: calendar)
        items = s.regular.sorted(by: PantryGrouping.soonestFirst)
        staples = s.staples.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        expiredCount = s.expired.count
    }

    var isEmpty: Bool { items.isEmpty }

    func itemCount(excluding: Set<UUID>) -> Int { items.filter { !excluding.contains($0.id) }.count }
    func stapleCount(excluding: Set<UUID>) -> Int { staples.filter { !excluding.contains($0.id) }.count }

    enum Warning: Equatable {
        /// Every item was left out.
        case nothingSelected
        /// Fewer than 3 items (staples not counted).
        case lowPantry
        /// "Only use what I have" with fewer than 5 items.
        case verySimple

        var message: String {
            switch self {
            case .nothingSelected: "You've left out every item. Include at least one to get recipes."
            case .lowPantry: "Recipes may need several items you don't have."
            case .verySimple: "Recipes may be very simple."
            }
        }
    }

    /// The empty pantry is handled separately (Scan / Add instead of Generate).
    func warning(excluding: Set<UUID>, onlyOnHand: Bool) -> Warning? {
        let n = itemCount(excluding: excluding)
        if n == 0 { return .nothingSelected }
        if n < 3 { return .lowPantry }
        if onlyOnHand && n < 5 { return .verySimple }
        return nil
    }
}

/// The body sent to generate-recipes (F2.2).
struct RecipeRequest: Codable, Equatable {
    var servings: Int
    var max_minutes: Int?
    var meal: String
    var cuisine: String?
    var prefer_expiring: Bool
    var only_on_hand: Bool
    var exclude_pantry_item_ids: [UUID]

    init(options o: RecipeOptions, excluding: Set<UUID>) {
        servings = RecipeOptions.clampServings(o.servings)
        max_minutes = o.maxMinutes
        meal = o.meal.rawValue
        cuisine = o.cleanCuisine
        prefer_expiring = o.preferExpiring
        only_on_hand = o.onlyOnHand
        exclude_pantry_item_ids = excluding.sorted { $0.uuidString < $1.uuidString }
    }

    /// The sheet's options for this request ("Change options" from the results).
    var options: RecipeOptions {
        RecipeOptions(servings: servings, maxMinutes: max_minutes, meal: Meal(rawValue: meal) ?? .any, cuisine: cuisine,
                      preferExpiring: prefer_expiring, onlyOnHand: only_on_hand)
    }

    /// Encodes missing values as null so the server sees every field.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(servings, forKey: .servings)
        if let max_minutes { try c.encode(max_minutes, forKey: .max_minutes) } else { try c.encodeNil(forKey: .max_minutes) }
        try c.encode(meal, forKey: .meal)
        if let cuisine { try c.encode(cuisine, forKey: .cuisine) } else { try c.encodeNil(forKey: .cuisine) }
        try c.encode(prefer_expiring, forKey: .prefer_expiring)
        try c.encode(only_on_hand, forKey: .only_on_hand)
        try c.encode(exclude_pantry_item_ids, forKey: .exclude_pantry_item_ids)
    }
    enum CodingKeys: String, CodingKey {
        case servings, max_minutes, meal, cuisine, prefer_expiring, only_on_hand, exclude_pantry_item_ids
    }
}
