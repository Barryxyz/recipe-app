import Foundation

/// A row of `app.pantry_items`.
struct PantryItem: Codable, Identifiable, Equatable {
    enum Status: String, Codable { case active, used, discarded }
    enum Source: String, Codable { case scan, manual, shoppingList = "shopping_list" }

    let id: UUID
    var ingredientId: Int64?
    var displayName: String
    /// nil = "some".
    var quantity: Double?
    var unit: String?
    var location: StorageLocation
    var addedAt: Date
    var expiresAt: Date?
    var expiryOverridden: Bool
    var status: Status
    var source: Source
    /// Seasonings & Staples: shown in its own section; amount and expiry optional.
    var isStaple: Bool = false
    /// When it was marked used or discarded (F1.8). Set by the database; nil while active.
    var statusChangedAt: Date? = nil
    /// For offline sync (F3.6): last server change, and the soft delete.
    var updatedAt: Date? = nil
    var deletedAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case id
        case ingredientId = "ingredient_id"
        case displayName = "display_name"
        case quantity, unit, location
        case addedAt = "added_at"
        case expiresAt = "expires_at"
        case expiryOverridden = "expiry_overridden"
        case status, source
        case isStaple = "is_staple"
        case statusChangedAt = "status_changed_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    static let columns = "id, ingredient_id, display_name, quantity, unit, location, added_at, expires_at, expiry_overridden, status, source, is_staple, status_changed_at, updated_at, deleted_at"

    /// Custom items (app.ingredients_private) have ids from 1e12 up; catalog ids are below.
    static let customIdStart: Int64 = 1_000_000_000_000
    var isCustom: Bool { (ingredientId ?? 0) >= Self.customIdStart }
}

/// An ingredient chosen in the add sheet: a catalog item or one of the user's custom items.
struct IngredientChoice: Codable, Identifiable, Equatable, Hashable {
    let id: Int64
    let name: String
    let category: String?
    let defaultUnit: String?
    let isCustom: Bool
    /// How well it matched a search (app.search_ingredients), 0–1.
    var score: Double? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, category, score
        case defaultUnit = "default_unit"
        case isCustom = "is_custom"
    }
}
