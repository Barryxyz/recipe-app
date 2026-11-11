import Foundation
import Supabase

/// F3.4: apply "Cooked this" to the pantry in one transaction, and undo it.
@MainActor
enum CookedAPI {
    private static var app: PostgrestClient { supabase.schema("app") }

    /// The rows as they were before the change, for Undo.
    struct Snapshot: Codable, Equatable {
        let id: UUID
        let quantity: Double?
        let status: String
    }

    static func apply(_ changes: [CookedThis.Change]) async throws -> [Snapshot] {
        struct Params: Encodable { let changes: [CookedThis.Change] }
        await OfflineStore.shared.sync()          // send pending pantry edits first (F3.6)
        let snapshot: [Snapshot] = try await app.rpc("apply_cooked", params: Params(changes: changes)).execute().value
        await ExpiryReminders.shared.pantryChanged()
        return snapshot
    }

    static func undo(_ snapshot: [Snapshot]) async throws {
        struct Params: Encodable { let snapshot: [Snapshot] }
        try await app.rpc("undo_cooked", params: Params(snapshot: snapshot)).execute()
        await ExpiryReminders.shared.pantryChanged()
    }

    /// Catalog weights and densities for these ids (custom ingredients have none).
    static func conversions(_ ids: [Int64]) async throws -> [Int64: CookedThis.Conversion] {
        let catalogIds = Array(Set(ids.filter { $0 < PantryItem.customIdStart }))
        guard !catalogIds.isEmpty else { return [:] }
        struct Row: Decodable { let id: Int64; let grams_per_unit: Double?; let density_g_per_ml: Double? }
        let rows: [Row] = try await supabase.schema("catalog").from("ingredients")
            .select("id, grams_per_unit, density_g_per_ml")
            .in("id", values: catalogIds.map { Int($0) })
            .execute().value
        return Dictionary(uniqueKeysWithValues: rows.map {
            ($0.id, CookedThis.Conversion(gramsPerUnit: $0.grams_per_unit, densityGPerMl: $0.density_g_per_ml))
        })
    }
}
