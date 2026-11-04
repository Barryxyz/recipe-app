import Foundation
import XCTest
@testable import Fridge

/// F1.4: expiry badges (device-local dates), grouping of batches, sorting and search.
final class PantryGroupingTests: XCTestCase {
    private var la: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }

    /// A local time in Los Angeles.
    private func local(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = la
        f.timeZone = la.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.date(from: s)!
    }

    private func item(_ name: String, ingredient: Int64? = 1, location: StorageLocation = .fridge,
                      qty: Double? = 1, unit: String? = "each", expires: String?) -> PantryItem {
        PantryItem(id: UUID(), ingredientId: ingredient, displayName: name, quantity: qty, unit: unit,
                   location: location, addedAt: local("2026-11-01 09:00:00"),
                   expiresAt: expires.map(local), expiryOverridden: false, status: .active, source: .manual)
    }

    // MARK: Badges

    func testBadgeBoundaries() {
        let now = local("2026-11-04 21:00:00")
        func badge(_ s: String?) -> ExpiryBadge { ExpiryBadge(expiresAt: s.map(local), now: now, calendar: la) }

        XCTAssertEqual(badge("2026-11-03 23:59:59"), .expired)
        XCTAssertEqual(badge("2026-11-04 20:59:59"), .expired, "earlier today counts as expired")
        XCTAssertEqual(badge("2026-11-04 23:59:59"), .today)
        XCTAssertEqual(badge("2026-11-05 23:59:59"), .tomorrow)
        XCTAssertEqual(badge("2026-11-06 23:59:59"), .days(2))
        XCTAssertEqual(badge("2026-11-07 23:59:59"), .days(3))
        XCTAssertEqual(badge("2026-11-08 23:59:59"), .later(local("2026-11-08 23:59:59")))
        XCTAssertEqual(badge(nil), .none)
    }

    func testBadgeJustBeforeAndAfterMidnight() {
        let expires = local("2026-11-05 23:59:59")
        XCTAssertEqual(ExpiryBadge(expiresAt: expires, now: local("2026-11-04 23:59:58"), calendar: la), .tomorrow)
        XCTAssertEqual(ExpiryBadge(expiresAt: expires, now: local("2026-11-05 00:00:01"), calendar: la), .today)
        XCTAssertEqual(ExpiryBadge(expiresAt: expires, now: local("2026-11-06 00:00:00"), calendar: la), .expired)
    }

    func testExpiredAndUseSoonAreSeparate() {
        XCTAssertTrue(ExpiryBadge.expired.isExpired)
        XCTAssertFalse(ExpiryBadge.expired.isUseSoon, "expired items have their own section")
        XCTAssertTrue(ExpiryBadge.today.isUseSoon)
        XCTAssertTrue(ExpiryBadge.tomorrow.isUseSoon)
        XCTAssertTrue(ExpiryBadge.days(3).isUseSoon)
        XCTAssertFalse(ExpiryBadge.later(.now).isUseSoon)
        XCTAssertFalse(ExpiryBadge.none.isUseSoon)
        XCTAssertFalse(ExpiryBadge.today.isExpired)
    }

    // MARK: Grouping

    func testSameIngredientSameLocationGroupsEarliestFirst() {
        let newer = item("milk", ingredient: 39, expires: "2026-11-12 23:59:59")
        let older = item("milk", ingredient: 39, expires: "2026-11-06 23:59:59")
        let groups = PantryGrouping.groups([newer, older])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].count, 2)
        XCTAssertEqual(groups[0].earliest.id, older.id, "earliest batch first")
        XCTAssertEqual(groups[0].badge(now: local("2026-11-04 12:00:00"), calendar: la), .days(2))
    }

    func testDifferentLocationsDontGroup() {
        let fridge = item("milk", ingredient: 39, location: .fridge, expires: "2026-11-06 23:59:59")
        let freezer = item("milk", ingredient: 39, location: .freezer, expires: "2027-01-06 23:59:59")
        XCTAssertEqual(PantryGrouping.groups([fridge, freezer]).count, 2)
    }

    func testItemsWithoutIngredientGroupByName() {
        let a = item("Leftover soup", ingredient: nil, expires: nil)
        let b = item("leftover soup ", ingredient: nil, expires: nil)
        let c = item("Pizza", ingredient: nil, expires: nil)
        XCTAssertEqual(PantryGrouping.groups([a, b, c]).count, 2)
    }

    func testTotalsAddUpOnlyWhenUnitsMatch() {
        let g1 = PantryGroup(items: [item("milk", qty: 1, unit: "l", expires: nil), item("milk", qty: 0.5, unit: "l", expires: nil)])
        XCTAssertEqual(g1.amountText, "1.5 l")
        let g2 = PantryGroup(items: [item("milk", qty: 1, unit: "l", expires: nil), item("milk", qty: 500, unit: "ml", expires: nil)])
        XCTAssertEqual(g2.amountText, "2 batches")
        let g3 = PantryGroup(items: [item("milk", qty: 1, unit: "l", expires: nil), item("milk", qty: nil, unit: "l", expires: nil)])
        XCTAssertEqual(g3.amountText, "2 batches", "\"some\" can't be added up")
        let single = PantryGroup(items: [item("eggs", qty: 6, unit: "each", expires: nil)])
        XCTAssertEqual(single.amountText, "6")
        XCTAssertFalse(single.isGroup)
    }

    func testSectionsSplitExpiredStaplesAndRegular() {
        let now = local("2026-11-04 12:00:00")
        var salt = item("salt", ingredient: 77, location: .pantry, qty: nil, expires: nil)
        salt.isStaple = true
        var oldFlour = item("flour", ingredient: 71, location: .pantry, expires: "2026-11-01 23:59:59")
        oldFlour.isStaple = true
        let milk = item("milk", ingredient: 39, expires: "2026-11-06 23:59:59")
        let oldEggs = item("eggs", ingredient: 38, expires: "2026-11-02 23:59:59")
        let parts = PantryGrouping.sections([salt, oldFlour, milk, oldEggs], now: now, calendar: la)
        XCTAssertEqual(Set(parts.expired.map(\.displayName)), ["flour", "eggs"], "a dated staple can expire too")
        XCTAssertEqual(parts.staples.map(\.displayName), ["salt"])
        XCTAssertEqual(parts.regular.map(\.displayName), ["milk"])
    }

    // MARK: Sorting & search

    func testSortByEarliestExpiryNoExpiryLast() {
        let salt = item("salt", ingredient: 77, expires: nil)
        let milk = item("milk", ingredient: 39, expires: "2026-11-10 23:59:59")
        let eggs = item("eggs", ingredient: 38, expires: "2026-11-05 23:59:59")
        let oldMilk = item("milk", ingredient: 39, expires: "2026-11-04 23:59:59")
        let names = PantryGrouping.groups([salt, milk, eggs, oldMilk]).map(\.name)
        XCTAssertEqual(names, ["milk", "eggs", "salt"], "the milk group sorts by its oldest batch")
    }

    func testSortAToZ() {
        let groups = PantryGrouping.groups([
            item("zucchini", ingredient: 3, expires: "2026-11-05 23:59:59"),
            item("Apple", ingredient: 1, expires: "2026-12-01 23:59:59"),
            item("banana", ingredient: 2, expires: nil),
        ], sort: .name)
        XCTAssertEqual(groups.map(\.name), ["Apple", "banana", "zucchini"])
    }

    func testSearchPutsExactMatchFirst() {
        let items = [
            item("TEST item 250", ingredient: 1, expires: "2026-11-05 23:59:59"),
            item("TEST item 25", ingredient: 2, expires: "2027-01-29 23:59:59"),
            item("TEST item 251", ingredient: 3, expires: "2026-11-06 23:59:59"),
            item("Old TEST item 25", ingredient: 4, expires: "2026-11-04 23:59:59"),
        ]
        let names = PantryGrouping.searchResults(items, search: "test item 25").map(\.name)
        XCTAssertEqual(names, ["TEST item 25", "TEST item 250", "TEST item 251", "Old TEST item 25"],
                       "exact, then starts-with (by expiry), then contains")
    }

    func testSearchIsCaseAndAccentInsensitive() {
        let items = [item("Jalapeño", ingredient: 21, expires: nil), item("milk", ingredient: 39, expires: nil)]
        XCTAssertEqual(PantryGrouping.filter(items, search: "jalapeno").map(\.displayName), ["Jalapeño"])
        XCTAssertEqual(PantryGrouping.filter(items, search: "  ").count, 2)
        XCTAssertEqual(PantryGrouping.filter(items, search: "MIL").map(\.displayName), ["milk"])
    }
}
