import Foundation
import Supabase

/// F1.8: monthly numbers from `app.pantry_insights`.
struct PantryInsights: Decodable, Equatable {
    struct Entry: Decodable, Equatable, Identifiable {
        let name: String
        let count: Int
        var id: String { name }
    }

    let used: Int
    let thrownOut: Int
    /// nil when the month has fewer than 5 items.
    let wasteRate: Double?
    let thrownMost: [Entry]
    let boughtMost: [Entry]

    enum CodingKeys: String, CodingKey {
        case used
        case thrownOut = "thrown_out"
        case wasteRate = "waste_rate"
        case thrownMost = "thrown_most"
        case boughtMost = "bought_most"
    }

    /// "11%", or nil when there's too little data.
    var wasteText: String? {
        wasteRate.map { $0.formatted(.percent.precision(.fractionLength(0))) }
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all, used, thrownOut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .used: "Used"
        case .thrownOut: "Thrown out"
        }
    }
    /// Status values to fetch.
    var statuses: [PantryItem.Status] {
        switch self {
        case .all: [.used, .discarded]
        case .used: [.used]
        case .thrownOut: [.discarded]
        }
    }
}

/// History list headers: "This week", "Last week", then "October" (with the year when it
/// isn't the current one). Pure, so it can be unit tested.
enum HistoryBuckets {
    static func label(for date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now) {
            if date >= thisWeek.start { return "This week" }
            if let lastWeekStart = calendar.date(byAdding: .weekOfYear, value: -1, to: thisWeek.start),
               date >= lastWeekStart { return "Last week" }
        }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = calendar.locale ?? .current
        f.setLocalizedDateFormatFromTemplate(sameYear ? "MMMM" : "MMMM yyyy")
        return f.string(from: date)
    }

    /// Consecutive sections in list order (items must already be newest first).
    static func sections(_ items: [PantryItem], now: Date = .now, calendar: Calendar = .current)
        -> [(title: String, items: [PantryItem])] {
        var out: [(title: String, items: [PantryItem])] = []
        for item in items {
            let title = label(for: item.statusChangedAt ?? item.addedAt, now: now, calendar: calendar)
            if out.last?.title == title { out[out.count - 1].items.append(item) } else { out.append((title, [item])) }
        }
        return out
    }

    /// First day of the month containing `date`, as yyyy-MM-dd for the insights RPC.
    static func monthStartString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d-01", c.year ?? 1970, c.month ?? 1)
    }
}

enum HistoryAPI {
    private static var app: PostgrestClient { supabase.schema("app") }
    static let pageSize = 50

    /// Used/thrown-out items, newest first.
    static func page(_ filter: HistoryFilter, offset: Int) async throws -> [PantryItem] {
        try await app.from("pantry_items")
            .select(PantryItem.columns)
            .in("status", values: filter.statuses.map(\.rawValue))
            .is("deleted_at", value: nil)
            .order("status_changed_at", ascending: false, nullsFirst: false)
            .order("added_at", ascending: false)
            .range(from: offset, to: offset + pageSize - 1)
            .execute()
            .value
    }

    static func insights(month: Date) async throws -> PantryInsights {
        try await app.rpc("pantry_insights", params: [
            "month_start": HistoryBuckets.monthStartString(month),
            "tz": TimeZone.current.identifier,
        ])
        .execute()
        .value
    }

    /// Back to the pantry with its original dates (a mistake); leaves History.
    static func putBack(_ id: UUID) async throws {
        try await PantryAPI.setStatus(id, .active)
    }
}
