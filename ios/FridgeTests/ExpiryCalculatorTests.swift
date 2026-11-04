import Foundation
import XCTest
@testable import Fridge

/// F1.6: runs the shared case table (supabase/tests/expiry_cases.json, also run against
/// app.default_expiry in SQL) against the Swift ExpiryCalculator.
final class ExpiryCalculatorTests: XCTestCase {
    private struct Fixture: Decodable {
        struct CatalogItem: Decodable { let id: Int64; let fridge: Int?; let freezer: Int?; let pantry: Int? }
        struct UserDefault: Decodable {
            let ingredient_id: Int64; let location: StorageLocation; let days: Int; let deleted: Bool
        }
        struct Case: Decodable {
            let name: String
            let ingredient_id: Int64?
            let location: StorageLocation
            let added_at: Date
            let timezone: String?
            let expect_local_date: String
        }
        let default_timezone: String
        let catalog: [CatalogItem]
        let user_overrides: [UserDefault]
        let cases: [Case]
    }

    private func loadFixture() throws -> Fixture {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "expiry_cases", withExtension: "json"),
                                "expiry_cases.json missing from the test bundle")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testSharedCaseTable() throws {
        let fx = try loadFixture()
        XCTAssertGreaterThanOrEqual(fx.cases.count, 10)

        let catalog = Dictionary(uniqueKeysWithValues: fx.catalog.map {
            ($0.id, CatalogShelfLife(fridge: $0.fridge, freezer: $0.freezer, pantry: $0.pantry))
        })
        var defaults: [ExpiryCalculator.DefaultKey: Int] = [:]
        for d in fx.user_overrides where !d.deleted {
            defaults[.init(ingredientId: d.ingredient_id, location: d.location)] = d.days
        }

        for c in fx.cases {
            let tz = try XCTUnwrap(TimeZone(identifier: c.timezone ?? fx.default_timezone), c.name)
            let calc = ExpiryCalculator(timeZone: tz, userDefaults: defaults, catalog: { catalog[$0] })
            let got = calc.defaultExpiry(ingredientId: c.ingredient_id, location: c.location, addedAt: c.added_at)
            XCTAssertEqual(got, try endOfLocalDay(c.expect_local_date, tz), c.name)
        }
    }

    func testFallbackForCustomItemIgnoresCatalogLookup() {
        let calc = ExpiryCalculator(timeZone: .gmt, userDefaults: [:], catalog: { _ in nil })
        XCTAssertEqual(calc.shelfLifeDays(ingredientId: 1_000_000_000_005, location: .fridge), 7)
        XCTAssertEqual(calc.shelfLifeDays(ingredientId: nil, location: .freezer), 90)
        XCTAssertEqual(calc.shelfLifeDays(ingredientId: nil, location: .pantry), 30)
    }

    /// 23:59:59 on yyyy-MM-dd in `tz`, computed independently of ExpiryCalculator.
    private func endOfLocalDay(_ ymd: String, _ tz: TimeZone) throws -> Date {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        var comps = DateComponents()
        comps.year = parts[0]; comps.month = parts[1]; comps.day = parts[2]
        comps.hour = 23; comps.minute = 59; comps.second = 59
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return try XCTUnwrap(cal.date(from: comps), ymd)
    }
}
