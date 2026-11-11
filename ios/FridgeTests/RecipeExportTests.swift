import PDFKit
import XCTest
@testable import Fridge

/// F4.4: text and PDF export.
@MainActor
final class RecipeExportTests: XCTestCase {
    private func recipe(steps: Int = 2, kcal: Double = 520, estimated: Bool = true) -> RecipeAPI.Recipe {
        let m = RecipeAPI.Macros(kcal: kcal, protein_g: 38.2, carbs_g: 41, fat_g: 21.6, fiber_g: 0, sugar_g: 0, sodium_mg: 0,
                                 estimated: estimated, coverage: 1)
        let ings: [RecipeAPI.Ingredient] = [
            .init(position: 0, name: "chicken thighs", ingredient_id: 52, pantry_item_id: nil, kind: .pantry, quantity: 300,
                  unit: "g", grams: 300, note: nil, is_optional: false),
            .init(position: 1, name: "spinach", ingredient_id: 24, pantry_item_id: nil, kind: .missing, quantity: 200,
                  unit: "g", grams: 200, note: "roughly chopped", is_optional: false),
            .init(position: 2, name: "salt", ingredient_id: 77, pantry_item_id: nil, kind: .staple, quantity: nil,
                  unit: "to taste", grams: nil, note: nil, is_optional: false),
            .init(position: 3, name: "lime", ingredient_id: nil, pantry_item_id: nil, kind: .missing, quantity: 0.5,
                  unit: "each", grams: 30, note: nil, is_optional: true),
        ]
        return .init(temp_id: "r", title: "Garlic Spinach Chicken & <Rice>", description: "Quick and green.", servings: 2,
                     prep_min: 10, cook_min: 20, ingredients: ings,
                     steps: (1...steps).map { "\($0). Step number \($0) of the method, with enough words to fill a line." },
                     macros_per_serving: m, macros_total: m, uses_expiring: [], model_version: "")
    }

    func testTextMatchesTheSpecShape() {
        let t = RecipeExport.text(recipe())
        XCTAssertEqual(t, """
        Garlic Spinach Chicken & <Rice> (serves 2 · 30 min)

        Quick and green.

        Ingredients
        - 300 g chicken thighs
        - 200 g spinach, roughly chopped
        - salt, to taste
        - ½ lime (optional)

        Steps
        1. Step number 1 of the method, with enough words to fill a line.
        2. Step number 2 of the method, with enough words to fill a line.

        Per serving: ≈520 kcal · 38 g protein · 41 g carbs · 22 g fat
        \(RecipeExport.safetyLine)
        \(RecipeExport.allergenLine)
        """)
    }

    func testOwnRecipesHaveNoAILineAndUnknownTimesAreLeftOut() {
        let t = RecipeExport.text(recipe(kcal: 0), .init(isAI: false, timesKnown: (false, false)))
        XCTAssertTrue(t.hasPrefix("Garlic Spinach Chicken & <Rice> (serves 2)\n"))
        XCTAssertFalse(t.contains("AI-generated"))
        XCTAssertTrue(t.hasSuffix(RecipeExport.allergenLine), "the allergy warning is on every export")
        XCTAssertFalse(t.contains("Per serving"), "no nutrition yet: no line")
    }

    func testPDFHasSelectableTextAndPaginates() throws {
        let short = try XCTUnwrap(PDFDocument(data: RecipeExport.pdfData(recipe(steps: 3))))
        XCTAssertEqual(short.pageCount, 1)
        XCTAssertTrue(short.string?.contains("Garlic Spinach Chicken & <Rice>") == true, "title is real text, escaped correctly")
        XCTAssertTrue(short.string?.contains("AI-generated recipe") == true)
        XCTAssertTrue(short.string?.contains("hidden allergens") == true, "the allergy warning is in the PDF")
        let long = try XCTUnwrap(PDFDocument(data: RecipeExport.pdfData(recipe(steps: 45))))
        XCTAssertGreaterThan(long.pageCount, 1)
        XCTAssertTrue(long.string?.contains("Step number 45") == true, "the last step isn't cut off")
    }
}
