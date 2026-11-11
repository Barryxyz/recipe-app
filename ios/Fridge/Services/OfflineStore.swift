import Foundation
import Network
import Observation
import os
import Supabase

/// F3.6: is there a network path? (A path doesn't guarantee the server answers; failed syncs
/// also count as offline until the next one works.)
@MainActor @Observable
final class Connectivity {
    static let shared = Connectivity()
    private(set) var hasPath = true
    private let monitor = NWPathMonitor()

    var isOnline: Bool { hasPath && OfflineStore.shared.serverReachable }

    private init() {
        monitor.pathUpdateHandler = { path in
            let ok = path.status == .satisfied
            Task { @MainActor in
                let was = Connectivity.shared.hasPath
                Connectivity.shared.hasPath = ok
                if ok && !was { await OfflineStore.shared.sync() }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.barryxyz.fridge.connectivity"))
    }
}

/// F3.6: the user's pantry and shopping list kept on the device, edited locally and synced.
///
/// - Reads come from here, after a quick sync when online.
/// - Writes change the local copy at once and add the row to an outbox. Pushing upserts each
///   row's current state by id (client-generated ids), so a retry never duplicates anything.
/// - Pulls fetch rows changed since the last pull (server clock), soft deletes included.
///   Rows with unsent changes keep their local version: last write wins per row.
/// - Steps that need the server (scan, recipes, Cooked this, moving bought items to the pantry)
///   stay online-only; afterwards the next pull brings their results.
/// The catalog (for offline search and expiry), custom items, expiry defaults, prefs and saved
/// recipes are cached too, read-only.
@MainActor @Observable
final class OfflineStore {
    static let shared = OfflineStore()

    struct CatalogItem: Codable, Equatable {
        let id: Int64
        let name: String
        let aliases: [String]?
        let category: String?
        let default_unit: String?
        let shelf_life_fridge_days: Int?
        let shelf_life_freezer_days: Int?
        let shelf_life_pantry_days: Int?
        let is_common_staple: Bool?

        var choice: IngredientChoice {
            IngredientChoice(id: id, name: name, category: category, defaultUnit: default_unit, isCustom: false)
        }
        var shelfLife: CatalogShelfLife {
            CatalogShelfLife(fridge: shelf_life_fridge_days, freezer: shelf_life_freezer_days, pantry: shelf_life_pantry_days)
        }
    }

    struct Pending: Codable, Equatable, Hashable {
        enum Table: String, Codable { case pantry, shopping }
        let table: Table
        let id: UUID
    }

    struct State: Codable {
        var userId: UUID?
        var pantry: [PantryItem] = []
        var shopping: [ShoppingItem] = []
        var pending: [Pending] = []
        /// Offline-created custom items: the name to create on the server before pushing the row.
        var pendingCustomNames: [UUID: String] = [:]
        var pulledPantry: Date?
        var pulledShopping: Date?
        var catalog: [CatalogItem] = []
        var catalogFetchedAt: Date?
        var customs: [IngredientChoice] = []
        var customsFetchedAt: Date?
        var expiryDefaults: [String: Int] = [:]       // "ingredientId|location" -> days
        var prefs: UserPrefs?
        var recipesJSON: Data?                        // the last saved-recipes response, as sent
    }

    private(set) var state = State()
    private(set) var serverReachable = true
    private(set) var lastSyncedAt: Date?
    var pendingCount: Int { state.pending.count }

    private var syncTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private let logger = Logger(subsystem: "com.barryxyz.fridge", category: "sync")
    private var app: PostgrestClient { supabase.schema("app") }

    private init() {}

    // MARK: Lifecycle

    /// Launch: load the file for this user, sync, then every 5 minutes while the app is open.
    func start() async {
        ensureUser()
        _ = Connectivity.shared
        await sync()
        ticker?.cancel()
        ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(300))
                await sync()
            }
        }
    }

    /// The signed-in user changed (or first use): load their file; another user's data is wiped.
    @discardableResult
    private func ensureUser() -> Bool {
        guard let uid = supabase.auth.currentUser?.id else { return false }
        if state.userId == uid { return true }
        if let data = try? Data(contentsOf: Self.url), let saved = try? JSONDecoder().decode(State.self, from: data),
           saved.userId == uid {
            state = saved
        } else {
            state = State(userId: uid)      // a different user's (or no) data: start clean
            persist()
        }
        return true
    }

    /// Unit tests: replace the state without touching the file or the network.
    func setStateForTests(_ s: State) { state = s }

    /// Sign out / delete account: nothing stays on the device.
    func wipe() {
        state = State()
        try? FileManager.default.removeItem(at: Self.url)
    }

    nonisolated private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("offline-store.json")
    }

    private func persist() {
        saveTask?.cancel()
        let snapshot = state
        let url = Self.url
        saveTask = Task.detached(priority: .utility) {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    // MARK: Sync

    /// Push the outbox, then pull changes. Concurrent calls share one run.
    func sync() async {
        if let running = syncTask { await running.value; return }
        let task = Task { await runSync() }
        syncTask = task
        await task.value
        syncTask = nil
    }

    /// For reads: sync unless one finished in the last 2 seconds.
    func refresh() async {
        if let last = lastSyncedAt, Date.now.timeIntervalSince(last) < 2, syncTask == nil { return }
        await sync()
    }

    /// The server changed rows itself (an RPC): the next read pulls again.
    func markStale() { lastSyncedAt = nil }

    private func runSync() async {
        guard ensureUser(), Connectivity.shared.hasPath else { return }
        do {
            try await push()
            try await pull()
            serverReachable = true
            lastSyncedAt = .now
        } catch {
            if !(error is PostgrestError) { serverReachable = false }
            logger.info("sync stopped: \(error.localizedDescription, privacy: .public)")
        }
        persist()
    }

    /// Sends each pending row in order. A row the server rejects (e.g. a check fails) is dropped
    /// so it can't block the queue; a network failure stops and keeps the rest.
    private func push() async throws {
        while let next = state.pending.first {
            do {
                switch next.table {
                case .pantry:
                    if var item = state.pantry.first(where: { $0.id == next.id }) {
                        if item.ingredientId == nil, let name = state.pendingCustomNames[item.id] {
                            let id: Int64 = try await app.rpc("get_or_create_custom_ingredient", params: ["p_name": name])
                                .execute().value
                            item.ingredientId = id
                            replace(pantry: item)
                            state.pendingCustomNames[item.id] = nil
                        }
                        try await app.from("pantry_items").upsert(PantryRow(item), onConflict: "id").execute()
                    }
                case .shopping:
                    if let item = state.shopping.first(where: { $0.id == next.id }) {
                        try await app.from("shopping_list_items").upsert(ShoppingRow(item), onConflict: "id").execute()
                    }
                }
            } catch let e as PostgrestError {
                logger.error("dropped \(next.table.rawValue, privacy: .public) change: \(e.localizedDescription, privacy: .public)")
            }
            state.pending.removeFirst()
            persist()
        }
    }

    private func pull() async throws {
        let now: Date = try await app.rpc("server_now").execute().value
        let pending = Set(state.pending)

        var pantryQuery = app.from("pantry_items").select(PantryItem.columns)
        if let since = state.pulledPantry { pantryQuery = pantryQuery.gte("updated_at", value: Self.iso(since)) }
        else { pantryQuery = pantryQuery.is("deleted_at", value: nil) }
        let pantryRows: [PantryItem] = try await pantryQuery.execute().value
        if state.pulledPantry == nil { state.pantry = state.pantry.filter { pending.contains(.init(table: .pantry, id: $0.id)) } }
        for row in pantryRows where !pending.contains(.init(table: .pantry, id: row.id)) {
            state.pantry.removeAll { $0.id == row.id }
            if row.deletedAt == nil { state.pantry.append(row) }
        }
        state.pulledPantry = now

        var shopQuery = app.from("shopping_list_items").select(ShoppingItem.columns)
        if let since = state.pulledShopping { shopQuery = shopQuery.gte("updated_at", value: Self.iso(since)) }
        else { shopQuery = shopQuery.is("deleted_at", value: nil) }
        let shopRows: [ShoppingItem] = try await shopQuery.execute().value
        if state.pulledShopping == nil { state.shopping = state.shopping.filter { pending.contains(.init(table: .shopping, id: $0.id)) } }
        for row in shopRows where !pending.contains(.init(table: .shopping, id: row.id)) {
            state.shopping.removeAll { $0.id == row.id }
            if row.deletedAt == nil { state.shopping.append(row) }
        }
        state.pulledShopping = now
        ShoppingBadge.shared.set(shoppingItems.filter { !$0.checked }.count)

        // Small, read-mostly data: refreshed now and then.
        if state.catalog.isEmpty || (state.catalogFetchedAt.map { Date.now.timeIntervalSince($0) > 7 * 86400 } ?? true) {
            state.catalog = try await supabase.schema("catalog").from("ingredients")
                .select("id, name, aliases, category, default_unit, shelf_life_fridge_days, shelf_life_freezer_days, " +
                        "shelf_life_pantry_days, is_common_staple")
                .order("name").execute().value
            state.catalogFetchedAt = .now
        }
        if state.customsFetchedAt.map({ Date.now.timeIntervalSince($0) > 300 }) ?? true {
            struct Row: Decodable { let id: Int64; let name: String }
            let rows: [Row] = try await app.from("ingredients_private").select("id, name")
                .is("deleted_at", value: nil).execute().value
            state.customs = rows.map { IngredientChoice(id: $0.id, name: $0.name, category: nil, defaultUnit: "each", isCustom: true) }
            state.customsFetchedAt = .now
        }
    }

    private static func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    // MARK: Pantry

    /// Active, not deleted; soonest expiry first, no-expiry last, then by name (like the server query).
    var activePantry: [PantryItem] {
        state.pantry.filter { $0.status == .active && $0.deletedAt == nil }.sorted { a, b in
            switch (a.expiresAt, b.expiresAt) {
            case let (x?, y?) where x != y: return x < y
            case (.some, nil): return true
            case (nil, .some): return false
            default: return a.displayName.localizedCompare(b.displayName) == .orderedAscending
            }
        }
    }

    /// Every pantry row the device knows (any status), newest first: for "recently added".
    var allPantry: [PantryItem] { state.pantry.filter { $0.deletedAt == nil }.sorted { $0.addedAt > $1.addedAt } }

    func pantryItem(_ id: UUID) -> PantryItem? { state.pantry.first { $0.id == id } }

    /// Saves a local change and queues it for the server.
    func save(pantry item: PantryItem, customName: String? = nil) {
        replace(pantry: item)
        if let customName { state.pendingCustomNames[item.id] = customName }
        enqueue(.init(table: .pantry, id: item.id))
    }

    private func replace(pantry item: PantryItem) {
        if let i = state.pantry.firstIndex(where: { $0.id == item.id }) { state.pantry[i] = item } else { state.pantry.append(item) }
    }

    /// The F1.6 rule on the device (the server's date replaces it after the next pull).
    func previewExpiry(ingredientId: Int64?, location: StorageLocation, addedAt: Date) -> Date {
        let byId = Dictionary(state.catalog.map { ($0.id, $0.shelfLife) }, uniquingKeysWith: { a, _ in a })
        return ExpiryCalculator(timeZone: .current, userDefaults: expiryDefaults, catalog: { byId[$0] })
            .defaultExpiry(ingredientId: ingredientId, location: location, addedAt: addedAt)
    }

    // MARK: Shopping list

    var shoppingItems: [ShoppingItem] {
        state.shopping.filter { $0.deletedAt == nil }.sorted { $0.createdAt < $1.createdAt }
    }

    func save(shopping item: ShoppingItem) {
        if let i = state.shopping.firstIndex(where: { $0.id == item.id }) { state.shopping[i] = item } else { state.shopping.append(item) }
        enqueue(.init(table: .shopping, id: item.id))
        ShoppingBadge.shared.set(shoppingItems.filter { !$0.checked }.count)
    }

    func shoppingItem(_ id: UUID) -> ShoppingItem? { state.shopping.first { $0.id == id } }

    private func enqueue(_ p: Pending) {
        state.pending.removeAll { $0 == p }       // one entry per row: its latest state is sent
        state.pending.append(p)
        persist()
        Task { await sync() }
    }

    // MARK: Catalog and cached reads

    var hasCatalog: Bool { !state.catalog.isEmpty }

    func catalogItem(_ id: Int64) -> CatalogItem? { state.catalog.first { $0.id == id } }

    var catalogStaples: [IngredientChoice] { state.catalog.filter { $0.is_common_staple == true }.map(\.choice) }

    /// Offline search over the catalog (names and aliases) and the user's own items.
    func search(_ query: String, limit: Int) -> [IngredientChoice] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func score(_ names: [String]) -> Double {
            names.map { n -> Double in
                let n = n.lowercased()
                if n == q { return 1 }
                if n.hasPrefix(q) { return 0.9 }
                if n.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 0.8 }
                if n.contains(q) { return 0.7 }
                return 0
            }.max() ?? 0
        }
        var found: [(IngredientChoice, Double)] = state.customs.compactMap { c in
            let s = score([c.name]); return s > 0 ? (c, s) : nil
        }
        found += state.catalog.compactMap { c in
            let s = score([c.name] + (c.aliases ?? [])); return s > 0 ? (c.choice, s) : nil
        }
        return found.sorted { a, b in
            if (a.0.isCustom && a.1 == 1) != (b.0.isCustom && b.1 == 1) { return a.0.isCustom && a.1 == 1 }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.name.count < b.0.name.count
        }
        .prefix(limit).map { var c = $0.0; c.score = $0.1; return c }
    }

    var expiryDefaults: [ExpiryCalculator.DefaultKey: Int] {
        var out: [ExpiryCalculator.DefaultKey: Int] = [:]
        for (k, v) in state.expiryDefaults {
            let parts = k.split(separator: "|")
            if parts.count == 2, let id = Int64(parts[0]), let loc = StorageLocation(rawValue: String(parts[1])) {
                out[.init(ingredientId: id, location: loc)] = v
            }
        }
        return out
    }

    func cache(expiryDefaults d: [ExpiryCalculator.DefaultKey: Int]) {
        state.expiryDefaults = Dictionary(uniqueKeysWithValues: d.map { ("\($0.key.ingredientId)|\($0.key.location.rawValue)", $0.value) })
        persist()
    }

    var prefs: UserPrefs? { state.prefs }
    func cache(prefs p: UserPrefs) { state.prefs = p; persist() }

    var recipesJSON: Data? { state.recipesJSON }
    func cache(recipesJSON data: Data) { state.recipesJSON = data; persist() }
}

