import XCTest
@testable import Fridge

/// F3.4: matching, unit conversion, defaults and the changes sent to app.apply_cooked.
final class CookedThisTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ name: String, id: Int64?, _ q: Double?, _ unit: String, staple: Bool = false,
                      expiresInDays: Double? = nil) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: id, displayName: name, quantity: q, unit: unit, location: .fridge,
                   addedAt: now, expiresAt: expiresInDays.map { now.addingTimeInterval($0 * 86400) },
                   expiryOverridden: false, status: .active, source: .manual, isStaple: staple)
    }

    private func ing(_ pos: Int, _ name: String, id: Int64?, _ q: Double?, _ unit: String?, grams: Double? = nil,
                     optional: Bool = false, pantryItem: UUID? = nil) -> RecipeAPI.Ingredient {
        .init(position: pos, name: name, ingredient_id: id, pantry_item_id: pantryItem, kind: .pantry, quantity: q,
              unit: unit, grams: grams, note: nil, is_optional: optional)
    }

    private func recipe(_ ings: [RecipeAPI.Ingredient], servings: Int = 2) -> RecipeAPI.Recipe {
        let m = RecipeAPI.Macros(kcal: 0, protein_g: 0, carbs_g: 0, fat_g: 0, fiber_g: 0, sugar_g: 0, sodium_mg: 0,
                                 estimated: false, coverage: 1)
        return .init(temp_id: "r", title: "R", description: "", servings: servings, prep_min: 5, cook_min: 5,
                     ingredients: ings, steps: ["Cook."], macros_per_serving: m, macros_total: m,
                     uses_expiring: [], model_version: "")
    }

    func testTwoOfSixEggsLeavesFour() {
        let eggs = item("eggs", id: 38, 6, "each")
        let rows = CookedThis.rows(for: recipe([ing(0, "eggs", id: 38, 2, "each")]), servings: 2,
                                   pantry: [eggs], conversions: [:], now: now)
        XCTAssertEqual(rows.first?.mode, .subtract)
        XCTAssertEqual(CookedThis.changes(rows), [.init(id: eggs.id, quantity: 4, used: nil)])
    }

    func testUnitConversionAndServingsScale() {
        let rice = item("rice", id: 67, 0.5, "kg")
        let r = recipe([ing(0, "rice", id: 67, 200, "g")])
        XCTAssertEqual(CookedThis.changes(CookedThis.rows(for: r, servings: 2, pantry: [rice], conversions: [:], now: now)),
                       [.init(id: rice.id, quantity: 0.3, used: nil)], "200 g from 0.5 kg leaves 0.3 kg")
        XCTAssertEqual(CookedThis.changes(CookedThis.rows(for: r, servings: 4, pantry: [rice], conversions: [:], now: now)),
                       [.init(id: rice.id, quantity: 0.1, used: nil)], "cooking 4 servings uses 400 g")
    }

    func testThroughGramsWithCatalogData() {
        let onions = item("onion", id: 11, 500, "g")
        let rows = CookedThis.rows(for: recipe([ing(0, "onion", id: 11, 1, "each")]), servings: 2, pantry: [onions],
                                   conversions: [11: .init(gramsPerUnit: 150, densityGPerMl: nil)], now: now)
        XCTAssertEqual(CookedThis.changes(rows), [.init(id: onions.id, quantity: 350, used: nil)])
        XCTAssertEqual(CookedThis.convert(1, from: "cup", to: "g", .init(gramsPerUnit: nil, densityGPerMl: 0.85)), 204)
        XCTAssertEqual(CookedThis.convert(2, from: "Tablespoons", to: "tsp", nil), 6)
        XCTAssertNil(CookedThis.convert(1, from: "cup", to: "g", nil), "no density: can't convert")
    }

    func testUnconvertibleAsksWhatsLeft() {
        let garlic = item("garlic", id: 13, 1, "bunch")
        var rows = CookedThis.rows(for: recipe([ing(0, "garlic", id: 13, 2, "clove")]), servings: 2,
                                   pantry: [garlic], conversions: [:], now: now)
        XCTAssertEqual(rows[0].mode, .setLeft)
        XCTAssertTrue(CookedThis.changes(rows).isEmpty, "nothing changes until the user types what's left")
        rows[0].amount = 0
        XCTAssertEqual(CookedThis.changes(rows), [.init(id: garlic.id, quantity: 0, used: true)])
    }

    func testSeveralBatchesSoonestFirstExpiredLast() {
        let expired = item("eggs", id: 38, 6, "each", expiresInDays: -1)
        let later = item("eggs", id: 38, 6, "each", expiresInDays: 10)
        let sooner = item("eggs", id: 38, 2, "each", expiresInDays: 2)
        let rows = CookedThis.rows(for: recipe([ing(0, "eggs", id: 38, 3, "each")]), servings: 2,
                                   pantry: [expired, later, sooner], conversions: [:], now: now)
        XCTAssertEqual(rows[0].items.map(\.id), [sooner.id, later.id, expired.id])
        XCTAssertEqual(CookedThis.changes(rows), [.init(id: sooner.id, quantity: 0, used: true),
                                                  .init(id: later.id, quantity: 5, used: nil)])
    }

    func testStaplesSomeAndOptionalAreSkippedByDefault() {
        let salt = item("salt", id: 77, 500, "g", staple: true)
        let oil = item("olive oil", id: 85, nil, "ml")
        let herbs = item("parsley", id: 30, 1, "bunch")
        var rows = CookedThis.rows(for: recipe([ing(0, "salt", id: 77, 1, "tsp"), ing(1, "olive oil", id: 85, 2, "tbsp"),
                                                ing(2, "parsley", id: 30, 1, "bunch", optional: true),
                                                ing(3, "lime", id: 99, 1, "each")]),
                                   servings: 2, pantry: [salt, oil, herbs], conversions: [:], now: now)
        XCTAssertEqual(rows.map(\.name), ["salt", "olive oil", "parsley"], "missing items are hidden")
        XCTAssertEqual(rows.map(\.mode), [.skip, .skip, .skip])
        XCTAssertTrue(CookedThis.changes(rows).isEmpty)
        XCTAssertEqual(rows[1].modes, [.skip, .usedUp], "\"some\": Still have some / Used it up")
        rows[1].mode = .usedUp
        rows[2].mode = .subtract
        rows[2].amount = 1
        XCTAssertEqual(CookedThis.changes(rows), [.init(id: oil.id, quantity: nil, used: true),
                                                  .init(id: herbs.id, quantity: 0, used: true)])
    }

    func testMatchesByNameAndGenerationItem() {
        let limes = item("Limes", id: nil, 3, "each")
        let rows = CookedThis.rows(for: recipe([ing(0, "lime", id: nil, 1, "each")]), servings: 2,
                                   pantry: [limes], conversions: [:], now: now)
        XCTAssertEqual(rows.first?.items.first?.id, limes.id)
        let chosen = item("chicken", id: 52, 300, "g", expiresInDays: 9)
        let other = item("chicken", id: 52, 500, "g", expiresInDays: 1)
        let m = CookedThis.matches(ing(0, "chicken", id: 52, 200, "g", pantryItem: chosen.id), in: [other, chosen], now: now)
        XCTAssertEqual(m.map(\.id), [chosen.id, other.id], "the item the recipe was made from comes first")
    }

    func testRounding() {
        XCTAssertEqual(CookedThis.roundLeft(0.30000001, unit: "kg"), 0.3)
        XCTAssertEqual(CookedThis.roundLeft(1.4, unit: "each"), 1.5)
        XCTAssertEqual(CookedThis.roundLeft(349.6, unit: "g"), 350)
        XCTAssertEqual(CookedThis.roundLeft(0.1, unit: "each"), 0, "a sliver left counts as used up")
    }
}
