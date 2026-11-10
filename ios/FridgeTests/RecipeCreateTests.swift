import XCTest
@testable import Fridge

/// F3.7: paste parsing, the allergen warning and duplicating.
final class RecipeCreateTests: XCTestCase {
    typealias P = RecipePaste.ParsedIngredient

    func testSpecIngredientList() {
        let rows = RecipePaste.ingredients("2 cups flour\n1 1/2 tsp salt\n3 eggs, beaten\n½ cup milk")
        XCTAssertEqual(rows, [
            P(quantity: 2, unit: "cup", name: "flour", note: ""),
            P(quantity: 1.5, unit: "tsp", name: "salt", note: ""),
            P(quantity: 3, unit: "each", name: "eggs", note: "beaten"),
            P(quantity: 0.5, unit: "cup", name: "milk", note: ""),
        ])
    }

    func testBulletsNumbersAndBlankLinesAreIgnored() {
        let rows = RecipePaste.ingredients("Ingredients:\n\n- 200 g pasta\n• 2 Tbsp. olive oil\n1. 1 onion, finely diced\n  \n* salt to taste")
        XCTAssertEqual(rows.map(\.name), ["Ingredients:", "pasta", "olive oil", "onion", "salt"])
        XCTAssertEqual(rows[1], P(quantity: 200, unit: "g", name: "pasta", note: ""))
        XCTAssertEqual(rows[2], P(quantity: 2, unit: "tbsp", name: "olive oil", note: ""))
        XCTAssertEqual(rows[3], P(quantity: 1, unit: "each", name: "onion", note: "finely diced"))
        XCTAssertEqual(rows[4], P(quantity: nil, unit: "to taste", name: "salt", note: ""))
    }

    func testAmounts() {
        XCTAssertEqual(RecipePaste.ingredient("1-2 onions")?.quantity, 2, "a range takes the higher number")
        XCTAssertEqual(RecipePaste.ingredient("1 – 2 onions")?.quantity, 2)
        XCTAssertEqual(RecipePaste.ingredient("2 to 3 carrots")?.quantity, 3)
        XCTAssertEqual(RecipePaste.ingredient("1½ cups rice")?.quantity, 1.5)
        XCTAssertEqual(RecipePaste.ingredient("1 ½ cups rice")?.quantity, 1.5)
        XCTAssertEqual(RecipePaste.ingredient("3/4 cup sugar")?.quantity, 0.75)
        XCTAssertEqual(RecipePaste.ingredient("1.5 kg potatoes")?.unit, "kg")
        XCTAssertEqual(RecipePaste.ingredient("2 tablespoons of butter"), P(quantity: 2, unit: "tbsp", name: "butter", note: ""))
        XCTAssertEqual(RecipePaste.ingredient("3 cloves garlic, crushed"), P(quantity: 3, unit: "clove", name: "garlic", note: "crushed"))
        XCTAssertEqual(RecipePaste.ingredient("pinch of salt"), P(quantity: 1, unit: "pinch", name: "salt", note: ""))
        XCTAssertEqual(RecipePaste.ingredient("fresh basil"), P(quantity: nil, unit: "each", name: "fresh basil", note: ""))
        XCTAssertNil(RecipePaste.ingredient("   "))
    }

    func testNumberedSteps() {
        let steps = RecipePaste.steps("Method\n1. Heat the oil.\n2) Add the onion\nand stir.\nStep 3: Serve.")
        XCTAssertEqual(steps, ["Heat the oil.", "Add the onion and stir.", "Serve."])
    }

    func testStepsSplitAtBlankLinesOrLines() {
        XCTAssertEqual(RecipePaste.steps("Boil the pasta\nfor 10 minutes.\n\nDrain and toss."),
                       ["Boil the pasta for 10 minutes.", "Drain and toss."])
        XCTAssertEqual(RecipePaste.steps("Instructions:\nChop.\nFry.\n"), ["Chop.", "Fry."])
        XCTAssertEqual(RecipePaste.steps("10 minutes later, stir."), ["10 minutes later, stir."],
                       "a number without a dot isn't step numbering")
    }

