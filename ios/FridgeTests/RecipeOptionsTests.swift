import Foundation
import XCTest
@testable import Fridge

/// F2.1: recipe request options (no UI, no network).
final class RecipeOptionsTests: XCTestCase {
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }
    private func at(_ hour: Int) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: hour, minute: 30))!
    }
    private func item(_ name: String, expiresInDays: Double?, staple: Bool = false) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: 1, displayName: name, quantity: 1, unit: "each", location: .fridge,
                   addedAt: .now, expiresAt: expiresInDays.map { Date.now.addingTimeInterval($0 * 86_400) },
                   expiryOverridden: false, status: .active, source: .manual, isStaple: staple)
    }

    func testMealFollowsTimeOfDay() {
        XCTAssertEqual(Meal.forTime(at(7), calendar: cal), .breakfast)
        XCTAssertEqual(Meal.forTime(at(10), calendar: cal), .breakfast)
        XCTAssertEqual(Meal.forTime(at(11), calendar: cal), .lunch)
        XCTAssertEqual(Meal.forTime(at(14), calendar: cal), .lunch)
        XCTAssertEqual(Meal.forTime(at(15), calendar: cal), .dinner)
        XCTAssertEqual(Meal.forTime(at(23), calendar: cal), .dinner)
    }

    func testDefaultsAndRememberedOptionsExceptMeal() {
        let first = RecipeOptions.initial(defaultServings: 4, remembered: nil, now: at(12), calendar: cal)
        XCTAssertEqual(first, RecipeOptions(servings: 4, maxMinutes: nil, meal: .lunch, cuisine: nil,
                                            preferExpiring: true, onlyOnHand: false))
        let last = RecipeOptions(servings: 3, maxMinutes: 30, meal: .dessert, cuisine: "thai",
                                 preferExpiring: false, onlyOnHand: true)
        let next = RecipeOptions.initial(defaultServings: 4, remembered: last, now: at(19), calendar: cal)
        XCTAssertEqual(next.meal, .dinner, "meal always follows the time of day")
        XCTAssertEqual([next.servings, next.maxMinutes], [3, 30])
        XCTAssertEqual(next.cuisine, "thai")
        XCTAssertTrue(next.onlyOnHand && !next.preferExpiring)
    }

    func testServingsCappedAt12() {
        XCTAssertEqual(RecipeOptions.initial(defaultServings: 20, remembered: nil).servings, 12)
        XCTAssertEqual(RecipeOptions.initial(defaultServings: 0, remembered: nil).servings, 1)
    }

    func testPantrySplitLeavesExpiredOut() {
        let p = RecipePantry([item("milk", expiresInDays: 5), item("old yogurt", expiresInDays: -1),
                              item("eggs", expiresInDays: 1), item("salt", expiresInDays: nil, staple: true),
                              item("expired staple", expiresInDays: -2, staple: true)])
        XCTAssertEqual(p.items.map(\.displayName), ["eggs", "milk"], "soonest first, expired left out")
        XCTAssertEqual(p.staples.map(\.displayName), ["salt"])
        XCTAssertEqual(p.expiredCount, 2)
        XCTAssertFalse(p.isEmpty)
        XCTAssertTrue(RecipePantry([item("salt", expiresInDays: nil, staple: true)]).isEmpty,
                      "staples alone count as an empty pantry")
    }

    func testWarnings() {
        let five = RecipePantry((1...5).map { item("i\($0)", expiresInDays: 5) })
        XCTAssertNil(five.warning(excluding: [], onlyOnHand: true))
        let four: Set<UUID> = [five.items[0].id]
        XCTAssertEqual(five.warning(excluding: four, onlyOnHand: true), .verySimple)
        XCTAssertNil(five.warning(excluding: four, onlyOnHand: false))
        let two = Set(five.items.prefix(3).map(\.id))
        XCTAssertEqual(five.warning(excluding: two, onlyOnHand: false), .lowPantry)
        XCTAssertEqual(five.warning(excluding: Set(five.items.map(\.id)), onlyOnHand: false), .nothingSelected)
        XCTAssertEqual(five.itemCount(excluding: two), 2)
    }

    func testRequestLeavesExcludedItemsOutAndCleansCuisine() throws {
        let p = RecipePantry([item("steak", expiresInDays: 4), item("rice", expiresInDays: 300)])
        let steak = p.items.first { $0.displayName == "steak" }!.id
        var o = RecipeOptions.initial(defaultServings: 2, remembered: nil, now: at(18), calendar: cal)
        o.cuisine = "  Korean "
        let r = RecipeRequest(options: o, excluding: [steak])
        XCTAssertEqual(r.exclude_pantry_item_ids, [steak])
        XCTAssertEqual(r.cuisine, "korean")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(r)) as! [String: Any]
        XCTAssertEqual(json["meal"] as? String, "dinner")
        XCTAssertTrue(json["max_minutes"] is NSNull, "any time is sent as null")
        XCTAssertEqual(json["prefer_expiring"] as? Bool, true)
        XCTAssertEqual(json["only_on_hand"] as? Bool, false)
        XCTAssertEqual(json["servings"] as? Int, 2)
        o.cuisine = "   "
        XCTAssertNil(RecipeRequest(options: o, excluding: []).cuisine)
    }
}