/// What's sent for a pantry row: the user's fields and the soft delete. The server sets
/// household, added_by, updated_at and status_changed_at, and recalculates a rule-based expiry.
private struct PantryRow: Encodable {
    let item: PantryItem
    init(_ item: PantryItem) { self.item = item }

    enum CodingKeys: String, CodingKey {
        case id, ingredient_id, display_name, quantity, unit, location, added_at, expires_at, expiry_overridden
        case status, source, is_staple, deleted_at
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(item.id, forKey: .id)
        try c.encode(item.ingredientId, forKey: .ingredient_id)
        try c.encode(item.displayName, forKey: .display_name)
        try c.encode(item.quantity, forKey: .quantity)
        try c.encode(item.unit, forKey: .unit)
        try c.encode(item.location, forKey: .location)
        try c.encode(item.addedAt, forKey: .added_at)
        try c.encode(item.expiresAt, forKey: .expires_at)
        try c.encode(item.expiryOverridden, forKey: .expiry_overridden)
        try c.encode(item.status, forKey: .status)
        try c.encode(item.source, forKey: .source)
        try c.encode(item.isStaple, forKey: .is_staple)
        try c.encode(item.deletedAt, forKey: .deleted_at)
    }
}

private struct ShoppingRow: Encodable {
    let item: ShoppingItem
    init(_ item: ShoppingItem) { self.item = item }

    enum CodingKeys: String, CodingKey {
        case id, ingredient_id, name, quantity, unit, source_recipe_id, source_recipe_title, checked, created_at, deleted_at
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(item.id, forKey: .id)
        try c.encode(item.ingredientId, forKey: .ingredient_id)
        try c.encode(item.name, forKey: .name)
        try c.encode(item.quantity, forKey: .quantity)
        try c.encode(item.unit, forKey: .unit)
        try c.encode(item.sourceRecipeId, forKey: .source_recipe_id)
        try c.encode(item.sourceRecipeTitle, forKey: .source_recipe_title)
        try c.encode(item.checked, forKey: .checked)
        try c.encode(item.createdAt, forKey: .created_at)
        try c.encode(item.deletedAt, forKey: .deleted_at)
    }
}
