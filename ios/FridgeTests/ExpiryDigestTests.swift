import XCTest
@testable import Fridge

/// F5.1: which days get a reminder, and what it says.
final class ExpiryDigestTests: XCTestCase {
    var cal = Calendar(identifier: .gregorian)
    // Tuesday 10 Nov 2026, 08:00 local
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 8))!

    override func setUp() { cal.timeZone = TimeZone(identifier: "Europe/London")! }

    /// Expires at the end of the local day, `days` from today (as F1.6 stores it).
    private func item(_ name: String, days: Int?, staple: Bool = false, status: PantryItem.Status = .active) -> PantryItem {
        let exp = days.flatMap { cal.date(byAdding: .day, value: $0, to: cal.startOfDay(for: now)) }
            .flatMap { cal.date(bySettingHour: 23, minute: 59, second: 59, of: $0) }
        return PantryItem(id: UUID(), ingredientId: 1, displayName: name, quantity: 1, unit: "each", location: .fridge,
                          addedAt: now, expiresAt: exp, expiryOverridden: false, status: status, source: .manual,
                          isStaple: staple)
    }

    private func digest(_ items: [PantryItem], dayOffset: Int = 0, lead: Int = 2) -> (title: String, body: String)? {
        ExpiryDigest.digest(items: items, day: cal.date(byAdding: .day, value: dayOffset, to: now)!, leadDays: lead, calendar: cal)
    }

    func testSpecExample() {
        let d = digest([item("spinach", days: 1), item("milk", days: 0), item("chicken thighs", days: 1)])
        XCTAssertEqual(d?.title, "3 items expire soon")
        XCTAssertEqual(d?.body, "milk (today), chicken thighs, spinach (tomorrow)")
    }

    func testMoreThanThreeAndSingleItem() {
        let d = digest([item("a", days: 0), item("b", days: 0), item("c", days: 1), item("d", days: 1), item("e", days: 1)])
        XCTAssertEqual(d?.body, "a, b (today), c (tomorrow) +2 more")
        XCTAssertEqual(digest([item("milk", days: 1)])?.title, "Milk expires tomorrow")
    }

    func testLeadTimeStaplesAndUsedItems() {
        let items = [item("yogurt", days: 2), item("salt", days: 0, staple: true), item("eggs", days: 0, status: .used),
                     item("rice", days: nil)]
        XCTAssertNil(digest(items, lead: 2), "2 days away is outside a 2-day warning; staples, used and no-date items never count")
        XCTAssertEqual(digest(items, lead: 3)?.body, "yogurt (in 2 days)")
    }

    func testExpiredItemsAreMentionedOnceTheDayAfter() {
        let milk = item("milk", days: -1)
        XCTAssertEqual(digest([milk])?.title, "Milk expired yesterday")
        XCTAssertNil(digest([item("milk", days: -2)]), "only the day after")
        XCTAssertEqual(digest([milk, item("ham", days: 0)])?.body, "milk (expired), ham (today)")
    }

    func testPlanSkipsEmptyDaysAndPastTimes() {
        let items = [item("milk", days: 0), item("fish", days: 4)]
        let plan = ExpiryDigest.plan(items: items, now: now, days: 7, leadDays: 2, hour: 9, minute: 0, calendar: cal)
        let days = plan.map { cal.dateComponents([.day], from: cal.startOfDay(for: now), to: $0.fireDate).day! }
        // milk: today (and "expired" tomorrow); fish: days 3 and 4, and "expired" on day 5
        XCTAssertEqual(days, [0, 1, 3, 4, 5])
        XCTAssertEqual(cal.component(.hour, from: plan[0].fireDate), 9)
        let late = cal.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        XCTAssertEqual(ExpiryDigest.plan(items: items, now: late, days: 7, leadDays: 2, hour: 9, minute: 0, calendar: cal).first
            .map { cal.dateComponents([.day], from: cal.startOfDay(for: now), to: $0.fireDate).day! }, 1,
                       "today's 9:00 has passed")
        XCTAssertTrue(ExpiryDigest.plan(items: [], now: now, days: 7, leadDays: 2, hour: 9, minute: 0, calendar: cal).isEmpty)
    }

    func testMarkedUsedDisappearsFromDigest() {
        XCTAssertNil(digest([item("milk", days: 0, status: .used)]))
    }
}
