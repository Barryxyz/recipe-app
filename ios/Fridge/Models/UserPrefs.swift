import Foundation

/// Diets offered in onboarding and Settings (F1.7). Stored in `app.user_prefs.diets`.
/// Enforcement happens in recipe generation (F2.2).
enum Diet: String, CaseIterable, Identifiable, Codable {
    case vegetarian, vegan, pescatarian, keto
    case lowCarb = "low_carb"
    case glutenFree = "gluten_free"
    case dairyFree = "dairy_free"
    case halal, kosher

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vegetarian: "Vegetarian"
        case .vegan: "Vegan"
        case .pescatarian: "Pescatarian"
        case .keto: "Keto"
        case .lowCarb: "Low-carb"
        case .glutenFree: "Gluten-free"
        case .dairyFree: "Dairy-free"
        case .halal: "Halal"
        case .kosher: "Kosher"
        }
    }
}

/// Allergy choices. Each maps to one or more `catalog.ingredients.allergens` tags, so the
/// recipe check (F2.2) can match ingredients by tag.
enum AllergyChoice: String, CaseIterable, Identifiable {
    case milk, egg, fish, shellfish
    case treeNuts = "tree nuts"
    case peanuts
    case wheatGluten = "wheat/gluten"
    case soy, sesame

    var id: String { rawValue }

    var title: String {
        switch self {
        case .milk: "Milk"
        case .egg: "Egg"
        case .fish: "Fish"
        case .shellfish: "Shellfish"
        case .treeNuts: "Tree nuts"
        case .peanuts: "Peanuts"
        case .wheatGluten: "Wheat / gluten"
        case .soy: "Soy"
        case .sesame: "Sesame"
        }
    }

    /// "Wheat / gluten" stores both tags: wheat catches flour, gluten catches barley and oats.
    var tags: [String] {
        self == .wheatGluten ? ["wheat", "gluten"] : [rawValue]
    }

    static let allTags: Set<String> = Set(allCases.flatMap(\.tags))
}

/// A row of `app.user_prefs`.
struct UserPrefs: Codable, Equatable {
    var diets: [String]
    /// Catalog allergen tags plus free-text "Other" entries (lowercased).
    var allergens: [String]
    /// Deprecated: staples are pantry items now (is_staple). Always written empty.
    var stapleIngredientIds: [Int64]
    var defaultServings: Int

    enum CodingKeys: String, CodingKey {
        case diets, allergens
        case stapleIngredientIds = "staple_ingredient_ids"
        case defaultServings = "default_servings"
    }

    static let columns = "diets, allergens, staple_ingredient_ids, default_servings"
}

/// Editable form of the preferences, shared by onboarding and Settings. No UI or networking,
/// so it can be unit tested.
struct PrefsDraft: Equatable {
    static let servingsRange = 1...20

    var diets: Set<Diet> = []
    var allergies: Set<AllergyChoice> = []
    /// Free text, comma-separated: "mustard, celery".
    var otherAllergies = ""
    /// Onboarding's staples screen: becomes Seasonings & Staples pantry items on Finish.
    var staples: [IngredientChoice] = []
    var servings = 2

    init() {}

    /// From stored prefs. Staple names are looked up separately and passed in.
    init(_ prefs: UserPrefs, staples: [IngredientChoice]) {
        diets = Set(prefs.diets.compactMap(Diet.init(rawValue:)))
        let stored = Set(prefs.allergens)
        allergies = Set(AllergyChoice.allCases.filter { choice in choice.tags.contains { stored.contains($0) } })
        otherAllergies = prefs.allergens.filter { !AllergyChoice.allTags.contains($0) }.joined(separator: ", ")
        self.staples = staples
        servings = Self.clampServings(prefs.defaultServings)
    }

    /// Free-text allergies: split on commas, trimmed, lowercased, de-duplicated, known tags removed.
    var otherAllergyList: [String] {
        var seen = Set<String>()
        return otherAllergies
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty && !AllergyChoice.allTags.contains($0) && seen.insert($0).inserted }
    }

    var prefs: UserPrefs {
        let tags = AllergyChoice.allCases.filter(allergies.contains).flatMap(\.tags)
        return UserPrefs(
            diets: Diet.allCases.filter(diets.contains).map(\.rawValue),
            allergens: tags + otherAllergyList,
            stapleIngredientIds: [],
            defaultServings: Self.clampServings(servings))
    }

    mutating func toggle(_ diet: Diet) {
        if diets.contains(diet) { diets.remove(diet) } else { diets.insert(diet) }
    }

    mutating func toggle(_ allergy: AllergyChoice) {
        if allergies.contains(allergy) { allergies.remove(allergy) } else { allergies.insert(allergy) }
    }

    mutating func addStaple(_ choice: IngredientChoice) {
        guard !staples.contains(where: { $0.id == choice.id }) else { return }
        staples.append(choice)
    }

    mutating func removeStaple(_ id: Int64) {
        staples.removeAll { $0.id == id }
    }

    static func clampServings(_ n: Int) -> Int {
        min(max(n, servingsRange.lowerBound), servingsRange.upperBound)
    }
}
