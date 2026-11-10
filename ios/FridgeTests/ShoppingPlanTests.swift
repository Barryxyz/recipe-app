import XCTest
@testable import Fridge

/// F3.5: missing items and shortfalls, merging into the list, store-aisle order.
final class ShoppingPlanTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, id: Int64?, _ q: Double?, _ unit: String, staple: Bool = false,
                      expiresInDays: Double? = nil) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: id, displayName: name, quantity: q, unit: unit, location: .fridge,
                   addedAt: now, expiresAt: expiresInDays.map { now.addingTimeInterval($0 * 86400) },
                   expiryOverridden: false, status: .active, source: .manual, isStaple: staple)
    }

    private func ing(_ pos: Int, _ name: String, id: Int64?, _ q: Double?, _ unit: String?,
                     optional: Bool = false) -> RecipeAPI.Ingredient {
        .init(position: pos, name: name, ingredient_id: id, pantry_item_id: nil, kind: .missing, quantity: q,
              unit: unit, grams: nil, note: nil, is_optional: optional)
    }

    private func recipe(_ ings: [RecipeAPI.Ingredient]) -> RecipeAPI.Recipe {
        let m = RecipeAPI.Macros(kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0,
                                 estimated: false, coverage: 1)
        return .init(temp_id: "r", title: "R", description: "", servings: 2, prep_min: 5, cook_min: 5,
                     ingredients: ings, steps: ["Cook."], macros_per_serving: m, macros_total: m,
                     uses_expiring: [], model_version: "")
    }

    private func listItem(_ name: String, id: Int64?, _ q: Double?, _ unit: String?, checked: Bool = false) -> ShoppingItem {
        ShoppingItem(id: UUID(), ingredientId: id, name: name, quantity: q, unit: unit, sourceRecipeId: nil,
                     sourceRecipeTitle: nil, checked: checked, createdAt: now)
    }

    func testShortfallIsTheDifference() {
        let lines = ShoppingPlan.lines(for: recipe([ing(0, "chicken", id: 52, 400, "g")]),
                                       pantry: [item("chicken", id: 52, 150, "g")], conversions: [:], now: now)
        XCTAssertEqual(lines.map(\.quantity), [250])
        XCTAssertEqual(lines.first?.isShortfall, true)
    }

    func testMissingCoveredStaplesSomeOptionalAndExpired() {
        let r = recipe([
            ing(0, "lime", id: 99, 2, "each"),            // missing
            ing(1, "rice", id: 67, 200, "g"),             // 0.5 kg on hand: covered
            ing(2, "salt", id: 77, 1, "tsp"),             // staple
            ing(3, "olive oil", id: 85, 2, "tbsp"),       // "some"
            ing(4, "parsley", id: 30, 1, "bunch", optional: true),
            ing(5, "milk", id: 39, 1, "cup"),             // only expired milk: buy
            ing(6, "pepper", id: 78, nil, "to taste"),    // missing, no amount
        ])
        let pantry = [item("rice", id: 67, 0.5, "kg"), item("salt", id: 77, 500, "g", staple: true),
                      item("olive oil", id: 85, nil, "ml"), item("milk", id: 39, 1, "l", expiresInDays: -2)]
        let lines = ShoppingPlan.lines(for: r, pantry: pantry, conversions: [:], now: now)
        XCTAssertEqual(lines.map(\.name), ["lime", "milk", "pepper"])
        XCTAssertEqual(lines[0].quantity, 2)
        XCTAssertEqual(lines[1].unit, "cup")
        XCTAssertNil(lines[2].quantity)
        XCTAssertNil(lines[2].unit)
    }

    func testSecondAddMergesIntoTheSameRow() {
        let lines = [ShoppingPlan.Line(id: 0, ingredientId: 52, name: "chicken", quantity: 250, unit: "g", isShortfall: true)]
        let existing = listItem("chicken breast", id: 52, 0.25, "kg")
        let adds = ShoppingPlan.adds(lines, existing: [existing], recipeId: nil, recipeTitle: "R", conversions: [:])
        XCTAssertEqual(adds.first?.merge_id, existing.id)
        XCTAssertEqual(adds.first?.quantity, 0.25, "converted into the row's unit")

        let bought = listItem("chicken breast", id: 52, 0.25, "kg", checked: true)
        XCTAssertNil(ShoppingPlan.adds(lines, existing: [bought], recipeId: nil, recipeTitle: nil, conversions: [:]).first?.merge_id,
                     "bought rows aren't merged into")
        let cup = listItem("chicken", id: 52, 1, "cup")
        XCTAssertNil(ShoppingPlan.adds(lines, existing: [cup], recipeId: nil, recipeTitle: nil, conversions: [:]).first?.merge_id,
                     "units that don't convert make a new row")
        let free = listItem("Za'atar", id: nil, nil, nil)
        let typed = ShoppingPlan.Line(id: 1, ingredientId: nil, name: "za'atar", quantity: nil, unit: nil, isShortfall: false)
        XCTAssertEqual(ShoppingPlan.adds([typed], existing: [free], recipeId: nil, recipeTitle: nil, conversions: [:]).first?.merge_id,
                       free.id, "free text merges by name")
    }

    func testAislesInStoreOrder() {
        let items = [listItem("ice cream", id: 1, nil, nil), listItem("apples", id: 2, nil, nil),
                     listItem("thing", id: nil, nil, nil), listItem("salmon", id: 3, nil, nil),
                     listItem("done", id: 2, nil, nil, checked: true)]
        let groups = ShoppingPlan.toBuy(items, categories: [1: "frozen", 2: "produce", 3: "seafood"])
        XCTAssertEqual(groups.map(\.0), [.produce, .meatFish, .frozen, .other])
        XCTAssertEqual(groups.flatMap { $0.1.map(\.name) }, ["apples", "salmon", "ice cream", "thing"])
    }

    func testRoundUp() {
        XCTAssertEqual(ShoppingPlan.roundUp(1.2, unit: "each"), 2, "you can't buy part of an egg")
        XCTAssertEqual(ShoppingPlan.roundUp(249.2, unit: "g"), 250)
        XCTAssertEqual(ShoppingPlan.roundUp(0.3, unit: "cup"), 0.5)
        XCTAssertEqual(ShoppingPlan.roundUp(0.25, unit: "kg"), 0.25)
    }
}
