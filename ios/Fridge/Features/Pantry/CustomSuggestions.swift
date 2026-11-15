import Foundation

/// "Did you mean…?" before a custom item (the food list has nutrition, units and shelf life;
/// a custom item has none of that). Up to 3 food-list items: the search results for the whole
/// name first, then searches for its single words, last word first ("trader joe's mango salsa"
/// → salsa, mango), since the food is usually named last.
enum CustomSuggestions {
    static let limit = 3

    static func words(in name: String) -> [String] {
        let parts = name.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
        var seen = Set<String>()
        return parts.reversed().filter { seen.insert($0).inserted }
    }

    /// Words that never name a food on their own.
    static let stopWords: Set<String> = ["the", "and", "with", "for", "organic", "fresh", "brand", "style",
                                         "original", "classic", "homemade", "free", "low", "fat", "light",
                                         "large", "small", "medium", "pack", "family", "size", "value"]

    static func suggestions(for name: String, results: [IngredientChoice],
                            search: (String) async -> [IngredientChoice]) async -> [IngredientChoice] {
        var out: [IngredientChoice] = []
        func add(_ c: IngredientChoice) {
            if !c.isCustom, !out.contains(where: { $0.id == c.id }) { out.append(c) }
        }
        results.prefix(limit).forEach(add)
        for word in words(in: name) where out.count < limit {
            for c in await search(word).prefix(2) where out.count < limit { add(c) }
        }
        return out
    }
}
