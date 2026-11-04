import SwiftUI

/// F1.8: what the household used and threw out, with monthly numbers.
struct HistoryView: View {
    /// Called after Put back, so the pantry can refresh.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    @State private var filter: HistoryFilter = .all
    @State private var items: [PantryItem] = []
    @State private var loaded = false
    @State private var reachedEnd = false
    @State private var loadingMore = false
    @State private var month = Date.now
    @State private var insights: PantryInsights?
    @State private var error: String?

    private var isCurrentMonth: Bool {
        Calendar.current.isDate(month, equalTo: .now, toGranularity: .month)
    }

    var body: some View {
        NavigationStack {
            List {
                Section { insightsCard }
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(HistoryFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())

                if loaded && items.isEmpty {
                    Text("Nothing here yet. Items you mark Used or Discard show up here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(HistoryBuckets.sections(items), id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            HistoryRow(item: item)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button { Task { await putBack(item) } } label: {
                                        Label("Put back", systemImage: "arrow.uturn.backward")
                                    }
                                    .tint(.blue)
                                    // "Buy again" joins here when the shopping list ships (F3.5).
                                }
                                .onAppear { if item.id == items.last?.id { Task { await loadMore() } } }
                        }
                    }
                }
                if loadingMore { ProgressView().frame(maxWidth: .infinity) }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .overlay { if !loaded { ProgressView() } }
            .refreshable { await reload() }
            .task(id: filter) { await reload() }
            .task(id: month) { await loadInsights() }
            .alert("Something went wrong", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: { Text(error ?? "") }
        }
    }

    // MARK: Insights

    private var insightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button { shiftMonth(-1) } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Previous month")
                Spacer()
                Text(month.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Button { shiftMonth(1) } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.borderless)
                    .disabled(isCurrentMonth)
                    .accessibilityLabel("Next month")
            }
            if let insights {
                HStack(spacing: 16) {
                    stat("\(insights.used)", "used", .green)
                    stat("\(insights.thrownOut)", "thrown out", .red)
                    if let waste = insights.wasteText {
                        stat(waste, "wasted", .orange)
                    }
                }
                if insights.wasteRate == nil && insights.used + insights.thrownOut > 0 {
                    Text("Waste rate shows once there are 5 or more items in a month.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !insights.thrownMost.isEmpty {
                    listLine("Thrown out most", insights.thrownMost)
                }
                if !insights.boughtMost.isEmpty {
                    listLine("Bought most", insights.boughtMost)
                }
                Text("Top lists cover the last 90 days.").font(.caption2).foregroundStyle(.tertiary)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title2.bold()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func listLine(_ title: String, _ entries: [PantryInsights.Entry]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(entries.map { "\($0.name) (\($0.count)×)" }.joined(separator: ", "))
                .font(.subheadline)
        }
    }

    private func shiftMonth(_ delta: Int) {
        guard let m = Calendar.current.date(byAdding: .month, value: delta, to: month) else { return }
        insights = nil
        month = min(m, .now)
    }

    // MARK: Data

    private func reload() async {
        do {
            items = try await HistoryAPI.page(filter, offset: 0)
            reachedEnd = items.count < HistoryAPI.pageSize
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func loadMore() async {
        guard !reachedEnd, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        do {
            let next = try await HistoryAPI.page(filter, offset: items.count)
            items.append(contentsOf: next)
            reachedEnd = next.count < HistoryAPI.pageSize
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadInsights() async {
        do { insights = try await HistoryAPI.insights(month: month) } catch { self.error = error.localizedDescription }
    }

    private func putBack(_ item: PantryItem) async {
        withAnimation { items.removeAll { $0.id == item.id } }
        do {
            try await HistoryAPI.putBack(item.id)
            onChange()
            await loadInsights()
        } catch {
            self.error = error.localizedDescription
            await reload()
        }
    }
}

private struct HistoryRow: View {
    let item: PantryItem

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                Text("\(QuantityFormat.string(item.quantity, unit: item.unit)) · \(item.isStaple ? "Staples" : item.location.title)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                let used = item.status == .used
                Text(used ? "Used" : "Thrown out")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background((used ? Color.green : Color.red).opacity(0.15), in: Capsule())
                    .foregroundStyle(used ? .green : .red)
                if let date = item.statusChangedAt {
                    Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}
