import Foundation
import XCTest
@testable import Fridge

/// F1.5: add/edit form logic (no UI, no network).
final class ItemDraftTests: XCTestCase {
    private func choice(_ category: String?, unit: String? = "g", custom: Bool = false) -> IngredientChoice {
        IngredientChoice(id: custom ? 1_000_000_000_001 : 42, name: "thing", category: category,
                         defaultUnit: unit, isCustom: custom)
    }

    func testDefaultLocationByCategory() {
        for c in ["produce", "dairy", "meat", "seafood", "protein", "condiments", "drinks"] {
            XCTAssertEqual(PantryDefaults.location(forCategory: c), .fridge, c)
        }
        XCTAssertEqual(PantryDefaults.location(forCategory: "frozen"), .freezer)
        for c in ["bakery", "grains", "baking", "spices", "oils", "canned", "nuts", "snacks"] {
            XCTAssertEqual(PantryDefaults.location(forCategory: c), .pantry, c)
        }
        XCTAssertEqual(PantryDefaults.location(forCategory: nil), .fridge, "custom items")
        XCTAssertEqual(PantryDefaults.location(forCategory: "something new"), .fridge)
    }

    func testPickFillsDefaults() {
        var d = ItemDraft()
        d.quantity = 7
        d.overrideExpiry(.now)
        d.pick(choice("grains", unit: "g"), sessionLocation: nil)
        XCTAssertEqual(d.unit, .g)
        XCTAssertEqual(d.quantity, 1)
        XCTAssertEqual(d.location, .pantry)
        XCTAssertFalse(d.expiryOverridden, "a new pick drops the previous item's date")
        XCTAssertNil(d.chosenExpiry)
    }

    func testSessionLocationWinsOverCategory() {
        var d = ItemDraft()
        d.pick(choice("produce"), sessionLocation: .freezer)
        XCTAssertEqual(d.location, .freezer)
    }

    func testUnknownCatalogUnitFallsBackToEach() {
        XCTAssertEqual(MeasureUnit(catalogUnit: "furlong"), .each)
        XCTAssertEqual(MeasureUnit(catalogUnit: nil), .each)
        XCTAssertEqual(MeasureUnit(catalogUnit: "ml"), .ml)
    }

    func testStepperStepsByUnit() {
        var d = ItemDraft(ingredient: choice("dairy"), quantity: 1, unit: .each)
        d.increment()
        XCTAssertEqual(d.quantity, 2)
        d.unit = .g
        d.quantity = 100
        d.increment()
        XCTAssertEqual(d.quantity, 150)
        d.unit = .kg
        d.quantity = 1
        d.decrement()
        XCTAssertEqual(d.quantity, 0.5)
    }

    func testDecrementStopsAtZero() {
        var d = ItemDraft(ingredient: choice("dairy"), quantity: 20, unit: .g)
        d.decrement()
        XCTAssertEqual(d.quantity, 0)
        d.decrement()
        XCTAssertEqual(d.quantity, 0)
    }

    func testSomeToggle() {
        var d = ItemDraft(ingredient: choice("dairy"), quantity: 3)
        d.setSome(true)
        XCTAssertTrue(d.isSome)
        XCTAssertNil(d.quantity)
        d.increment()   // "some" + step starts counting from 0
        XCTAssertEqual(d.quantity, 1)
        d.setSome(true)
        d.decrement()   // no-op on "some"
        XCTAssertNil(d.quantity)
        d.setSome(false)
        XCTAssertEqual(d.quantity, 1)
    }

    func testCanAdd() {
        var d = ItemDraft()
        XCTAssertFalse(d.canAdd, "needs an ingredient")
        d.pick(choice("dairy"), sessionLocation: nil)
        XCTAssertTrue(d.canAdd)
        d.quantity = 0
        XCTAssertFalse(d.canAdd, "can't add zero of something")
        XCTAssertTrue(d.canSaveEdit, "an edit can go to zero (then offers Mark used)")
        d.quantity = -1
        XCTAssertFalse(d.canSaveEdit)
        d.quantity = .nan
        XCTAssertFalse(d.canAdd)
        d.setSome(true)
        XCTAssertTrue(d.canAdd, "\"some\" is a valid amount")
    }

    func testOverrideExpiryAndNoExpiry() {
        var d = ItemDraft(ingredient: choice("dairy"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        d.overrideExpiry(date)
        XCTAssertTrue(d.expiryOverridden)
        XCTAssertEqual(d.chosenExpiry, date)
        d.overrideExpiry(nil)
        XCTAssertTrue(d.expiryOverridden, "no expiry is still the user's choice")
        XCTAssertNil(d.chosenExpiry)
    }

    func testDaysBetweenLocalDays() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let added = ISO8601DateFormatter().date(from: "2026-03-11T05:30:00Z")!     // Mar 10, 22:30 local
        let expiry = ISO8601DateFormatter().date(from: "2026-03-13T08:00:00Z")!    // Mar 13, 01:00 local
        XCTAssertEqual(ItemDraft.days(from: added, to: expiry, in: la), 3)
        XCTAssertEqual(ItemDraft.days(from: expiry, to: added, in: la), 0, "never negative")
    }

    func testEndOfDayMatchesExpiryCalculator() throws {
        let la = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let added = ISO8601DateFormatter().date(from: "2026-03-10T15:00:00Z")!
        let calc = ExpiryCalculator(timeZone: la, userDefaults: [:], catalog: { _ in nil })
        let ruleDate = calc.defaultExpiry(ingredientId: nil, location: .fridge, addedAt: added)
        // Picking that same day in the date picker gives the same instant.
        XCTAssertEqual(ItemDraft.endOfDay(ruleDate.addingTimeInterval(-3600), in: la), ruleDate)
        XCTAssertEqual(ItemDraft.days(from: added, to: ruleDate, in: la), 7)
    }

    func testQuantityFormat() {
        XCTAssertEqual(QuantityFormat.string(nil, unit: "g"), "some")
        XCTAssertEqual(QuantityFormat.string(6, unit: "each"), "6")
        XCTAssertEqual(QuantityFormat.string(0.5, unit: "kg"), "0.5 kg")
        XCTAssertEqual(QuantityFormat.string(250, unit: "g"), "250 g")
    }

    func testCustomIdRange() {
        let base = PantryItem(id: UUID(), ingredientId: 5, displayName: "x", quantity: 1, unit: "each",
                              location: .fridge, addedAt: .now, expiresAt: nil, expiryOverridden: false,
                              status: .active, source: .manual)
        XCTAssertFalse(base.isCustom)
        var custom = base
        custom.ingredientId = PantryItem.customIdStart
        XCTAssertTrue(custom.isCustom)
    }
}
