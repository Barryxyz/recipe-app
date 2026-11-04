import Foundation

/// F1.4: the expiry badge for an item, based on the device's local date.
enum ExpiryBadge: Equatable {
    case expired
    case today
    case tomorrow
    /// 2 or 3 days away.
    case days(Int)
    /// Further out: shown as grey date text.
    case later(Date)
    case none

    init(expiresAt: Date?, now: Date = .now, calendar: Calendar = .current) {
        guard let expiresAt else { self = .none; return }
        if expiresAt < now { self = .expired; return }
        let days = calendar.dateComponents([.day],
                                           from: calendar.startOfDay(for: now),
                                           to: calendar.startOfDay(for: expiresAt)).day ?? 0
        switch days {
        case ..<1: self = .today
        case 1: self = .tomorrow
        case 2, 3: self = .days(days)
        default: self = .later(expiresAt)
        }
    }

    /// Red, orange and yellow badges go in "Use these first".
    var isExpiringSoon: Bool {
        switch self {
        case .expired, .today, .tomorrow, .days: true
        case .later, .none: false
        }
    }

    var label: String? {
        switch self {
        case .expired: "Expired"
        case .today: "Today"
        case .tomorrow: "Tomorrow"
        case .days(let n): "\(n) days"
        case .later(let date): date.formatted(.dateTime.month(.abbreviated).day())
        case .none: nil
        }
    }
}

/// F1.4: several batches of the same ingredient in the same location shown as one row
/// ("Milk ×2 · 2 l · Today"). Single items are groups of one.
struct PantryGroup: Identifiable, Equatable {
    /// Batches, soonest expiry first (no expiry last).
    let items: [PantryItem]

    var id: String { Self.key(for: items[0]) }
    var earliest: PantryItem { items[0] }
    var name: String { earliest.displayName }
    var location: StorageLocation { earliest.location }
    var count: Int { items.count }
    var isGroup: Bool { items.count > 1 }

    /// The total when every batch has an amount in the same unit, else nil.
    var totalQuantity: (amount: Double, unit: String?)? {
        let units = Set(items.map { $0.unit ?? "" })
        guard units.count == 1, items.allSatisfy({ $0.quantity != nil }) else { return nil }
        return (items.reduce(0) { $0 + ($1.quantity ?? 0) }, items[0].unit)
    }

    /// "2 l", "6", "some", or "2 batches" when amounts can't be added up.
    var amountText: String {
        guard isGroup else { return QuantityFormat.string(earliest.quantity, unit: earliest.unit) }
        guard let total = totalQuantity else { return "\(count) batches" }
        return QuantityFormat.string(total.amount, unit: total.unit)
    }

    func badge(now: Date = .now, calendar: Calendar = .current) -> ExpiryBadge {
        ExpiryBadge(expiresAt: earliest.expiresAt, now: now, calendar: calendar)
    }

    /// Same ingredient in the same location. Items without an ingredient id group by name.
    static func key(for item: PantryItem) -> String {
        let ingredient = item.ingredientId.map(String.init)
            ?? "name:" + item.displayName.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(item.location.rawValue)|\(ingredient)"
    }
}

enum PantrySort: String, CaseIterable, Identifiable {
    case expiry, name
    var id: String { rawValue }
    var title: String { self == .expiry ? "Expiry date" : "A–Z" }
}

enum PantryGrouping {
    /// Groups items by ingredient and location, then sorts the groups.
    static func groups(_ items: [PantryItem], sort: PantrySort = .expiry) -> [PantryGroup] {
        let byKey = Dictionary(grouping: items, by: PantryGroup.key(for:))
        let groups = byKey.values.map { PantryGroup(items: $0.sorted(by: soonestFirst)) }
        switch sort {
        case .expiry:
            return groups.sorted { a, b in
                if soonestFirst(a.earliest, b.earliest) { return true }
                if soonestFirst(b.earliest, a.earliest) { return false }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
        case .name:
            return groups.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    /// Expiry ascending, no expiry last, then name.
    static func soonestFirst(_ a: PantryItem, _ b: PantryItem) -> Bool {
        switch (a.expiresAt, b.expiresAt) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        case (nil, .some): return false
        default: return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
        }
    }

    /// Search results: exact name matches first, then names starting with the text, then the
    /// rest, each tier in the usual order. Without this, "TEST item 25" could sit below
    /// "TEST item 250…259" because it expires later.
    static func searchResults(_ items: [PantryItem], search: String, sort: PantrySort = .expiry) -> [PantryGroup] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let groups = Self.groups(filter(items, search: q), sort: sort)
        func rank(_ g: PantryGroup) -> Int {
            let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
            if g.items.contains(where: { $0.displayName.trimmingCharacters(in: .whitespaces).compare(q, options: opts) == .orderedSame }) { return 0 }
            if g.items.contains(where: { $0.displayName.range(of: q, options: opts.union(.anchored)) != nil }) { return 1 }
            return 2
        }
        let ranked = groups.enumerated().map { (rank: rank($0.element), index: $0.offset, group: $0.element) }
        return ranked.sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }.map(\.group)
    }

    /// Case- and accent-insensitive name filter across all locations.
    static func filter(_ items: [PantryItem], search: String) -> [PantryItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return items }
        return items.filter { $0.displayName.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }
}
