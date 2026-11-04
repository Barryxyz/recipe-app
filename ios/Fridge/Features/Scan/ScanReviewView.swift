import SwiftUI

/// F1.3: confirm, fix or remove what a scan found before anything reaches the pantry.
/// The list is kept as a draft (JSON, never photos) until Save or Discard.
struct ScanReviewView: View {
    @State var review: ScanReview
    /// Saved: number of items added or updated.
    var onSaved: (Int) -> Void
    var onDiscard: () -> Void
    /// Empty scan: back to the camera.
    var onRetake: (() -> Void)?
    var onAddManually: () -> Void

    @State private var editing: ScanReview.Row?
    @State private var showAdd = false
    @State private var confirmDiscard = false
    @State private var saving = false
    @State private var saveError: String?
    @State private var shelfLives: [Int64: CatalogShelfLife] = [:]
    @State private var userDefaults: [ExpiryCalculator.DefaultKey: Int] = [:]
    @State private var loaded = false
    /// The scan itself found nothing (as opposed to the user deleting every row).
    @State private var startedEmpty: Bool?

    var body: some View {
        Group {
            if startedEmpty == nil {
                ProgressView()
            } else if startedEmpty == true && review.rows.isEmpty {
                noFood
            } else {
                list
            }
        }
        .navigationTitle("Review scan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .sheet(item: $editing) { row in
            ItemFormView(mode: .reviewEdit(row.draft), onDraft: { review.update(row.id, draft: $0) })
        }
        .sheet(isPresented: $showAdd) {
            ItemFormView(mode: .reviewAdd, onDraft: { review.add($0) })
        }
        .confirmationDialog("Discard this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { ScanReview.clearDraft(); onDiscard() }
        } message: { Text("Nothing from it will be added to your pantry.") }
        .alert("Couldn't save", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: { Text("Nothing was saved and your review is kept. \(saveError ?? "")") }
        .onChange(of: review) { _, new in new.saveDraft() }
        .task { await load() }
    }

    // MARK: List

    private var list: some View {
        List {
            Section {
                Text(header).font(.headline)
                if review.unsureCount > 0 {
                    Label("\(review.unsureCount) item\(review.unsureCount == 1 ? "" : "s") to check", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline).foregroundStyle(.orange)
                }
            }
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        Button { editing = row } label: { rowView(row) }
                            .foregroundStyle(.primary)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) { withAnimation { review.delete(row.id) } } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            Section {
                Button { showAdd = true } label: { Label("Add item", systemImage: "plus") }
            }
        }
    }

    private var header: String {
        let n = review.rows.count
        let place = review.placement == .staples ? "Seasonings & Staples" : "your \(review.placement.title)"
        return "Found \(n) item\(n == 1 ? "" : "s") in \(place)"
    }

    private var sections: [(title: String, rows: [ScanReview.Row])] {
        var out: [(title: String, rows: [ScanReview.Row])] = []
        for row in review.rows {
            let title = row.addedByHand ? "Added by you" : (row.category?.capitalized ?? "Other")
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].rows.append(row) } else { out.append((title, [row])) }
        }
        return out
    }

    private func rowView(_ row: ScanReview.Row) -> some View {
        let d = row.draft
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(d.ingredient?.name ?? "?")
                    if let seen = row.seenAs {
                        Text("seen as \u{201C}\(seen)\u{201D}").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Text(QuantityFormat.string(d.quantity, unit: d.unit.rawValue)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if row.lowConfidence { tag("Check this", .orange) }
                if row.isCustom { tag("Custom item", .purple) }
                Text("\(d.placement.title) · \(expiryText(d))").font(.caption).foregroundStyle(.secondary)
            }
            if let existing = row.existing { existingNote(row, existing) }
        }
        .padding(.vertical, 2)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private func existingNote(_ row: ScanReview.Row, _ existing: ScanReview.Existing) -> some View {
        HStack {
            let amount = QuantityFormat.string(existing.quantity, unit: existing.unit)
            let exp = existing.expiresAt.map { ", expires \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? ""
            Text("Already have: \(amount)\(exp)").font(.caption).foregroundStyle(.blue)
            Spacer()
            Menu {
                Picker("", selection: Binding(get: { row.existingChoice },
                                              set: { review.setExistingChoice(row.id, $0) })) {
                    ForEach(ScanReview.ExistingChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            } label: {
                Text(shortTitle(row.existingChoice)).font(.caption.weight(.semibold))
            }
        }
    }

    private func shortTitle(_ c: ScanReview.ExistingChoice) -> String {
        switch c {
        case .addBatch: "Add batch ▾"
        case .update: "Update amount ▾"
        case .skip: "Skip ▾"
        }
    }

    /// The date it will get (F1.6), or the one the user picked.
    private func expiryText(_ d: ItemDraft) -> String {
        if d.expiryOverridden {
            return d.chosenExpiry.map { "exp. \($0.formatted(.dateTime.month(.abbreviated).day()))" } ?? "no expiry"
        }
        let calc = ExpiryCalculator(timeZone: .current, userDefaults: userDefaults, catalog: { shelfLives[$0] })
        let id = d.ingredient?.id
        let date = calc.defaultExpiry(ingredientId: id == 0 ? nil : id, location: d.location, addedAt: .now)
        return "exp. \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    // MARK: Empty scan

    private var noFood: some View {
        ContentUnavailableView {
            Label("Didn't spot any food", systemImage: "eye.slash")
        } description: {
            Text("Try a closer photo with better light, or add items by hand.")
        } actions: {
            if let onRetake { Button("Retake") { ScanReview.clearDraft(); onRetake() }.buttonStyle(.borderedProminent) }
            Button("Add manually") { ScanReview.clearDraft(); onAddManually() }
        }
    }

    // MARK: Toolbar & save

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Discard") { confirmDiscard = true }
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Menu("Move everything to…") {
                    ForEach(Placement.allCases) { p in Button(p.title) { review.setPlacementForAll(p); Task { await markExisting() } } }
                }
                Button(role: .destructive) { withAnimation { review.deleteAllUnsure() } } label: {
                    Label("Delete all unsure (\(review.unsureCount))", systemImage: "trash")
                }
                .disabled(review.unsureCount == 0)
            } label: { Image(systemName: "ellipsis.circle") }
        }
        ToolbarItem(placement: .confirmationAction) {
            if review.isEmpty {
                Button("Discard scan") { ScanReview.clearDraft(); onDiscard() }
            } else {
                Button("Save \(review.saveCount)") { Task { await save() } }
                    .fontWeight(.semibold)
                    .disabled(saving)
            }
        }
    }

    private func load() async {
        if startedEmpty == nil { startedEmpty = review.rows.isEmpty }
        review.saveDraft()
        async let defaults = try? PantryAPI.userDefaults()
        let ids = review.rows.compactMap { $0.draft.ingredient?.id }
        shelfLives = (try? await PantryAPI.shelfLives(for: ids)) ?? [:]
        userDefaults = await defaults ?? [:]
        await markExisting()
        loaded = true
    }

    private func markExisting() async {
        if let pantry = try? await PantryAPI.activeItems() { review.markExisting(pantry) }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        do {
            let r = try await ScanAPI.save(review)
            ScanReview.clearDraft()
            onSaved(r.added + r.updated)
        } catch {
            saveError = error.localizedDescription   // the draft stays
        }
    }
}