    // MARK: Allergens

    private func ing(_ name: String, id: Int64? = nil) -> RecipeEditDraft.Ingredient {
        .init(ingredientId: id, name: name, quantity: 1, unit: "each", note: "", isOptional: false)
    }

    func testAllergenNamesMatchLikeTheServer() {
        XCTAssertTrue(AllergenCheck.nameHasAllergen("Parmesan cheese", "milk"))
        XCTAssertFalse(AllergenCheck.nameHasAllergen("coconut milk", "milk"))
        XCTAssertFalse(AllergenCheck.nameHasAllergen("peanut butter", "milk"))
        XCTAssertTrue(AllergenCheck.nameHasAllergen("peanut butter", "peanuts"))
        XCTAssertTrue(AllergenCheck.nameHasAllergen("basil pesto", "tree nuts"))
        XCTAssertFalse(AllergenCheck.nameHasAllergen("nutmeg", "tree nuts"))
        XCTAssertFalse(AllergenCheck.nameHasAllergen("gluten-free bread", "gluten"))
        XCTAssertTrue(AllergenCheck.nameHasAllergen("Crème fraîche", "milk"))
        XCTAssertTrue(AllergenCheck.nameHasAllergen("dijon mustard", "mustard"), "custom allergy: its own word")
    }

    func testWarningUsesTagsAndNames() {
        let found = AllergenCheck.found(in: [ing("flour"), ing("satay sauce"), ing("mystery", id: 7)],
                                        allergens: ["milk", "peanuts", "wheat", "gluten", "egg"],
                                        tags: [7: ["egg"]])
        XCTAssertEqual(found, ["peanuts", "wheat", "gluten", "egg"])
        XCTAssertEqual(AllergenCheck.warning(found), "Contains peanuts, wheat/gluten, and egg, which are on your allergy list.")
        XCTAssertEqual(AllergenCheck.warning(["peanuts"]), "Contains peanuts, which is on your allergy list.")
        XCTAssertNil(AllergenCheck.warning([]))
    }

    // MARK: Drafts

    func testDuplicateAndSource() {
        let d = RecipeEditDraft(title: "Pad thai", servings: 2, ingredients: [ing("noodles")], steps: [.init(text: "Cook.")])
        let copy = d.duplicated()
        XCTAssertEqual(copy.title, "Pad thai (copy)")
        XCTAssertNotEqual(copy.ingredients[0].id, d.ingredients[0].id)
        XCTAssertEqual(copy.ingredients[0].name, "noodles")
        XCTAssertEqual(RecipeEditDraft.duplicateSource(of: "manual"), "manual")
        XCTAssertEqual(RecipeEditDraft.duplicateSource(of: "ai"), "edited")
        XCTAssertEqual(RecipeEditDraft.duplicateSource(of: "shared"), "edited")
        XCTAssertLessThanOrEqual(RecipeEditDraft(title: String(repeating: "a", count: 80)).duplicated().title.count, 80)
    }

    func testNewDraftContentAndPasting() {
        var d = RecipeEditDraft(servings: 4)
        XCTAssertFalse(d.hasContent)
        XCTAssertEqual(d.errors.keys.sorted { "\($0)" < "\($1)" }.count, 3, "title, ingredients and steps errors")
        d.appendPasted(RecipePaste.ingredients("2 cups flour"))
        d.steps = [.init(text: "")]
        d.appendPasted(steps: ["Mix.", "Bake."])
        XCTAssertTrue(d.hasContent)
        XCTAssertEqual(d.steps.map(\.text), ["Mix.", "Bake."], "an empty step is replaced by the pasted ones")
        XCTAssertEqual(d.payload(source: "manual").source, "manual")
        let data = try! JSONEncoder().encode(d)
        XCTAssertEqual(try! JSONDecoder().decode(RecipeEditDraft.self, from: data), d, "drafts survive being kept")
    }
}
