import Foundation

/// Defaults used when an ingredient is picked in the add sheet (F1.5).
enum PantryDefaults {
    /// Default location by catalog category. Condiments go in the fridge (mayo, salsa,
    /// hummus, ketchup once opened). Unknown categories and custom items: fridge.
    static func location(forCategory category: String?) -> StorageLocation {
        switch category {
        case "frozen": .freezer
        case "bakery", "grains", "baking", "spices", "oils", "canned", "nuts", "snacks": .pantry
        default: .fridge
        }
    }

    /// Seasoning & Staples by default: spices and the catalog's common staples.
    static func isStaple(_ choice: IngredientChoice, stapleIds: Set<Int64>) -> Bool {
        choice.category == "spices" || stapleIds.contains(choice.id)
    }
}

/// The add/edit form's state, kept free of UI and networking so it can be unit tested.
struct ItemDraft: Equatable {
    var ingredient: IngredientChoice?
    /// nil = "some".
    var quantity: Double? = 1
    var unit: MeasureUnit = .each
    var location: StorageLocation = .fridge
    /// Set when the user picks a date; nil means "use the rule" (F1.6).
    var chosenExpiry: Date?
    /// True when the user set the date (or chose "no expiry") for this item only.
    var expiryOverridden = false
    /// Seasoning & Staples item: defaults to "some" and no expiry.
    var isStaple = false

    var isSome: Bool { quantity == nil }

    /// Picking an ingredient fills in unit, quantity 1 and location. `sessionLocation` is the
    /// location last used in this sheet, which wins over the category default.
    /// `stapleIds` are the catalog's common staples; spices count as staples too.
    mutating func pick(_ choice: IngredientChoice, sessionLocation: StorageLocation?, stapleIds: Set<Int64> = []) {
        ingredient = choice
        unit = MeasureUnit(catalogUnit: choice.defaultUnit)
        location = sessionLocation ?? PantryDefaults.location(forCategory: choice.category)
        setStaple(PantryDefaults.isStaple(choice, stapleIds: stapleIds))
    }

    /// On: "some" and no expiry (both still editable). Off: 1 and the expiry rule (F1.6).
    mutating func setStaple(_ on: Bool) {
        isStaple = on
        chosenExpiry = nil
        if on {
            quantity = nil
            expiryOverridden = true
        } else {
            quantity = 1
            expiryOverridden = false
        }
    }

    mutating func increment() {
        quantity = (quantity ?? 0) + unit.step
    }

    /// Never goes below 0. Reaching 0 lets the edit sheet offer "Mark used".
    mutating func decrement() {
        guard let q = quantity else { return }
        quantity = max(0, q - unit.step)
    }

    mutating func setSome(_ some: Bool) {
        quantity = some ? nil : 1
    }

    /// Adding needs an ingredient and a positive quantity (or "some").
    var canAdd: Bool {
        guard ingredient != nil else { return false }
        if let q = quantity { return q > 0 && q.isFinite }
        return true
    }

    /// Editing also allows 0 (the sheet then offers "Mark used").
    var canSaveEdit: Bool {
        guard ingredient != nil else { return false }
        if let q = quantity { return q >= 0 && q.isFinite }
        return true
    }

    /// The user's date for this item only.
    mutating func overrideExpiry(_ date: Date?) {
        chosenExpiry = date
        expiryOverridden = true
    }

    /// Whole days from the local day added to the local day of `expiry`, for
    /// "Always use N days for <ingredient>".
    static func days(from addedAt: Date, to expiry: Date, in timeZone: TimeZone) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let a = cal.startOfDay(for: addedAt)
        let b = cal.startOfDay(for: expiry)
        return max(0, cal.dateComponents([.day], from: a, to: b).day ?? 0)
    }

    /// 23:59:59 local on the day of `date` (how F1.6 stores expiry dates).
    static func endOfDay(_ date: Date, in timeZone: TimeZone) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let start = cal.startOfDay(for: date)
        return cal.date(byAdding: .day, value: 1, to: start)!.addingTimeInterval(-1)
    }
}

/// Formats a quantity for display: "6", "0.5", "some".
enum QuantityFormat {
    static func string(_ quantity: Double?, unit: String?) -> String {
        guard let q = quantity else { return "some" }
        let number = q.formatted(.number.precision(.fractionLength(0...2)))
        guard let unit, unit != MeasureUnit.each.rawValue else { return number }
        return "\(number) \(unit)"
    }
}
