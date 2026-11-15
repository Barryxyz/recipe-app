import XCTest
@testable import Fridge

/// "Did you mean…?" before a custom item.
final class CustomSuggestionsTests: XCTestCase {
    private func c(_ id: Int64, _ name: String, custom: Bool = false) -> IngredientChoice {
        IngredientChoice(id: id, name: name, category: "produce", defaultUnit: "g", isCustom: custom)
    }

    func testWordsLastFirstWithoutNoise() {
        XCTAssertEqual(CustomSuggestions.words(in: "Trader Joe's Organic Mango Salsa"), ["salsa", "mango", "joe", "trader"])
        XCTAssertEqual(CustomSuggestions.words(in: "a big bag"), ["bag", "big"])
    }

    func testResultsComeFirstThenWordSearches() async {
        let found = await CustomSuggestions.suggestions(for: "mango salsa", results: [c(1, "salsa verde")]) { word in
            word == "salsa" ? [self.c(1, "salsa verde"), self.c(2, "salsa")] : word == "mango" ? [self.c(3, "mango")] : []
        }
        XCTAssertEqual(found.map(\.name), ["salsa verde", "salsa", "mango"])
    }

    func testCustomItemsAreNeverSuggested() async {
        let found = await CustomSuggestions.suggestions(for: "zz mystery", results: [c(9, "zz mystery", custom: true)]) { _ in [] }
        XCTAssertTrue(found.isEmpty)
    }

    func testAtMostThree() async {
        let many = (1...6).map { c(Int64($0), "item \($0)") }
        let found = await CustomSuggestions.suggestions(for: "item", results: many) { _ in many }
        XCTAssertEqual(found.count, 3)
    }
}
