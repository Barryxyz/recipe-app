import XCTest
import Supabase
@testable import Fridge

/// F5.2: event props are counts and options only, never typed text.
final class EventPropsTests: XCTestCase {
    private func draft(_ name: String, id: Int64) -> ItemDraft {
        var d = ItemDraft()
        d.ingredient = IngredientChoice(id: id, name: name, category: "produce", defaultUnit: "each", isCustom: false)
        return d
    }

    func testScanSavedCounts() {
        var review = ScanReview(rows: [.init(draft: draft("apple", id: 1)), .init(draft: draft("pear", id: 2)),
                                       .init(draft: draft("kiwi", id: 3))], placement: .fridge)
        review.detectedCount = 3
        review.editedIds = []
        review.delete(review.rows[0].id)
        var d = review.rows[0].draft
        d.quantity = 4
        review.update(review.rows[0].id, draft: d)
        review.add(draft("lime", id: 4))
        XCTAssertEqual(review.eventProps, ["detected": 3, "deleted": 1, "edited": 1, "added_manually": 1, "saved": 3])
    }

    func testTypedCuisineIsNotSent() {
        var o = RecipeOptions.initial(defaultServings: 2, remembered: nil)
        o.cuisine = "Grandma's Sunday"
        let props = RecipeRequest(options: o, excluding: []).eventProps
        XCTAssertEqual(props["cuisine"], .string("other"))
        o.cuisine = "thai"
        XCTAssertEqual(RecipeRequest(options: o, excluding: []).eventProps["cuisine"], .string("thai"))
    }
}
