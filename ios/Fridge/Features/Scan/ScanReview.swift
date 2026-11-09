import Foundation

/// F1.3: the review list between a scan and the pantry. Pure state + rules (no UI, no network),
/// so it can be unit tested and saved as a draft if the app is closed.
struct ScanReview: Codable, Equatable, Identifiable {
    var id: Date { createdAt }
    /// What to do with a scanned item the pantry already has in the same place.
    enum ExistingChoice: String, Codable, CaseIterable {
        case addBatch, update, skip
        var title: String {
            switch self {
            case .addBatch: "Add as another batch"
            case .update: "Update the amount"
            case .skip: "Skip it"
            }
        }
    }

    /// The pantry item a row duplicates, as shown in the note.
    struct Existing: Codable, Equatable {
        let id: UUID
        let quantity: Double?
        let unit: String?
        let expiresAt: Date?
    }

    struct Row: Codable, Equatable, Identifiable {
        var id = UUID()
        var draft: ItemDraft
        /// The model's own name ("eggs") when it differs from the match ("egg").
        var seenAs: String?
        var lowConfidence = false
        /// Not in the catalog or the user's custom items: becomes a custom item on save.
        var isCustom = false
        var category: String?
        var existing: Existing?
        var existingChoice: ExistingChoice = .addBatch
        /// Rows added by hand during review.
        var addedByHand = false
    }

    var rows: [Row]
    /// The place picked for the scan ("Found 14 items in your Fridge").
    var placement: Placement
    var createdAt = Date()

    /// Rows that will be written (skipped duplicates aren't).
    var rowsToSave: [Row] { rows.filter { !($0.existing != nil && $0.existingChoice == .skip) } }
    var saveCount: Int { rowsToSave.count }
    /// All rows deleted (or all skipped): the Save button becomes Discard scan.
    var isEmpty: Bool { saveCount == 0 }

    // MARK: Building from a scan

    init(rows: [Row], placement: Placement) {
        self.rows = rows
        self.placement = placement
    }

    /// Rows from the server's draft. Suggested staples go to Staples, everything else to the
    /// scanned place; unsure rows first within each category.
    init(scan: ScanAPI.Response, placement: Placement, stapleIds: Set<Int64> = []) {
        self.placement = placement
        rows = scan.items.map { item in
            var d = ItemDraft()
            let choice = IngredientChoice(id: item.ingredient_id ?? 0, name: item.display_name, category: item.category,
                                          defaultUnit: item.unit, isCustom: item.ingredient_id == nil
                                              || (item.ingredient_id ?? 0) >= PantryItem.customIdStart)
            d.ingredient = choice
            d.unit = MeasureUnit(catalogUnit: item.unit)
            d.location = placement.location ?? PantryDefaults.location(forCategory: item.category)
            d.setStaple(placement == .staples || item.suggest_staple)
            d.quantity = item.quantity              // scanned amount (or "some"), also for staples
            return Row(draft: d,
                       seenAs: item.name == item.display_name ? nil : item.name,
                       lowConfidence: item.low_confidence,
                       isCustom: item.ingredient_id == nil,
                       category: item.category)
        }
        sortRows()
    }

    /// Grouped by category (unknown last), unsure rows first in each group, then by name.
    mutating func sortRows() {
        rows.sort { a, b in
            let ca = a.category ?? "~", cb = b.category ?? "~"
            if ca != cb { return ca < cb }
            if a.lowConfidence != b.lowConfidence { return a.lowConfidence }
            return (a.draft.ingredient?.name ?? "") < (b.draft.ingredient?.name ?? "")
        }
    }

    // MARK: Editing

    mutating func delete(_ id: Row.ID) { rows.removeAll { $0.id == id } }

    mutating func deleteAllUnsure() { rows.removeAll(where: \.lowConfidence) }

    var unsureCount: Int { rows.filter(\.lowConfidence).count }

