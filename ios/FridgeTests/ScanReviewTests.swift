import Foundation
import XCTest
@testable import Fridge

/// F1.3: scan review rules (no UI, no network).
final class ScanReviewTests: XCTestCase {
    private func draftItem(_ name: String, id: Int64?, category: String?, qty: Double? = 1, unit: String? = "each",
                           low: Bool = false, staple: Bool = false, seenAs: String? = nil) -> ScanAPI.DraftItem {
        ScanAPI.DraftItem(temp_id: UUID().uuidString, name: seenAs ?? name, ingredient_id: id, display_name: name,
                          category: category, match: id == nil ? "none" : "exact", quantity: qty, unit: unit,
                          confidence: low ? 0.4 : 0.9, low_confidence: low, suggest_staple: staple, photo_indexes: [0])
    }

    private func review(_ items: [ScanAPI.DraftItem], placement: Placement = .fridge) -> ScanReview {
        ScanReview(scan: ScanAPI.Response(location: placement.rawValue, items: items, usage: nil), placement: placement)
    }

    private func pantryItem(_ name: String, id: Int64, location: StorageLocation = .fridge, qty: Double = 1,
                            staple: Bool = false) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: id, displayName: name, quantity: qty, unit: "each", location: location,
                   addedAt: .now, expiresAt: .now.addingTimeInterval(86_400 * 3), expiryOverridden: false,
                   status: .active, source: .manual, isStaple: staple)
    }

    func testBuildsRowsFromScanWithPlacesAndFlags() {
        let r = review([
            draftItem("egg", id: 38, category: "dairy", qty: 6, seenAs: "eggs"),
            draftItem("soy sauce", id: 89, category: "condiments", qty: nil, unit: "ml", staple: true),
            draftItem("mystery jar", id: nil, category: nil, low: true),
        ])
        let egg = r.rows.first { $0.draft.ingredient?.name == "egg" }!
        XCTAssertEqual(egg.draft.placement, .fridge)
        XCTAssertEqual(egg.draft.quantity, 6)
        XCTAssertEqual(egg.seenAs, "eggs")
        let soy = r.rows.first { $0.draft.ingredient?.name == "soy sauce" }!
        XCTAssertEqual(soy.draft.placement, .staples, "suggested staples go to Staples")
        XCTAssertTrue(soy.draft.expiryOverridden && soy.draft.chosenExpiry == nil, "staples: no expiry")
        let jar = r.rows.first { $0.draft.ingredient?.name == "mystery jar" }!
        XCTAssertTrue(jar.isCustom && jar.lowConfidence)
        XCTAssertEqual(r.rows.last?.draft.ingredient?.name, "mystery jar", "unknown category sorts last")
    }

    func testScanningStaplesPutsEverythingInStaples() {
        let r = review([draftItem("cumin", id: 80, category: "spices", qty: nil, unit: "g")], placement: .staples)
        XCTAssertEqual(r.rows[0].draft.placement, .staples)
    }

    func testUnsureRowsSortFirstWithinCategory() {
        let r = review([draftItem("milk", id: 39, category: "dairy"), draftItem("cheddar cheese", id: 41, category: "dairy", low: true)])
        XCTAssertEqual(r.rows.map { $0.draft.ingredient!.name }, ["cheddar cheese", "milk"])
    }

    func testDeleteAndDeleteAllUnsureAndEmptyMeansDiscard() {
        var r = review([draftItem("milk", id: 39, category: "dairy"), draftItem("x", id: nil, category: nil, low: true),
                        draftItem("y", id: nil, category: nil, low: true)])
        XCTAssertEqual(r.unsureCount, 2)
        r.deleteAllUnsure()
        XCTAssertEqual(r.rows.count, 1)
        XCTAssertFalse(r.isEmpty)
        r.delete(r.rows[0].id)
        XCTAssertTrue(r.isEmpty, "all rows deleted: Save becomes Discard scan")
    }

    func testEditingToAnotherIngredientClearsTheGuessFlags() {
        var r = review([draftItem("chedd", id: nil, category: nil, low: true)])
        var d = r.rows[0].draft
        d.ingredient = IngredientChoice(id: 41, name: "cheddar cheese", category: "dairy", defaultUnit: "g", isCustom: false)
        r.update(r.rows[0].id, draft: d)
        XCTAssertFalse(r.rows[0].lowConfidence)
        XCTAssertFalse(r.rows[0].isCustom)
        XCTAssertEqual(r.rows[0].category, "dairy")
        XCTAssertEqual(r.saveItems.first?.ingredient_id, 41)
    }

    func testAddedByHandRows() {
        var r = review([])
        var d = ItemDraft()
        d.pick(IngredientChoice(id: 10, name: "tomato", category: "produce", defaultUnit: "each", isCustom: false), sessionPlacement: nil)
        r.add(d)
        XCTAssertEqual(r.saveCount, 1)
        XCTAssertTrue(r.rows[0].addedByHand)
    }

    func testMoveEverythingKeepsStaplesAndAmounts() {
        var r = review([draftItem("egg", id: 38, category: "dairy", qty: 6),
                        draftItem("soy sauce", id: 89, category: "condiments", qty: nil, staple: true)])
        r.setPlacementForAll(.freezer)
        let egg = r.rows.first { $0.draft.ingredient?.name == "egg" }!
        XCTAssertEqual(egg.draft.placement, .freezer)
        XCTAssertEqual(egg.draft.quantity, 6, "the scanned amount survives the move")
        XCTAssertEqual(r.rows.first { $0.draft.ingredient?.name == "soy sauce" }!.draft.placement, .staples,
                       "staples stay staples")
    }

    func testAlreadyHaveChoices() {
        var r = review([draftItem("egg", id: 38, category: "dairy", qty: 4), draftItem("milk", id: 39, category: "dairy")])
        let existing = pantryItem("egg", id: 38, qty: 6)
        r.markExisting([existing, pantryItem("milk", id: 39, location: .freezer)])
        let eggRow = r.rows.first { $0.draft.ingredient?.id == 38 }!
        XCTAssertEqual(eggRow.existing?.id, existing.id)
        XCTAssertNil(r.rows.first { $0.draft.ingredient?.id == 39 }!.existing, "a different location isn't a duplicate")

        XCTAssertEqual(r.saveCount, 2, "default: add as another batch")
        r.setExistingChoice(eggRow.id, .update)
        XCTAssertEqual(r.saveItems.first { $0.ingredient_id == 38 }?.update_item_id, existing.id)
        XCTAssertEqual(r.saveItems.first { $0.ingredient_id == 38 }?.quantity, 4, "update replaces with the scanned amount")
        r.setExistingChoice(eggRow.id, .skip)
        XCTAssertEqual(r.saveCount, 1)
        XCTAssertNil(r.saveItems.first { $0.ingredient_id == 38 })
    }

    func testSavePayload() throws {
        let r = review([draftItem("egg", id: 38, category: "dairy", qty: 6),
                        draftItem("dragon fruit", id: nil, category: nil, qty: nil),
                        draftItem("cumin", id: 80, category: "spices", qty: nil, unit: "g", staple: true)])
        let items = r.saveItems
        let fruit = items.first { $0.display_name == "dragon fruit" }!
        XCTAssertNil(fruit.ingredient_id)
        XCTAssertEqual(fruit.custom_name, "dragon fruit", "unmatched names become custom items on save")
        let cumin = items.first { $0.display_name == "cumin" }!
        XCTAssertTrue(cumin.is_staple && cumin.expiry_overridden)
        let json = String(decoding: try JSONEncoder().encode(items.first { $0.display_name == "egg" }!), as: UTF8.self)
        XCTAssertFalse(json.contains("expires_at"), "rule-based dates are left to the server (F1.6)")
        XCTAssertTrue(json.contains("\"quantity\":6"))
    }

    func testDraftRoundTripsThroughJSON() throws {
        var r = review([draftItem("egg", id: 38, category: "dairy", qty: 6, seenAs: "eggs")])
        r.rows[0].existingChoice = .skip
        let back = try JSONDecoder().decode(ScanReview.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
    }

    func testUsageText() {
        let u = ScanAPI.Usage(today: 8, daily_limit: 10, this_month: 20, monthly_limit: 60, left: 2, resets_at: nil)
        XCTAssertEqual(u.text, "2 scans left today")
        let month = ScanAPI.Usage(today: 1, daily_limit: 10, this_month: 59, monthly_limit: 60, left: 1, resets_at: nil)
        XCTAssertEqual(month.text, "1 scan left this month")
        XCTAssertEqual(ScanAPI.Usage(today: 10, daily_limit: 10, this_month: 30, monthly_limit: 60, left: 0, resets_at: nil).text,
                       "No scans left")
    }

    func testLimitErrorMapping() {
        let body = Data(#"{"error":{"code":"limit_reached","message":"You've used today's 10 scans."}}"#.utf8)
        XCTAssertEqual(ScanAPI.map(code: 429, data: body), .limitReached("You've used today's 10 scans."))
    }
}
