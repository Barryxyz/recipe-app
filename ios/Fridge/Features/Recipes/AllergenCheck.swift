import Foundation

/// F3.7: the allergen warning for the user's own recipes. A port of the name rules in
/// supabase/functions/_shared/food_rules.ts (keep the two in step): an ingredient matches if its
/// catalog tags OR its name do. Whole words, after removing look-alike phrases ("coconut milk").
enum AllergenCheck {
    static let allergenWords: [String: [String]] = {
        var m: [String: [String]] = [
            "milk": ["milk", "cheese", "butter", "cream", "yogurt", "yoghurt", "whey", "ghee", "casein", "buttermilk",
                     "parmesan", "parmigiano", "mozzarella", "cheddar", "feta", "ricotta", "brie", "gouda", "mascarpone",
                     "paneer", "custard", "kefir", "lactose", "halloumi", "camembert", "gruyere", "pecorino", "burrata",
                     "provolone", "queso", "creme fraiche", "half and half", "bechamel", "alfredo"],
            "egg": ["egg", "mayonnaise", "mayo", "aioli", "meringue", "hollandaise"],
            "fish": ["fish", "salmon", "tuna", "cod", "anchovy", "anchovies", "sardine", "tilapia", "halibut", "trout",
                     "bass", "catfish", "mackerel", "haddock", "snapper", "pollock", "swordfish", "herring", "worcestershire",
                     "caesar", "bonito", "dashi"],
            "shellfish": ["shellfish", "shrimp", "prawn", "crab", "lobster", "scallop", "clam", "mussel", "oyster", "crawfish",
                          "crayfish", "langoustine", "squid", "calamari", "octopus"],
            "tree nuts": ["almond", "walnut", "cashew", "pecan", "pistachio", "hazelnut", "macadamia", "pine nut", "brazil nut",
                          "praline", "marzipan", "nutella", "pesto", "nut", "frangipane", "chestnut"],
            "peanuts": ["peanut", "satay", "groundnut"],
            "wheat": ["wheat", "flour", "bread", "breadcrumb", "panko", "pasta", "spaghetti", "penne", "macaroni", "linguine",
                      "fettuccine", "lasagna", "lasagne", "noodle", "ramen", "udon", "couscous", "bulgur", "semolina", "farro",
                      "spelt", "seitan", "tortilla", "pita", "naan", "bagel", "croissant", "cracker", "soy sauce", "pastry",
                      "dough", "wonton", "dumpling", "roux", "bun", "baguette", "brioche", "crouton", "orzo", "gnocchi"],
            "gluten": ["barley", "rye", "malt", "oat", "oats", "beer"],
            "soy": ["soy", "soya", "tofu", "tempeh", "edamame", "miso", "tamari", "natto"],
            "sesame": ["sesame", "tahini", "hummus", "halva", "halvah", "furikake", "gomasio", "za atar", "zaatar"],
        ]
        m["gluten"]! += m["wheat"]!
        return m
    }()

    private static let glutenLookAlikes = [
        "rice flour", "almond flour", "coconut flour", "corn flour", "cornflour", "chickpea flour",
        "tapioca flour", "potato flour", "buckwheat flour", "rice noodle", "rice noodles", "glass noodle",
        "glass noodles", "corn tortilla", "corn tortillas", "rice paper", "cauliflower rice", "tamari",
    ]

    static let notAllergen: [String: [String]] = [
        "milk": ["coconut milk", "almond milk", "oat milk", "soy milk", "soya milk", "rice milk", "cashew milk",
                 "coconut cream", "peanut butter", "almond butter", "cashew butter", "nut butter", "apple butter",
                 "cocoa butter", "shea butter", "butter bean", "butter beans", "butternut", "cream of tartar"],
        "shellfish": ["oyster mushroom", "oyster mushrooms", "crab apple", "crab apples"],
        "tree nuts": ["water chestnut", "water chestnuts", "nutmeg", "coconut", "butternut", "peanut", "peanuts",
                      "doughnut", "donut"],
        "wheat": glutenLookAlikes,
        "gluten": glutenLookAlikes,
    ]

    static let freeOf: [String: [String]] = [
        "milk": ["dairy free", "milk free", "lactose free", "vegan", "plant based", "non dairy"],
        "egg": ["egg free", "eggless", "vegan"],
        "fish": ["fish free"],
        "shellfish": ["shellfish free"],
        "tree nuts": ["nut free", "tree nut free"],
        "peanuts": ["peanut free", "nut free"],
        "wheat": ["gluten free", "wheat free"],
        "gluten": ["gluten free"],
        "soy": ["soy free"],
        "sesame": ["sesame free"],
    ]

    /// "Crème-Fraîche (full fat)" -> "creme fraiche full fat"
    static func normalize(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en"))
        return folded.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }

    /// Whole-word match, allowing a plural (s / es / ies for y).
    private static func hasWord(_ text: String, _ word: String) -> Bool {
        let w = normalize(word)
        guard !w.isEmpty else { return false }
        let stem = w.hasSuffix("y") ? "(?:\(escape(w))|\(escape(String(w.dropLast())))ies)" : escape(w)
        return text.range(of: "(?:^| )\(stem)(?:s|es)?(?= |$)", options: .regularExpression) != nil
    }

    private static func strip(_ text: String, _ phrases: [String]) -> String {
        var t = " \(text) "
        for p in phrases {
            t = t.replacingOccurrences(of: " \(escape(normalize(p)))(?:s|es)?(?= )", with: " ", options: .regularExpression)
        }
        return t.replacingOccurrences(of: " +", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    /// True if the name mentions the allergen tag (or, for a custom allergy like "mustard", the word itself).
    static func nameHasAllergen(_ name: String, _ allergen: String) -> Bool {
        let tag = allergen.trimmingCharacters(in: .whitespaces).lowercased()
        let n = normalize(name)
        if (freeOf[tag] ?? []).contains(where: { " \(n) ".contains(" \($0) ") }) { return false }
        let text = strip(n, notAllergen[tag] ?? [])
        return (allergenWords[tag] ?? [allergen]).contains { hasWord(text, $0) }
    }

    /// The user's allergens found in these ingredients, in the order of the user's list.
    /// `tags` are the catalog allergen tags of the linked ingredients, by ingredient id.
    static func found(in ingredients: [RecipeEditDraft.Ingredient], allergens: [String],
                      tags: [Int64: [String]]) -> [String] {
        allergens.filter { a in
            let tag = a.trimmingCharacters(in: .whitespaces).lowercased()
            return ingredients.contains { ing in
                (ing.ingredientId.flatMap { tags[$0] } ?? []).contains(tag) || nameHasAllergen(ing.name, tag)
            }
        }
    }

    /// "Contains peanuts, which is on your allergy list." / "Contains milk and peanuts, which are …"
    static func warning(_ found: [String]) -> String? {
        guard !found.isEmpty else { return nil }
        // The "Wheat / gluten" choice stores both tags: name it once.
        var unique = found.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        if let w = unique.firstIndex(of: "wheat"), unique.contains("gluten") {
            unique[w] = "wheat/gluten"
            unique.removeAll { $0 == "gluten" }
        }
        let list = ListFormatter.localizedString(byJoining: unique)
        return "Contains \(list), which \(unique.count == 1 ? "is" : "are") on your allergy list."
    }
}
