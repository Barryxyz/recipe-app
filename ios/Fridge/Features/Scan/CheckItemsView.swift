import SwiftUI

/// F1.3: walks through the scan's unsure items one at a time: Looks right, Fix, or Remove.
struct CheckItemsView: View {
    @Binding var review: ScanReview
    /// "Fridge · exp. Nov 12" for a row.
    var detail: (ScanReview.Row) -> String

    @Environment(\.dismiss) private var dismiss
    /// The unsure rows when the sheet opened, so the count stays stable while checking.
    @State private var queue: [ScanReview.Row.ID] = []
    @State private var index = 0
    @State private var editing: ScanReview.Row?

    private var current: ScanReview.Row? {
        guard index < queue.count else { return nil }
        return review.rows.first { $0.id == queue[index] }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let row = current {
                    card(row)
                } else {
                    ContentUnavailableView("All checked", systemImage: "checkmark.circle.fill",
                                           description: Text("Review the rest of the list, then tap Save."))
                }
            }
            .navigationTitle(queue.isEmpty ? "Check items" : "Check \(min(index + 1, queue.count)) of \(queue.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $editing) { row in
                ItemFormView(mode: .reviewEdit(row.draft), onDraft: { draft in
                    review.update(row.id, draft: draft)
                    review.confirm(row.id)
                    next()
                })
            }
        }
        .onAppear {
            if queue.isEmpty { queue = review.rows.filter(\.lowConfidence).map(\.id) }
        }
    }

    private func card(_ row: ScanReview.Row) -> some View {
        let d = row.draft
        return VStack(spacing: 20) {
            ProgressView(value: Double(index), total: Double(max(queue.count, 1)))
            Spacer()
            VStack(spacing: 8) {
                Text("Is this right?").font(.subheadline).foregroundStyle(.secondary)
                Text(d.ingredient?.name ?? "?").font(.largeTitle.bold()).multilineTextAlignment(.center)
                if let seen = row.seenAs {
                    Text("seen as \u{201C}\(seen)\u{201D}").font(.callout).foregroundStyle(.secondary)
                }
                Text(QuantityFormat.string(d.quantity, unit: d.unit.rawValue)).font(.title3)
                Text(detail(row)).font(.callout).foregroundStyle(.secondary)
                if row.isCustom {
                    Text("Not in our food list: it will be saved as a custom item.")
                        .font(.caption).foregroundStyle(.purple).multilineTextAlignment(.center)
                }
            }
            Spacer()
            VStack(spacing: 12) {
                Button { review.confirm(row.id); next() } label: {
                    Label("Looks right", systemImage: "checkmark").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                Button { editing = row } label: {
                    Label("Fix it", systemImage: "pencil").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
                Button(role: .destructive) { review.delete(row.id); next() } label: {
                    Label("Remove", systemImage: "trash").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .padding()
        .id(row.id)
        .transition(.push(from: .trailing))
    }

    /// Next unsure row still in the list; closes after the last one.
    private func next() {
        withAnimation {
            index += 1
            while index < queue.count, current == nil { index += 1 }
        }
        if index >= queue.count {
            Task { try? await Task.sleep(for: .milliseconds(600)); dismiss() }
        }
    }
}
