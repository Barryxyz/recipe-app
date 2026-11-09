import Foundation
import XCTest
@testable import Fridge

/// F3.1: "Can make now", search and filters (no UI, no network).
final class SavedRecipeTests: XCTestCase {
    private func item(_ name: String, id: Int64?, days: Double? = 5, staple: Bool = false) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: id, displayName: name, quantity: 1, unit: "each", location: .fridge,
                   addedAt: .now, expiresAt: days.map { Date.now.addingTimeInterval($0 * 86_400) },
                   expiryOverridden: false, status: .active, source: .manual, isStaple: staple)
    }
    private func ing(_ name: String, id: Int64? = nil, optional: Bool = false) -> SavedRecipe.Ingredient {
        .init(position: 0, ingredient_id: id, name: name, quantity: 1, unit: "each", grams: nil, note: nil, is_optional: optional)
    }

    private var pantry: PantryMatcher {
        PantryMatcher([item("chicken breast", id: 52), item("limes", id: nil), item("olive oil", id: 85, days: nil, staple: true),
                       item("old milk", id: 39, days: -1), item("spinach", id: 24, days: 1)])
    }

    func testCanMakeNowFullyCoveredAndOneMissing() {
        let covered = SavedRecipe(id: UUID(), title: "Chicken", prepMin: 10, cookMin: 15, ingredients: [
            ing("chicken breast", id: 52), ing("olive oil", id: 85), ing("lime"), ing("parsley", optional: true)])
        XCTAssertTrue(pantry.canMakeNow(covered), "staples count, 'lime' matches 'limes', optional parsley ignored")
        let oneMissing = SavedRecipe(id: UUID(), title: "Chicken", prepMin: 10, cookMin: 15, ingredients: [
            ing("chicken breast", id: 52), ing("garlic", id: 13)])
        XCTAssertFalse(pantry.canMakeNow(oneMissing))
        let expired = SavedRecipe(id: UUID(), title: "Milk", prepMin: 1, cookMin: 1, ingredients: [ing("milk", id: 39)])
        XCTAssertFalse(pantry.canMakeNow(expired), "expired items don't count")
    }

    func testKindsAndExpiringForTheDetailView() {
        let r = SavedRecipe(id: UUID(), title: "Saag", prepMin: 10, cookMin: 20, ingredients: [
            ing("chicken breast", id: 52), ing("olive oil", id: 85), ing("garlic", id: 13), ing("spinach", id: 24)])
            .asRecipe(pantry: pantry)
        XCTAssertEqual(r.ingredients.map(\.kind), [.pantry, .staple, .missing, .pantry])
        XCTAssertEqual(r.uses_expiring, ["spinach"])
    }

    func testNormalize() {
        XCTAssertEqual(PantryMatcher.normalize("Tomatoes"), "tomato")
        XCTAssertEqual(PantryMatcher.normalize("limes"), "lime")
        XCTAssertEqual(PantryMatcher.normalize("eggs"), "egg")
        XCTAssertEqual(PantryMatcher.normalize("cheese"), "cheese")
        XCTAssertEqual(PantryMatcher.normalize("peaches"), "peach")
    }

    func testSearchAndFilters() {
        let quick = SavedRecipe(id: UUID(), title: "Garlic Chicken", prepMin: 10, cookMin: 15,
                                ingredients: [ing("chicken breast", id: 52)])
        let slow = SavedRecipe(id: UUID(), title: "Slow Beef Stew", prepMin: 20, cookMin: 120,
                               ingredients: [ing("beef", id: 54), ing("carrots", id: 3)])
        let all = [quick, slow]
        XCTAssertEqual(SavedRecipeSearch.filter(all, search: "chicken", filters: [], pantry: pantry).map(\.title), ["Garlic Chicken"])
        XCTAssertEqual(SavedRecipeSearch.filter(all, search: "CARROT", filters: [], pantry: pantry).map(\.title),
                       ["Slow Beef Stew"], "by ingredient")
        XCTAssertEqual(SavedRecipeSearch.filter(all, search: "", filters: [.under30], pantry: pantry).map(\.title), ["Garlic Chicken"])
        XCTAssertEqual(SavedRecipeSearch.filter(all, search: "", filters: [.canMakeNow], pantry: pantry).map(\.title), ["Garlic Chicken"])
        XCTAssertEqual(SavedRecipeSearch.filter(all, search: "", filters: [], pantry: pantry).count, 2)
    }

    func testDecodesSavedRecipe() throws {
        let json = """
        {"id":"7E2B8C1A-5F4D-4C2B-9A1E-3D5F6A7B8C9D","title":"Garlic chicken","description":null,"servings":2,
         "prep_min":10,"cook_min":20,"steps":["Heat.","Cook."],
         "macros_per_serving":{"kcal":520,"protein_g":38,"carbs_g":41,"fat_g":22,"fiber_g":6,"sugar_g":9,"sodium_mg":840,"estimated":false,"coverage":1},
         "macros_total":null,"source":"edited","model_version":"claude-haiku-5-5","updated_at":"2026-11-09T10:00:00+00:00",
         "recipe_ingredients":[{"position":1,"ingredient_id":null,"name":"lime","quantity":1,"unit":"each","grams":67,"note":null,"is_optional":false},
                               {"position":0,"ingredient_id":52,"name":"chicken breast","quantity":300,"unit":"g","grams":300,"note":null,"is_optional":false}]}
        """
        let r = try ScanAPI.decoder.decode(SavedRecipe.self, from: Data(json.utf8))
        XCTAssertEqual(r.ingredients.map(\.name), ["chicken breast", "lime"], "sorted by position")
        XCTAssertEqual(r.totalMinutes, 30)
        XCTAssertEqual(r.tag, "Edited")
        XCTAssertEqual(r.asRecipe(pantry: PantryMatcher()).macros_total.kcal, 520, "total falls back to per serving")
    }

    func testSavePayloadDropsNothingTheRPCNeeds() throws {
        let json = String(decoding: try JSONEncoder().encode(RecipeAPI.Recipe(
            temp_id: "r1", title: "T", description: "D", servings: 2, prep_min: 1, cook_min: 2,
            ingredients: [.init(position: 0, name: "lime", ingredient_id: nil, pantry_item_id: nil, kind: .missing,
                                quantity: 1, unit: "each", grams: 67, note: nil, is_optional: false)],
            steps: ["S"], macros_per_serving: .init(kcal: 1, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0, estimated: false, coverage: 1),
            macros_total: .init(kcal: 2, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0, estimated: false, coverage: 1),
            uses_expiring: [], model_version: "m")), as: UTF8.self)
        for key in ["\"title\"", "\"steps\"", "\"ingredients\"", "\"macros_per_serving\"", "\"model_version\"", "\"grams\""] {
            XCTAssertTrue(json.contains(key), key)
        }
    }
}