    /// The user checked an unsure row and it's right (or they fixed it).
    mutating func confirm(_ id: Row.ID) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].lowConfidence = false
    }

    mutating func update(_ id: Row.ID, draft: ItemDraft) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let renamed = rows[i].draft.ingredient?.id != draft.ingredient?.id
        rows[i].draft = draft
        if renamed {
            // The user picked a different ingredient: no longer a guess.
            rows[i].lowConfidence = false
            rows[i].seenAs = nil
            rows[i].isCustom = draft.ingredient?.isCustom == true && (draft.ingredient?.id ?? 0) == 0
            rows[i].category = draft.ingredient?.category
            rows[i].existing = nil
        }
    }

    mutating func add(_ draft: ItemDraft) {
        rows.append(Row(draft: draft, category: draft.ingredient?.category, addedByHand: true))
    }

    /// Moves every row that isn't a staple to `placement` (the header's "change location").
    mutating func setPlacementForAll(_ placement: Placement) {
        self.placement = placement
        for i in rows.indices where !rows[i].draft.isStaple || placement == .staples {
            let scanned = rows[i].draft.quantity      // keep the scanned amount across the move
            rows[i].draft.placement = placement
            rows[i].draft.quantity = scanned
            rows[i].existing = nil   // re-checked against the new place
        }
    }

    mutating func setExistingChoice(_ id: Row.ID, _ choice: ExistingChoice) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].existingChoice = choice
    }

    /// Marks rows whose ingredient the pantry already has in the same place.
    mutating func markExisting(_ pantry: [PantryItem]) {
        for i in rows.indices {
            guard let id = rows[i].draft.ingredient?.id, id != 0, !rows[i].addedByHand else { continue }
            let d = rows[i].draft
            let match = pantry
                .filter { $0.ingredientId == id && $0.isStaple == d.isStaple && (d.isStaple || $0.location == d.location) }
                .sorted(by: PantryGrouping.soonestFirst)
                .first
            rows[i].existing = match.map { Existing(id: $0.id, quantity: $0.quantity, unit: $0.unit, expiresAt: $0.expiresAt) }
            if match == nil { rows[i].existingChoice = .addBatch }
        }
    }

    // MARK: Save payload (app.add_pantry_items)

    struct SaveItem: Encodable, Equatable {
        var ingredient_id: Int64?
        var custom_name: String?
        var display_name: String
        var quantity: Double?
        var unit: String
        var location: String
        var is_staple: Bool
        var expiry_overridden: Bool
        var expires_at: Date?
        var update_item_id: UUID?

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(ingredient_id, forKey: .ingredient_id)
            try c.encodeIfPresent(custom_name, forKey: .custom_name)
            try c.encode(display_name, forKey: .display_name)
            if let quantity { try c.encode(quantity, forKey: .quantity) } else { try c.encodeNil(forKey: .quantity) }
            try c.encode(unit, forKey: .unit)
            try c.encode(location, forKey: .location)
            try c.encode(is_staple, forKey: .is_staple)
            try c.encode(expiry_overridden, forKey: .expiry_overridden)
            if expiry_overridden, let expires_at {
                try c.encode(ISO8601DateFormatter().string(from: expires_at), forKey: .expires_at)
            }
            try c.encodeIfPresent(update_item_id, forKey: .update_item_id)
        }
        enum CodingKeys: String, CodingKey {
            case ingredient_id, custom_name, display_name, quantity, unit, location, is_staple
            case expiry_overridden, expires_at, update_item_id
        }
    }

    var saveItems: [SaveItem] {
        rowsToSave.compactMap { row in
            let d = row.draft
            guard let ing = d.ingredient else { return nil }
            let name = ing.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let known = ing.id != 0
            return SaveItem(
                ingredient_id: known ? ing.id : nil,
                custom_name: known ? nil : name,
                display_name: name,
                quantity: d.quantity,
                unit: d.unit.rawValue,
                location: d.location.rawValue,
                is_staple: d.isStaple,
                expiry_overridden: d.expiryOverridden,
                expires_at: d.chosenExpiry,
                update_item_id: row.existing != nil && row.existingChoice == .update ? row.existing?.id : nil)
        }
    }

    // MARK: Draft persistence (JSON only, never photos)

    private static let draftKey = "scan.reviewDraft"

    static func loadDraft() -> ScanReview? {
        guard let data = UserDefaults.standard.data(forKey: draftKey) else { return nil }
        return try? JSONDecoder().decode(ScanReview.self, from: data)
    }

    func saveDraft() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.draftKey) }
    }

    static func clearDraft() { UserDefaults.standard.removeObject(forKey: draftKey) }
}

