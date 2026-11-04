import Foundation

/// Catalog shelf life for one ingredient, per location (`catalog.ingredients.shelf_life_*_days`).
struct CatalogShelfLife: Equatable {
    var fridge: Int?
    var freezer: Int?
    var pantry: Int?

    func days(at location: StorageLocation) -> Int? {
        switch location {
        case .fridge: fridge
        case .freezer: freezer
        case .pantry: pantry
        }
    }
}

/// F1.6: the expiry rule, mirrored from `app.default_expiry` in
/// supabase/migrations/20261104100000_expiry_rules.sql so the add sheet can preview the date
/// without a network call. The server's value is final. Both are checked against
/// supabase/tests/expiry_cases.json; change them together.
///
/// Priority (rule 1, a date the user set, is handled by the caller):
/// 2. the user's default for (ingredient, location)
/// 3. the catalog's shelf life for the location
/// 4. fallback: fridge 7, freezer 90, pantry 30 days
/// Result: 23:59:59 local time on (local day added + days).
struct ExpiryCalculator {
    struct DefaultKey: Hashable {
        let ingredientId: Int64
        let location: StorageLocation
    }

    static let fallbackDays: [StorageLocation: Int] = [.fridge: 7, .freezer: 90, .pantry: 30]

    var timeZone: TimeZone
    /// The user's own defaults (`app.user_shelf_life_overrides`, deleted rows excluded).
    var userDefaults: [DefaultKey: Int]
    /// Catalog lookup by ingredient id. Custom items (id >= 1e12) aren't in the catalog.
    var catalog: (Int64) -> CatalogShelfLife?

    func shelfLifeDays(ingredientId: Int64?, location: StorageLocation) -> Int {
        if let id = ingredientId {
            if let days = userDefaults[DefaultKey(ingredientId: id, location: location)] { return days }
            if let days = catalog(id)?.days(at: location) { return days }
        }
        return Self.fallbackDays[location]!
    }

    func defaultExpiry(ingredientId: Int64?, location: StorageLocation, addedAt: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let days = shelfLifeDays(ingredientId: ingredientId, location: location)
        let dayAdded = calendar.startOfDay(for: addedAt)
        // Midnight after the expiry day, minus one second.
        let nextMidnight = calendar.date(byAdding: .day, value: days + 1, to: dayAdded)!
        return nextMidnight.addingTimeInterval(-1)
    }
}
