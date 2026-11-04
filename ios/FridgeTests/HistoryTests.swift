import Foundation
import XCTest
@testable import Fridge

/// F1.8: history headers, month strings and insights decoding.
final class HistoryTests: XCTestCase {
    /// Gregorian, Los Angeles, weeks starting Sunday (US).
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        c.locale = Locale(identifier: "en_US")
        c.firstWeekday = 1
        return c
    }

    private func local(_ s: String) -> Date {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.date(from: s)!
    }

    // Wednesday Nov 4, 2026; this week started Sunday Nov 1.
    private var now: Date { local("2026-11-04 12:00") }

    func testWeekAndMonthLabels() {
        XCTAssertEqual(HistoryBuckets.label(for: local("2026-11-04 08:00"), now: now, calendar: cal), "This week")
        XCTAssertEqual(HistoryBuckets.label(for: local("2026-11-01 00:01"), now: now, calendar: cal), "This week")
        XCTAssertEqual(HistoryBuckets.label(for: local("2026-10-31 23:59"), now: now, calendar: cal), "Last week")
        XCTAssertEqual(HistoryBuckets.label(for: local("2026-10-25 00:00"), now: now, calendar: cal), "Last week")
        XCTAssertEqual(HistoryBuckets.label(for: local("2026-10-24 23:59"), now: now, calendar: cal), "October")
        XCTAssertEqual(HistoryBuckets.label(for: local("2025-12-20 10:00"), now: now, calendar: cal), "December 2025",
                       "the year is shown for other years")
    }

    func testSectionsKeepOrderAndGroupConsecutive() {
        func used(_ name: String, _ when: String) -> PantryItem {
            PantryItem(id: UUID(), ingredientId: 1, displayName: name, quantity: 1, unit: "each", location: .fridge,
                       addedAt: local("2026-09-01 10:00"), expiresAt: nil, expiryOverridden: false,
                       status: .used, source: .manual, statusChangedAt: local(when))
        }
        let items = [used("a", "2026-11-03 10:00"), used("b", "2026-11-02 10:00"),
                     used("c", "2026-10-28 10:00"), used("d", "2026-10-10 10:00"), used("e", "2026-09-10 10:00")]
        let sections = HistoryBuckets.sections(items, now: now, calendar: cal)
        XCTAssertEqual(sections.map(\.title), ["This week", "Last week", "October", "September"])
        XCTAssertEqual(sections.map { $0.items.map(\.displayName) }, [["a", "b"], ["c"], ["d"], ["e"]])
    }

    func testMonthStartString() {
        XCTAssertEqual(HistoryBuckets.monthStartString(local("2026-11-30 23:59"), calendar: cal), "2026-11-01")
        XCTAssertEqual(HistoryBuckets.monthStartString(local("2026-01-01 00:00"), calendar: cal), "2026-01-01")
    }

    func testInsightsDecodeAndWasteText() throws {
        let json = """
        {"month_start":"2026-10-01","used":7,"thrown_out":2,"waste_rate":0.222,
         "thrown_most":[{"name":"spinach","count":2}],"bought_most":[{"name":"egg","count":6},{"name":"milk","count":2}]}
        """
        let i = try JSONDecoder().decode(PantryInsights.self, from: Data(json.utf8))
        XCTAssertEqual(i.used, 7)
        XCTAssertEqual(i.thrownOut, 2)
        XCTAssertEqual(i.thrownMost.first, .init(name: "spinach", count: 2))
        XCTAssertEqual(i.boughtMost.map(\.name), ["egg", "milk"])
        XCTAssertEqual(i.wasteText?.filter(\.isNumber), "22")

        let few = try JSONDecoder().decode(PantryInsights.self, from: Data("""
        {"used":1,"thrown_out":0,"waste_rate":null,"thrown_most":[],"bought_most":[]}
        """.utf8))
        XCTAssertNil(few.wasteRate)
        XCTAssertNil(few.wasteText, "hidden below 5 items")
    }

    func testFilterStatuses() {
        XCTAssertEqual(HistoryFilter.all.statuses, [.used, .discarded])
        XCTAssertEqual(HistoryFilter.used.statuses, [.used])
        XCTAssertEqual(HistoryFilter.thrownOut.statuses, [.discarded])
    }
}
